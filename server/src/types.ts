export type PolicyKind = 'schedule' | 'limit' | 'block';

export type GroupMode = 'strict' | 'quota' | 'open';

export interface Group {
  id: string;
  name: string;
  hasSelection: boolean;
  /** strict = chat-only unlocks; quota = N self-serve unlocks/day; open = unblock freely. */
  mode: GroupMode;
  quotaPerDay: number;
  quotaMinutes: number;
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

// v1 never sets 'active' server-side — grants go pending→expired on the clock; the
// device applies/reports via events, and applied-ness is conveyed by the separate
// delivery state.
export type GrantStatus = 'pending' | 'active' | 'expired' | 'cancelled';

export type GrantSource = 'chat' | 'device_quota';

export interface Grant {
  id: string;
  groupId: string;
  minutes: number;
  reason: string | null;
  startsAt: string;
  expiresAt: string;
  status: GrantStatus;
  source: GrantSource;
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
