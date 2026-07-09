import type { Repo } from './repo.js';
import type { ApnsConfig } from './config.js';

export interface Push {
  /** Fire-and-forget: notify device(s) that policy changed at `changedAt`. */
  policyChanged(changedAt: Date, description: string): void;
}

export interface PushSender {
  sendSilent(token: string): Promise<void>;
  sendVisible(token: string, title: string, body: string): Promise<void>;
}

/**
 * Spec §7 rungs 2–3. Silent push immediately (best-effort); if no device has
 * acked past `changedAt` after `fallbackMs`, send a visible Time-Sensitive
 * "Tap to apply" notification (guaranteed-delivery rung).
 */
export class Ladder implements Push {
  constructor(
    private repo: Repo,
    private sender: PushSender,
    private fallbackMs = 15_000,
  ) {}

  policyChanged(changedAt: Date, description: string): void {
    void this.run(changedAt, description).catch(() => { /* push is never fatal */ });
  }

  private async run(changedAt: Date, description: string): Promise<void> {
    const devices = await this.repo.listDevices();
    if (devices.length === 0) return;
    await Promise.all(
      devices.map((d) => this.sender.sendSilent(d.apnsToken).catch(() => {})),
    );
    const timer = setTimeout(() => {
      void (async () => {
        const latest = await this.repo.listDevices();
        const acked = latest.some(
          (d) => d.appliedThrough !== null && new Date(d.appliedThrough) >= changedAt,
        );
        if (acked) return;
        await Promise.all(
          latest.map((d) =>
            this.sender.sendVisible(d.apnsToken, 'ScreenCP', `Tap to apply: ${description}`).catch(() => {}),
          ),
        );
      })().catch(() => {});
    }, this.fallbackMs);
    timer.unref?.();
  }
}

/** Used when APNs env vars are unset (e.g. before Plan 2 registers a device). */
export class NoopSender implements PushSender {
  async sendSilent() {}
  async sendVisible() {}
}

/**
 * apns2 adapter. Verify option names against the installed apns2 README
 * (https://github.com/AndrewBarba/apns2) when wiring — the shapes below match v11.
 */
export class ApnsSender implements PushSender {
  private client: import('apns2').ApnsClient;
  private Notification: typeof import('apns2').Notification;
  private SilentNotification: typeof import('apns2').SilentNotification;

  private constructor(
    client: import('apns2').ApnsClient,
    N: typeof import('apns2').Notification,
    S: typeof import('apns2').SilentNotification,
  ) {
    this.client = client;
    this.Notification = N;
    this.SilentNotification = S;
  }

  static async create(cfg: ApnsConfig): Promise<ApnsSender> {
    const { ApnsClient, Notification, SilentNotification } = await import('apns2');
    const client = new ApnsClient({
      team: cfg.teamId,
      keyId: cfg.keyId,
      signingKey: cfg.key,
      defaultTopic: cfg.topic,
      host: cfg.production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com',
    });
    return new ApnsSender(client, Notification, SilentNotification);
  }

  async sendSilent(token: string): Promise<void> {
    await this.client.send(new this.SilentNotification(token));
  }

  async sendVisible(token: string, title: string, body: string): Promise<void> {
    await this.client.send(
      new this.Notification(token, {
        alert: { title, body },
        // Time-Sensitive so it pierces Focus modes (spec §7 rung 3).
        aps: { 'interruption-level': 'time-sensitive' },
      }),
    );
  }
}
