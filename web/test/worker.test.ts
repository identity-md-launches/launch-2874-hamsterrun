import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import worker, { type Env, type Statement } from '../serverless/worker';

function setup() {
  const db = new DatabaseSync(':memory:'); db.exec(readFileSync(new URL('../serverless/schema.sql', import.meta.url), 'utf8'));
  const env: Env = { SITE_ORIGIN: 'https://hamster.example', DB: { prepare(sql) {
    let values: (string | number)[] = [];
    const stmt: Statement = { bind(...v) { values = v; return stmt; }, async run() { db.prepare(sql).run(...values); return { success: true }; }, async all<T>() { return { results: db.prepare(sql).all(...values) as T[] }; } }; return stmt;
  } } };
  const call = (path: string, body?: unknown, origin = env.SITE_ORIGIN) => worker.fetch(new Request(`https://invites.example${path}`, { method: body === undefined ? 'GET' : 'POST', headers: { Origin: origin, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }), env);
  return { db, call };
}
test('optional service deduplicates first attribution and returns real, ordered counts', async () => {
  const { db, call } = setup();
  const a = '11111111-1111-4111-8111-111111111111', b = '22222222-2222-4222-8222-222222222222', c = '33333333-3333-4333-8333-333333333333';
  assert.equal((await call('/attributions', { handle: '@Zed', visitorId: a })).status, 200);
  await call('/attributions', { handle: 'alice', visitorId: a }); // cannot reattribute a prior visit
  await call('/attributions', { handle: 'alice', visitorId: b });
  assert.deepEqual(await (await call('/leaderboard')).json(), { leaders: [{ handle: 'alice', invites: 1 }, { handle: 'zed', invites: 1 }] });
  await call('/attributions', { handle: 'zed', visitorId: c });
  assert.deepEqual(await (await call('/leaderboard')).json(), { leaders: [{ handle: 'zed', invites: 2 }, { handle: 'alice', invites: 1 }] });
  db.close();
});
test('service rejects cross-origin, malformed, oversized and unknown requests', async () => {
  const { db, call } = setup();
  assert.equal((await call('/attributions', {}, 'https://another.example')).status, 403);
  assert.equal((await call('/attributions', { handle: 'bad/handle', visitorId: 'bad' })).status, 400);
  assert.equal((await call('/attributions', { handle: 'a'.repeat(3000) })).status, 413);
  assert.equal((await call('/unknown')).status, 404);
  db.close();
});
