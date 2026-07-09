import type {
  Group, Policy, PolicyKind, Grant, Goal, EventRow, Device, NewEvent, SyncPayload,
} from './types.js';

export interface Repo {
  listGroups(): Promise<Group[]>;
  createGroup(name: string): Promise<Group>;
  setGroupSelection(id: string, hasSelection: boolean): Promise<void>;

  listPolicies(activeOnly?: boolean): Promise<Policy[]>;
  /** Deactivates any active policy of this kind on the group, inserts the new one. */
  replacePolicy(
    groupId: string,
    kind: PolicyKind,
    fields: Pick<Policy, 'daysOfWeek' | 'startTime' | 'endTime' | 'minutesPerDay' | 'until' | 'timezone'>,
  ): Promise<Policy>;
  /** Sets active=false. Returns count deactivated. kind omitted = all kinds. */
  deactivatePolicies(groupId: string, kind?: PolicyKind): Promise<number>;

  listGrants(statuses?: Grant['status'][]): Promise<Grant[]>;
  createGrant(groupId: string, minutes: number, reason: string | null, expiresAt: Date): Promise<Grant>;
  /** Marks pending/active grants with expires_at <= now as expired. Returns count. */
  expireGrants(now: Date): Promise<number>;

  upsertGoal(date: string, text: string, target: string | null): Promise<Goal>;
  getGoal(date: string): Promise<Goal | null>;

  insertEvents(events: NewEvent[]): Promise<number>;
  /** Events whose ts falls on `date` (YYYY-MM-DD) in `timezone`. */
  listEventsOn(date: string, timezone: string): Promise<EventRow[]>;

  registerDevice(apnsToken: string): Promise<Device>;
  listDevices(): Promise<Device[]>;
  ackDevice(apnsToken: string, appliedThrough: Date): Promise<void>;

  /** Everything updated after `since` (all rows when null), for device pull-sync. */
  changesSince(since: Date | null): Promise<SyncPayload>;
}
