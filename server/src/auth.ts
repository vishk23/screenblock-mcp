import { timingSafeEqual } from 'node:crypto';

/** Constant-time string comparison. Length-guards first (lengths aren't secret). */
export function timingSafeEqualStr(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}
