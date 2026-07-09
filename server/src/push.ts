export interface Push {
  /** Fire-and-forget: notify device(s) that policy changed at `changedAt`. */
  policyChanged(changedAt: Date, description: string): void;
}
