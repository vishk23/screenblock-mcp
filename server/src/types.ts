export type PolicyKind = 'schedule' | 'limit' | 'block';

export interface Group {
  id: string;
  name: string;
  hasSelection: boolean;
  updatedAt: string;
}

export interface Policy {
  id: string;
  groupId: string;
  kind: PolicyKind;
  active: boolean;
  daysOfWeek?: number[]; // 0=Sun … 6=Sat
  startTime?: string;    // "HH:MM"
  endTime?: string;      // "HH:MM"
  minutesPerDay?: number;
  until?: string | null; // ISO timestamp for block_now(until)
  timezone?: string;
  updatedAt: string;
}

export type GrantStatus = 'pending' | 'active' | 'expired' | 'cancelled';

export interface Grant {
  id: string;
  groupId: string;
  minutes: number;
  reason: string | null;
  startsAt: string;
  expiresAt: string;
  status: GrantStatus;
  updatedAt: string;
}

export interface Goal {
  date: string; // YYYY-MM-DD
  text: string;
  target: string | null;
}

export interface EventRow {
  id: number;
  groupId: string | null;
  type: string;
  ts: string;
  meta: Record<string, unknown>;
}

export interface Device {
  id: string;
  apnsToken: string;
  appliedThrough: string | null;
  lastSeenAt: string;
}

export interface NewEvent {
  type: string;
  groupId?: string | null;
  ts?: string;
  meta?: Record<string, unknown>;
}

export interface SyncPayload {
  groups: Group[];
  policies: Policy[];
  grants: Grant[];
  serverTime: string;
}
