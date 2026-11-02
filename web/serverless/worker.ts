import { cleanHandle } from '../src/game';

export interface Statement {
  bind(...values: (string | number)[]): Statement;
  run(): Promise<{ success: boolean }>;
  all<T>(): Promise<{ results: T[] }>;
}
export interface Env { DB: { prepare(sql: string): Statement }; SITE_ORIGIN: string }
const json = (value: unknown, status: number, origin: string) => new Response(JSON.stringify(value), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'Vary': 'Origin', 'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'X-Content-Type-Options': 'nosniff' },
});
/** Optional, separately hosted anonymous first-visit service. No wallet or X authentication. */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (!env.DB || !/^https:\/\//.test(env.SITE_ORIGIN ?? '')) return json({ error: 'Invite service not configured' }, 503, 'null');
    const origin = request.headers.get('Origin');
    if (origin && origin !== env.SITE_ORIGIN) return json({ error: 'Origin not allowed' }, 403, env.SITE_ORIGIN);
    const reply = (data: unknown, status = 200) => json(data, status, env.SITE_ORIGIN);
    if (request.method === 'OPTIONS') return reply({});
    const path = new URL(request.url).pathname;
    try {
      if (path === '/leaderboard' && request.method === 'GET') {
        const rows = await env.DB.prepare('SELECT handle, COUNT(*) AS invites FROM attributions GROUP BY handle ORDER BY invites DESC, handle ASC LIMIT 20').all<{ handle: string; invites: number }>();
        return reply({ leaders: rows.results });
      }
      if (path === '/attributions' && request.method === 'POST') {
        if (origin !== env.SITE_ORIGIN) return reply({ error: 'Site origin required' }, 403);
        if (!request.headers.get('Content-Type')?.startsWith('application/json')) return reply({ error: 'JSON required' }, 415);
        if (Number(request.headers.get('Content-Length') ?? 0) > 2048) return reply({ error: 'Payload too large' }, 413);
        const text = await request.text();
        if (text.length > 2048) return reply({ error: 'Payload too large' }, 413);
        let data: { handle?: unknown; visitorId?: unknown };
        try { data = JSON.parse(text); } catch { return reply({ error: 'Invalid JSON' }, 400); }
        if (!data || typeof data.handle !== 'string' || typeof data.visitorId !== 'string') return reply({ error: 'Handle and visitorId required' }, 400);
        const handle = cleanHandle(data.handle);
        if (!handle || !/^[\da-f]{8}-[\da-f]{4}-4[\da-f]{3}-[89ab][\da-f]{3}-[\da-f]{12}$/i.test(data.visitorId)) return reply({ error: 'Invalid handle or visitorId' }, 400);
        const result = await env.DB.prepare('INSERT INTO attributions (visitor_id, handle) VALUES (?, ?) ON CONFLICT(visitor_id) DO NOTHING').bind(data.visitorId.toLowerCase(), handle).run();
        if (!result.success) throw Error('Insert failed');
        return reply({ recorded: true });
      }
      return reply({ error: 'Not found' }, 404);
    } catch { return reply({ error: 'Invite service temporarily unavailable' }, 503); }
  },
};
