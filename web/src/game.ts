export type Activity = 0 | 1 | 2 | 3;
export const ACTIVITIES = ['Idle', 'Training', 'Queued', 'Matched'] as const;
export const BODY_CLASSES = ['Fit', 'Normal', 'Obese'] as const;
export function bandForStamina(stamina: bigint): bigint {
  if (stamina < 0n) throw new Error('Stamina must be positive');
  let scaled = stamina / 500n;
  let band = 0n;
  while (scaled > 0n) { band++; scaled >>= 1n; }
  return band;
}
export function bandRange(band: bigint): [bigint, bigint] {
  if (band < 0n || band > 248n) throw new Error('Invalid band');
  return band === 0n ? [0n, 499n] : [500n << (band - 1n), (500n << band) - 1n];
}
export function trainingGain(work: bigint, bps: bigint) { return 2n * work * bps / 10000n; }
export function bodyClass(score: bigint) { return score >= 70n ? 'Fit' : score >= 35n ? 'Normal' : 'Obese'; }
export function hungryAt(fedUntil: bigint, now: bigint) { return fedUntil === 0n || now > fedUntil; }
export function canFeed(activity: Activity) { return activity === 0 || activity === 1; }
export function canSettle(active: boolean, ready: boolean, coreError: boolean) { return active && ready && !coreError; }
export function fulfillState(block: bigint, entropyBlock: bigint) {
  return block <= entropyBlock ? 'waiting' : block > entropyBlock + 256n ? 'expired' : 'ready';
}
export function cleanHandle(input: string): string | null {
  const value = input.trim().replace(/^@/, '');
  return /^[A-Za-z0-9_]{1,15}$/.test(value) ? value.toLowerCase() : null;
}
export function inviteLink(base: string, handle: string) {
  const valid = cleanHandle(handle);
  if (!valid) throw new Error('Enter an X handle with 1–15 letters, numbers or underscores.');
  const url = new URL(base); url.search = ''; url.hash = ''; url.searchParams.set('ref', valid);
  return url.toString();
}
export const fmt = (n: bigint | number) => n.toLocaleString('en-US');
export const shortAddress = (s: string) => `${s.slice(0, 6)}…${s.slice(-4)}`;
export const canonical = (value: unknown): unknown => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.entries(value).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0).map(([k, v]) => [k, canonical(v)])) : value;
export function fedLabel(fedUntil: bigint, now: bigint) {
  if (hungryAt(fedUntil, now)) return 'Hungry';
  const seconds = fedUntil - now;
  return seconds < 3600n ? `${seconds / 60n}m left` : `${seconds / 3600n}h ${seconds % 3600n / 60n}m left`;
}
