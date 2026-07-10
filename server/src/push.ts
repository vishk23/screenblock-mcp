import type { Repo } from './repo.js';
import type { ApnsConfig } from './config.js';

export interface Push {
  /** Fire-and-forget: notify device(s) that policy changed at `changedAt`. */
  policyChanged(changedAt: Date, description: string): void;
}

export interface PushSender {
  sendSilent(token: string): Promise<void>;
  sendVisible(token: string, title: string, body: string): Promise<void>;
  /** Plain visible push, NO mutable-content — the NSE must not intercept/rewrite it. */
  sendNudge(token: string, title: string, body: string): Promise<void>;
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
    // Short leash: the NSE no-tap path (proven reliable) rides the visible push,
    // so waiting long for the flaky silent push just adds dead air.
    private fallbackMs = 8_000,
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
    // This timer intentionally no-ops (rather than being cancelled) when an ack lands
    // before it fires; devices registered after the silent send still receive the
    // visible fallback, which is desired — new devices need the policy too.
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
  async sendNudge() {}
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
    try {
      await this.client.send(new this.SilentNotification(token));
      console.log(`apns silent ok -> ${token.slice(0, 8)}`);
    } catch (err) {
      console.error(`apns silent FAILED -> ${token.slice(0, 8)}:`, err);
      throw err;
    }
  }

  async sendNudge(token: string, title: string, body: string): Promise<void> {
    try {
      await this.client.send(
        new this.Notification(token, {
          alert: { title, body },
          aps: { 'interruption-level': 'time-sensitive' },
        }),
      );
      console.log(`apns nudge ok -> ${token.slice(0, 8)}`);
    } catch (err) {
      console.error(`apns nudge FAILED -> ${token.slice(0, 8)}:`, err);
      throw err;
    }
  }

  async sendVisible(token: string, title: string, body: string): Promise<void> {
    try {
      await this.client.send(
        new this.Notification(token, {
          alert: { title, body },
          // mutable-content routes delivery through the Notification Service
          // Extension on-device, which tries to apply the change with NO tap
          // (spec §7 spike). Time-Sensitive pierces Focus modes (rung 3).
          aps: { 'interruption-level': 'time-sensitive', 'mutable-content': 1 },
        }),
      );
      console.log(`apns visible ok -> ${token.slice(0, 8)}`);
    } catch (err) {
      console.error(`apns visible FAILED -> ${token.slice(0, 8)}:`, err);
      throw err;
    }
  }
}
