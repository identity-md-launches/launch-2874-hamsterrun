import { cleanHandle } from './game';
const key = 'hamsterrun:v3:attribution';
export interface Attribution { handle: string; visitorId: string; createdAt: string; sent?: boolean }
export function captureAttribution(url: string): Attribution | null {
  try {
    const saved = localStorage.getItem(key);
    if (saved) { const parsed = JSON.parse(saved) as Attribution; if (cleanHandle(parsed.handle) && /^[\da-f-]{36}$/i.test(parsed.visitorId)) return parsed; }
    const handle = cleanHandle(new URL(url).searchParams.get('ref') ?? '');
    if (!handle) return null;
    const attribution = { handle, visitorId: crypto.randomUUID(), createdAt: new Date().toISOString() };
    localStorage.setItem(key, JSON.stringify(attribution));
    return attribution;
  } catch { return null; }
}
async function serviceRequest(base: string, path: string, options?: RequestInit) {
  const response = await fetch(`${base.replace(/\/$/, '')}${path}`, { ...options, signal: AbortSignal.timeout(8000), credentials: 'omit' });
  if (!response.ok) throw Error('Invite service unavailable');
  return response.json();
}
export interface Leader { handle: string; invites: number }
export async function inviteLeaderboard(service: string): Promise<Leader[]> {
  const data = await serviceRequest(service, '/leaderboard') as { leaders?: Leader[] };
  if (!Array.isArray(data.leaders) || data.leaders.some(row => !cleanHandle(row.handle) || !Number.isSafeInteger(row.invites) || row.invites < 0)) throw Error('Invalid invite leaderboard');
  return data.leaders.slice(0, 20);
}
export async function sendAttribution(service: string, attribution: Attribution) {
  if (attribution.sent) return;
  await serviceRequest(service, '/attributions', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ handle: attribution.handle, visitorId: attribution.visitorId }) });
  try { localStorage.setItem(key, JSON.stringify({ ...attribution, sent: true })); } catch { /* read-only browser storage */ }
}
