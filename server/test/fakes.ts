import { randomUUID } from 'node:crypto';
import type { Repo } from '../src/repo.js';
import type {
  Group, Policy, PolicyKind, Grant, Goal, EventRow, Device, NewEvent, SyncPayload,
} from '../src/types.js';
import type { Push } from '../src/push.js';

const iso = (d: Date) => d.toISOString();

/** YYYY-MM-DD of an instant in a timezone (mirrors domain.todayInTz). */
function localDate(tsIso: string, timezone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(tsIso));
}

export class FakeRepo implements Repo {
  groups: Group[] = [];
  policies: Policy[] = [];
  grants: Grant[] = [];
  goals: Goal[] = [];
  events: EventRow[] = [];
  devices: Device[] = [];
  private eventId = 0;

  async listGroups() { return [...this.groups]; }

  async createGroup(name: string): Promise<Group> {
    if (this.groups.some((g) => g.name === name)) throw new Error(`duplicate group: ${name}`);
    const g: Group = { id: randomUUID(), name, hasSelection: false, updatedAt: iso(new Date()) };
    this.groups.push(g);
    return g;
  }

  async setGroupSelection(id: string, hasSelection: boolean) {
    const g = this.groups.find((x) => x.id === id);
    if (g) { g.hasSelection = hasSelection; g.updatedAt = iso(new Date()); }
  }

  async listPolicies(activeOnly = true) {
    return this.policies.filter((p) => !activeOnly || p.active);
  }

  async replacePolicy(
    groupId: string,
    kind: PolicyKind,
    fields: Pick<Policy, 'daysOfWeek' | 'startTime' | 'endTime' | 'minutesPerDay' | 'until' | 'timezone'>,
  ): Promise<Policy> {
    for (const p of this.policies) {
      if (p.groupId === groupId && p.kind === kind && p.active) {
        p.active = false; p.updatedAt = iso(new Date());
      }
    }
    const policy: Policy = {
      id: randomUUID(), groupId, kind, active: true, ...fields, updatedAt: iso(new Date()),
    };
    this.policies.push(policy);
    return policy;
  }

  async deactivatePolicies(groupId: string, kind?: PolicyKind) {
    let n = 0;
    for (const p of this.policies) {
      if (p.groupId === groupId && p.active && (!kind || p.kind === kind)) {
        p.active = false; p.updatedAt = iso(new Date()); n++;
      }
    }
    return n;
  }

  async listGrants(statuses?: Grant['status'][]) {
    return this.grants.filter((g) => !statuses || statuses.includes(g.status));
  }

  async createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date): Promise<Grant> {
    const grant: Grant = {
      id: randomUUID(), groupId, minutes, reason,
      startsAt: iso(new Date()), expiresAt: iso(expiresAt),
      status: 'pending', updatedAt: iso(new Date()),
    };
    this.grants.push(grant);
    return grant;
  }

  async expireGrants(now: Date) {
    let n = 0;
    for (const g of this.grants) {
      if ((g.status === 'pending' || g.status === 'active') && new Date(g.expiresAt) <= now) {
        g.status = 'expired'; g.updatedAt = iso(new Date()); n++;
      }
    }
    return n;
  }

  async upsertGoal(date: string, text: string, target: string | null): Promise<Goal> {
    const existing = this.goals.find((g) => g.date === date);
    if (existing) { existing.text = text; existing.target = target; return existing; }
    const goal: Goal = { date, text, target };
    this.goals.push(goal);
    return goal;
  }

  async getGoal(date: string) { return this.goals.find((g) => g.date === date) ?? null; }

  async insertEvents(events: NewEvent[]) {
    for (const e of events) {
      this.events.push({
        id: ++this.eventId,
        groupId: e.groupId ?? null,
        type: e.type,
        ts: e.ts ?? iso(new Date()),
        meta: e.meta ?? {},
      });
    }
    return events.length;
  }

  async listEventsOn(date: string, timezone: string) {
    return this.events.filter((e) => localDate(e.ts, timezone) === date);
  }

  async registerDevice(apnsToken: string): Promise<Device> {
    const existing = this.devices.find((d) => d.apnsToken === apnsToken);
    if (existing) { existing.lastSeenAt = iso(new Date()); return existing; }
    const d: Device = { id: randomUUID(), apnsToken, appliedThrough: null, lastSeenAt: iso(new Date()) };
    this.devices.push(d);
    return d;
  }

  async listDevices() { return [...this.devices]; }

  async ackDevice(apnsToken: string, appliedThrough: Date) {
    const d = this.devices.find((x) => x.apnsToken === apnsToken);
    if (d) { d.appliedThrough = iso(appliedThrough); d.lastSeenAt = iso(new Date()); }
  }

  async changesSince(since: Date | null): Promise<SyncPayload> {
    const newer = (u: string) => !since || new Date(u) > since;
    return {
      groups: this.groups.filter((g) => newer(g.updatedAt)),
      policies: this.policies.filter((p) => newer(p.updatedAt)),
      grants: this.grants.filter((g) => newer(g.updatedAt)),
      serverTime: iso(new Date()),
    };
  }
}

export class FakePush implements Push {
  calls: Array<{ changedAt: Date; description: string }> = [];
  policyChanged(changedAt: Date, description: string) {
    this.calls.push({ changedAt, description });
  }
}
