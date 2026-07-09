import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { Ladder, type PushSender } from '../src/push.js';
import { FakeRepo } from './fakes.js';

class RecordingSender implements PushSender {
  silent: string[] = [];
  visible: Array<{ token: string; body: string }> = [];
  async sendSilent(token: string) { this.silent.push(token); }
  async sendVisible(token: string, _title: string, body: string) { this.visible.push({ token, body }); }
}

describe('Ladder', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('sends silent immediately, then visible fallback when no ack arrives', async () => {
    const repo = new FakeRepo();
    await repo.registerDevice('tok1');
    const sender = new RecordingSender();
    const ladder = new Ladder(repo, sender, 15_000);

    ladder.policyChanged(new Date(), 'Block Social now');
    await vi.advanceTimersByTimeAsync(0);
    expect(sender.silent).toEqual(['tok1']);
    expect(sender.visible).toHaveLength(0);

    await vi.advanceTimersByTimeAsync(15_000);
    expect(sender.visible).toEqual([{ token: 'tok1', body: 'Tap to apply: Block Social now' }]);
  });

  it('skips the visible fallback when a device acks in time', async () => {
    const repo = new FakeRepo();
    await repo.registerDevice('tok1');
    const sender = new RecordingSender();
    const ladder = new Ladder(repo, sender, 15_000);

    const changedAt = new Date();
    ladder.policyChanged(changedAt, 'Block Social now');
    await vi.advanceTimersByTimeAsync(0);
    await repo.ackDevice('tok1', new Date(changedAt.getTime() + 1000));

    await vi.advanceTimersByTimeAsync(15_000);
    expect(sender.visible).toHaveLength(0);
  });

  it('does nothing (and does not throw) with zero devices', async () => {
    const ladder = new Ladder(new FakeRepo(), new RecordingSender(), 15_000);
    expect(() => ladder.policyChanged(new Date(), 'x')).not.toThrow();
    await vi.advanceTimersByTimeAsync(15_000);
  });

  it('survives sender failures silently', async () => {
    const repo = new FakeRepo();
    await repo.registerDevice('tok1');
    const failing: PushSender = {
      sendSilent: async () => { throw new Error('apns down'); },
      sendVisible: async () => { throw new Error('apns down'); },
    };
    const ladder = new Ladder(repo, failing, 1000);
    ladder.policyChanged(new Date(), 'x');
    await vi.advanceTimersByTimeAsync(1000); // no unhandled rejection = pass
  });
});
