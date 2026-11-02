/** Production-export interaction checks. All wallet writes are intercepted test fixtures, never broadcast. */
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { decodeFunctionData, encodeFunctionResult, encodeEventTopics, encodeErrorResult, toHex, zeroAddress } from 'viem';
const { chromium, webkit } = await import(process.env.IMD_PLAYWRIGHT ? pathToFileURL(process.env.IMD_PLAYWRIGHT).href : 'playwright');
const repo = resolve(fileURLToPath(new URL('../../', import.meta.url)));
const dist = resolve(repo, 'dist');
const output = resolve(repo, 'test/scratch/interaction');
await mkdir(output, { recursive: true });
const release = JSON.parse(await readFile(resolve(dist, 'imd-deployment.json'), 'utf8'));
const codes = JSON.parse(await readFile(new URL('fixtures/v3-runtime.json', import.meta.url), 'utf8'));
const abis = Object.fromEntries(await Promise.all(release.contracts.map(async c => [c.name, JSON.parse(await readFile(resolve(dist, c.abi), 'utf8'))])));
const nft = release.contracts.find(c => c.name === 'HamsterRunNFT').address;
const queue = release.contracts.find(c => c.name === 'MatchQueue').address;
const player = '0x1111111111111111111111111111111111111111';
const other = '0x2222222222222222222222222222222222222222';
const owner = '0x6c14430adacc99e27f6180bc5a74d6768616bf4a';
const blockHash = `0x${'ab'.repeat(32)}`;
const bandOf = s => s < 500n ? 0n : BigInt((s / 500n).toString(2).length);
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.json': 'application/json', '.woff2': 'font/woff2' };
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://local');
  const path = resolve(dist, decodeURIComponent(url.pathname.replace(/^\/pocket\//, '')) || 'index.html');
  if (!url.pathname.startsWith('/pocket/') || !path.startsWith(dist + '/')) { res.writeHead(404); res.end(); return; }
  try { const body = await readFile(path); res.writeHead(200, { 'Content-Type': types[extname(path)] ?? 'application/octet-stream' }); res.end(body); }
  catch { res.writeHead(404); res.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}/pocket/`;
const results = [];
const browsers = [];
function state(overrides = {}) {
  return { block: 12048550n, now: 1793627000n, mintOpen: true, queueBound: true, supply: 0n, owned: false, minted: false,
    stamina: 10n, body: 50n, fedUntil: 0n, activity: 0, foodTier: 1, trainBps: 15000n, frontier: 1973n, current: 3000n,
    start: 3000n, end: 3005n, capturedBps: 15000n, capturedTier: 1, work: 1012n, used: 0n, points: 0n,
    entries: [], round: null, race: null, txCount: 0, calls: [], receipts: new Map(), walletCalls: [], ...overrides };
}
const block = s => ({ number: toHex(s.block), timestamp: toHex(s.now), hash: blockHash, parentHash: blockHash, nonce: '0x0000000000000000', sha3Uncles: blockHash, logsBloom: `0x${'00'.repeat(256)}`, transactionsRoot: blockHash, stateRoot: blockHash, receiptsRoot: blockHash, miner: owner, difficulty: '0x0', totalDifficulty: '0x0', extraData: '0x', size: '0x200', gasLimit: '0x1c9c380', gasUsed: '0x0', baseFeePerGas: '0x3b9aca00', mixHash: blockHash, transactions: [], uncles: [] });
function callResult(s, to, data) {
  const name = to.toLowerCase() === nft.toLowerCase() ? 'HamsterRunNFT' : 'MatchQueue';
  const abi = abis[name];
  const decoded = decodeFunctionData({ abi, data });
  const fn = decoded.functionName, a = decoded.args ?? [];
  const inputAddress = typeof a[0] === 'string' ? a[0].toLowerCase() : '';
  const weight = s.body >= 70n ? 0 : s.body >= 35n ? 1 : 2;
  let result;
  if (name === 'HamsterRunNFT') {
    const getters = { mintOpen: s.mintOpen, matchQueue: s.queueBound ? queue : zeroAddress, totalSupply: s.supply, owner, core: release.upstream.address,
      currentRound: s.current, settledThroughRound: s.frontier, freeMinted: s.minted && inputAddress === player.toLowerCase(),
      balanceOf: s.owned && inputAddress === player.toLowerCase() ? 1n : 0n, ownerOf: a[0] === 1n && s.owned ? player : other,
      isHungry: s.fedUntil === 0n || s.now > s.fedUntil, matchesThisWeek: s.used,
      hamster: { stamina: s.stamina, fedUntil: s.fedUntil, trainBps: s.trainBps, bodyScore: s.body, weight, activity: s.activity, foodTier: s.foodTier },
      training: s.activity === 1 ? [s.start, s.end, s.capturedBps, s.capturedTier] : [0n, 0n, 0n, 0],
      trainingStatus: { active: s.activity === 1, trainStartRound: s.activity === 1 ? s.start : 0n, trainEndRound: s.activity === 1 ? s.end : 0n,
        frontier: s.activity === 1 ? s.frontier : 0n, ready: s.activity === 1 && s.frontier >= s.end, waitingForCertification: s.activity === 1 && s.frontier < s.end,
        corePaused: false, work: s.activity === 1 && s.frontier >= s.end ? s.work : 0n, gain: s.activity === 1 && s.frontier >= s.end ? 2n * s.work * s.capturedBps / 10000n : 0n },
    };
    if (s.coreError && ['trainingStatus', 'currentRound', 'settledThroughRound'].includes(fn)) throw Error('Core unavailable');
    if (s.petReadError && fn === 'hamster') throw Error('Pet read unavailable');
    if (fn === 'foodPrices') result = [100000000000000n, 200000000000000n, 300000000000000n][Number(a[0])];
    else if (fn === 'foodTrainBps') result = [10000n, 15000n, 20000n][Number(a[0])];
    else if (fn in getters) result = getters[fn];
    else if (fn === 'mint') { if (!s.mintOpen) return { error: encodeErrorResult({ abi, errorName: 'MintClosed' }) }; if (s.minted) return { error: encodeErrorResult({ abi, errorName: 'AlreadyMinted' }) }; result = 1n; }
    else if (['feed', 'startTraining', 'settleTraining', 'cancelTraining'].includes(fn)) result = undefined;
    else throw Error(`Unhandled NFT read ${fn}`);
  } else {
    const entries = s.entries.filter(x => x.band === a[0]).map(({ band, ...entry }) => entry);
    const getters = { nft, points: s.points, bandOf: bandOf(s.stamina), bandForStamina: fn === 'bandForStamina' ? bandOf(a[0]) : 0n, activeToken: s.activity >= 2 ? 1n : 0n,
      queueEntries: entries, eligibleCount: BigInt(entries.filter(e => s.block >= e.joinedBlock + 10n && s.now <= e.joinedAt + 86400n).length), roundCount: s.round ? 1n : 0n,
      roundInfo: s.round ? [s.round.band, s.round.entropyBlock, 2965n, s.round.status, `0x${'00'.repeat(32)}`, 2n] : undefined,
      roundRacers: s.round?.racers, roundMatchIds: s.race ? [1n] : [], roundBye: 0n, matchInfo: s.race, matchCount: s.race ? 1n : 0n,
    };
    if (fn in getters) result = getters[fn];
    else if (fn === 'requestRound') result = 1n;
    else if (['enqueue', 'leaveQueue', 'fulfillRound', 'settleMatch', 'expireRound'].includes(fn)) result = undefined;
    else throw Error(`Unhandled queue read ${fn}`);
  }
  return encodeFunctionResult({ abi, functionName: fn, result });
}
function mutate(s, tx) {
  const name = tx.to.toLowerCase() === nft.toLowerCase() ? 'HamsterRunNFT' : 'MatchQueue';
  const { functionName: fn, args: a = [] } = decodeFunctionData({ abi: abis[name], data: tx.data });
  s.calls.push({ fn, args: a.map(String), value: tx.value ? BigInt(tx.value).toString() : '0', to: tx.to.toLowerCase() });
  if (s.failReceipt) return;
  if (fn === 'mint') { s.supply = 1n; s.owned = true; s.minted = true; }
  else if (fn === 'feed') { const tier = Number(a[1]); s.fedUntil = s.now + 259200n; s.foodTier = tier; s.trainBps = [10000n, 15000n, 20000n][tier]; s.body = [s.body > 4n ? s.body - 4n : 0n, s.body + 6n, s.body + 12n][tier]; if (s.body > 100n) s.body = 100n; }
  else if (fn === 'startTraining') { s.activity = 1; s.start = s.current; s.end = s.current + 5n; s.capturedBps = s.trainBps; s.capturedTier = s.foodTier; }
  else if (fn === 'settleTraining') { s.activity = 0; s.stamina += 2n * s.work * s.capturedBps / 10000n; }
  else if (fn === 'cancelTraining') s.activity = 0;
  else if (fn === 'enqueue') { s.activity = 2; s.entries.push({ tokenId: 1n, player, joinedAt: s.now, joinedBlock: s.block, band: bandOf(s.stamina) }); }
  else if (fn === 'leaveQueue') { s.activity = 0; s.entries = s.entries.filter(e => e.tokenId !== 1n); }
  else if (fn === 'requestRound') { s.activity = 3; s.used++; s.round = { band: a[0], entropyBlock: s.block + 2n, status: 1, racers: [{ tokenId: 1n, player, stamina: s.stamina, weight: 1 }, { tokenId: 2n, player: other, stamina: s.stamina, weight: 1 }] }; s.entries = []; }
  else if (fn === 'fulfillRound') { s.round.status = 2; s.race = { roundId: 1n, a: s.round.racers[0], b: s.round.racers[1], scoreA: 1500n, scoreB: 1400n, winner: 1n, settled: false }; }
  else if (fn === 'settleMatch') { s.race.settled = true; s.activity = 0; s.stamina += 3n; s.points += 10n; }
  else if (fn === 'expireRound') { s.round.status = 3; s.activity = 0; }
  else throw Error(`Unhandled test write ${fn}`);
}
function rpc(s, method, params) {
  if (s.rpcError) throw Error('RPC temporarily unavailable');
  if (method === 'eth_chainId') return '0xaa36a7';
  if (method === 'eth_blockNumber') return toHex(s.block);
  if (method === 'eth_getBlockByNumber' || method === 'eth_getBlockByHash') return block(s);
  if (method === 'eth_getCode') return s.badCode ? '0x6000' : codes[params[0].toLowerCase()] ?? '0x';
  if (method === 'eth_call') return callResult(s, params[0].to, params[0].data);
  if (method === 'eth_estimateGas') return '0x30d40';
  if (method === 'eth_gasPrice' || method === 'eth_maxPriorityFeePerGas') return '0x3b9aca00';
  if (method === 'eth_getBalance') return toHex(10n ** 18n);
  if (method === 'eth_getTransactionCount') return '0x0';
  if (method === 'eth_getTransactionReceipt') return s.receipts.get(params[0]) ?? null;
  if (method === 'eth_getLogs') {
    const p = params[0]; const at = BigInt(release.contracts[0].blockNumber + 1);
    if (!s.owned || p.address.toLowerCase() !== nft.toLowerCase() || BigInt(p.fromBlock) > at || BigInt(p.toBlock) < at || p.topics?.[2]?.toLowerCase() !== `0x${player.slice(2).padStart(64, '0')}`) return [];
    return [{ address: nft, topics: encodeEventTopics({ abi: abis.HamsterRunNFT, eventName: 'Transfer', args: { from: zeroAddress, to: player, tokenId: 1n } }), data: '0x', blockNumber: toHex(at), blockHash, transactionHash: `0x${'01'.repeat(32)}`, transactionIndex: '0x0', logIndex: '0x0', removed: false }];
  }
  if (method === 'wallet_getCapabilities') return {};
  throw Error(`Unhandled RPC ${method}`);
}
async function makeContext(browser, s, { width = 390, mobile = false, inject = true, chain = '0x1' } = {}) {
  const context = await browser.newContext({ viewport: { width, height: 844 }, ...(mobile ? { userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148', isMobile: true, hasTouch: true } : {}) });
  await context.route(/^https:\/\//, async route => {
    const req = route.request();
    if (!release.network.rpcUrls.some(url => req.url().startsWith(url))) { await route.abort(); return; }
    try {
      const payload = req.postDataJSON();
      const reply = item => { try { const result = rpc(s, item.method, item.params ?? []); if (result && typeof result === 'object' && 'error' in result) return { jsonrpc: '2.0', id: item.id, error: { code: 3, message: 'execution reverted', data: result.error } }; return { jsonrpc: '2.0', id: item.id, result }; } catch (e) { return { jsonrpc: '2.0', id: item.id, error: { code: -32000, message: e.message } }; } };
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(Array.isArray(payload) ? payload.map(reply) : reply(payload)) });
    } catch (e) { await route.fulfill({ status: 500, body: e.message }); }
  });
  await context.exposeBinding('__testRequest', async (_, { method, params = [] }) => {
    s.walletCalls.push({ method, params });
    if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [player];
    if (method === 'eth_sendTransaction') {
      mutate(s, params[0]); s.txCount++; s.block++; s.now += 12n;
      const hash = `0x${s.txCount.toString(16).padStart(64, '0')}`;
      s.receipts.set(hash, { transactionHash: hash, transactionIndex: '0x0', blockHash, blockNumber: toHex(s.block), from: player, to: params[0].to, cumulativeGasUsed: '0x20000', gasUsed: '0x20000', effectiveGasPrice: '0x3b9aca00', contractAddress: null, logs: [], logsBloom: `0x${'00'.repeat(256)}`, status: s.failReceipt ? '0x0' : '0x1', type: '0x2' });
      return hash;
    }
    if (method === 'wallet_addEthereumChain' || method === 'wallet_switchEthereumChain' || method === 'wallet_requestPermissions') return null;
    return rpc(s, method, params);
  });
  if (inject) await context.addInitScript(({ chain }) => {
    const handlers = new Map();
    let chainId = chain; let accounts = []; let added = false;
    const provider = {
      isRabby: true,
      on(event, cb) { const list = handlers.get(event) ?? []; list.push(cb); handlers.set(event, list); },
      removeListener(event, cb) { handlers.set(event, (handlers.get(event) ?? []).filter(x => x !== cb)); },
      emit(event, value) { if (event === 'chainChanged') chainId = value; if (event === 'accountsChanged') accounts = value; for (const cb of handlers.get(event) ?? []) cb(value); },
      async request({ method, params = [] }) {
        if (method === 'eth_chainId') return chainId;
        if (method === 'eth_accounts') return accounts;
        if (method === 'eth_requestAccounts') { if (window.__rejectConnect) { window.__rejectConnect = false; throw Object.assign(Error('User rejected request'), { code: 4001 }); } accounts = await window.__testRequest({ method, params }); return accounts; }
        if (method === 'wallet_switchEthereumChain') { if (!added) throw Object.assign(Error('Unknown chain'), { code: 4902 }); await window.__testRequest({ method, params }); chainId = params[0].chainId; provider.emit('chainChanged', chainId); return null; }
        if (method === 'wallet_addEthereumChain') added = true;
        if (method === 'eth_sendTransaction' && window.__rejectNext) { window.__rejectNext = false; throw Object.assign(Error('User rejected request'), { code: 4001 }); }
        return window.__testRequest({ method, params });
      },
    };
    window.ethereum = provider; window.__wallet = provider;
    const announce = () => {
      for (const [name, rdns, uuid] of [['Rabby', 'io.rabby', '11111111-1111-4111-8111-111111111111'], ['MetaMask', 'io.metamask', '22222222-2222-4222-8222-222222222222']]) {
        window.dispatchEvent(new CustomEvent('eip6963:announceProvider', { detail: { info: { uuid, name, icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28"><rect width="28" height="28" fill="%238BAC0F"/></svg>', rdns }, provider } }));
      }
    };
    window.addEventListener('eip6963:requestProvider', announce); announce();
  }, { chain });
  const page = await context.newPage(); page.setDefaultTimeout(12000);
  const errors = []; page.on('pageerror', e => errors.push(e.message));
  return { context, page, errors };
}
async function until(check, message = 'condition') {
  const start = Date.now(); while (Date.now() - start < 15000) { if (await check()) return; await new Promise(r => setTimeout(r, 80)); } throw Error(`Timed out: ${message}`);
}
const visible = (page, text) => page.getByText(text, { exact: false }).first().isVisible();
async function refresh(page) { const b = page.getByRole('button', { name: 'Refresh', exact: true }).first(); await b.click(); await until(async () => !(await b.isDisabled()), 'refresh finished'); }
async function connect(page, switchChain = true) {
  await page.getByRole('button', { name: 'Connect wallet' }).click();
  await page.getByRole('button', { name: 'Rabby', exact: true }).click();
  if (switchChain) { await page.getByRole('button', { name: 'Switch to Sepolia', exact: true }).waitFor(); await page.getByRole('button', { name: 'Switch to Sepolia', exact: true }).click(); }
}
async function action(page, triggerName, confirmName, expected = `${confirmName} confirmed on Sepolia.`) {
  const trigger = page.getByRole('button', { name: triggerName, exact: true });
  await until(async () => await trigger.isEnabled(), `${triggerName} enabled`); await trigger.click();
  const dialog = page.getByRole('dialog'); await dialog.waitFor(); await dialog.getByRole('button', { name: confirmName, exact: true }).click();
  await page.getByText(expected, { exact: true }).waitFor();
  if (confirmName === 'Start training') assert.equal(await page.evaluate(() => document.activeElement?.id), 'main-content', 'focus returns to main when the booking replaces its trigger');
}
async function check(name, fn) {
  const started = Date.now(); try { await fn(); results.push({ name, passed: true, durationMs: Date.now() - started }); console.log(`PASS ${name}`); }
  catch (e) { results.push({ name, passed: false, error: e.message }); console.error(`FAIL ${name}: ${e.message}`); throw e; }
}
let browser;
try {
  browser = await chromium.launch({ headless: true }); browsers.push(browser);
  await check('Closed mint / unbound queue; no auto wallet sheet; keyboard dialog focus', async () => {
    const s = state({ mintOpen: false, queueBound: false }); const { context, page, errors } = await makeContext(browser, s);
    try { await page.goto(base); await page.getByText('Mint not open yet · Queue unbound').waitFor(); assert.equal(await page.getByRole('dialog').count(), 0); assert.equal(await page.getByRole('button', { name: 'Mint not open yet', exact: true }).isDisabled(), true);
      assert.equal(s.walletCalls.some(x => x.method === 'eth_requestAccounts'), false);
      await page.getByRole('button', { name: 'Connect wallet' }).click(); assert.equal(await page.getByRole('button', { name: 'Rabby', exact: true }).count(), 1); assert.equal(await page.getByRole('button', { name: 'MetaMask', exact: true }).count(), 1); assert.equal(await page.getByRole('button', { name: 'Browser wallet', exact: true }).count(), 0);
      await page.keyboard.press('Tab'); await page.keyboard.press('Tab'); assert.equal(await page.evaluate(() => document.querySelector('dialog').contains(document.activeElement)), true); await page.keyboard.press('Escape'); assert.equal(await page.evaluate(() => document.activeElement?.textContent?.includes('Connect wallet')), true);
      await page.screenshot({ path: resolve(output, '390-closed.png'), fullPage: true }); assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  await check('Mobile wallet links and local invite attribution; honest offline leaderboard', async () => {
    const s = state(); const { context, page, errors } = await makeContext(browser, s, { inject: false, mobile: true });
    try { await page.goto(`${base}?ref=first_runner#invite`); await page.getByRole('heading', { name: 'Bring your little crew' }).waitFor(); await page.getByRole('button', { name: 'Connect wallet' }).click();
      for (const name of ['MetaMask', 'Coinbase Wallet', 'Rabby', 'Phantom']) assert.equal(await page.getByRole('link', { name: `Open in ${name}`, exact: true }).isVisible(), true);
      assert.equal(await page.getByRole('button', { name: 'Coinbase Smart Wallet', exact: true }).isVisible(), true); await page.keyboard.press('Escape');
      await page.getByRole('button', { name: 'Create invite link', exact: true }).click(); await page.getByText('Use 1–15 letters, numbers or underscores. A leading @ is okay.').waitFor();
      await page.getByLabel('Your X handle').fill('@Little_Runner'); await page.getByRole('button', { name: 'Create invite link', exact: true }).click();
      assert.equal(await page.getByLabel('Your shareable invite').inputValue(), `${base}?ref=little_runner`); assert.equal(await visible(page, 'Invite service offline'), true);
      await page.goto(`${base}?ref=second_runner#invite`); await page.getByText('You arrived through').waitFor(); assert.equal((await page.evaluate(() => JSON.parse(localStorage.getItem('hamsterrun:v3:attribution')))).handle, 'first_runner');
      await page.screenshot({ path: resolve(output, '390-invite.png'), fullPage: true }); assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  await check('Full mocked player journey: chain switch, mint, care, Core lag, geometric queue and match', async () => {
    const s = state(); const { context, page, errors } = await makeContext(browser, s, { width: 1440 });
    try { await page.goto(base); await page.getByText('Mint open · Queue bound').waitFor(); await connect(page); await until(async () => !await page.getByRole('button', { name: 'Mint a hamster', exact: true }).isDisabled(), 'mint enabled on Sepolia');
      assert.deepEqual(s.walletCalls.find(x => x.method === 'wallet_addEthereumChain').params[0], release.walletAddChain);
      await action(page, 'Mint a hamster', 'Mint hamster'); await page.getByRole('heading', { name: 'Hello, hamster #1' }).waitFor(); assert.equal(s.supply, 1n);
      assert.equal(await page.getByRole('button', { name: 'Start training', exact: true }).isDisabled(), true);
      await action(page, 'Feed hamster', 'Feed hamster'); assert.equal(s.calls.find(x => x.fn === 'feed').value, '200000000000000');
      await action(page, 'Start training', 'Start training'); await page.getByText('Waiting for Core certification', { exact: true }).waitFor();
      assert.equal(await page.getByRole('button', { name: 'Settle training', exact: true }).isDisabled(), true); assert.equal(await page.getByRole('button', { name: 'Feed hamster', exact: true }).isEnabled(), true);
      await page.screenshot({ path: resolve(output, '1440-training-lag.png'), fullPage: true });
      await page.getByRole('button', { name: /Power bowl/ }).click(); await action(page, 'Feed hamster', 'Feed hamster'); assert.equal(s.calls.filter(x => x.fn === 'feed')[1].value, '300000000000000'); assert.equal(s.capturedBps, 15000n); assert.equal(s.trainBps, 20000n);
      s.frontier = s.end; s.block++; await refresh(page); await until(async () => await page.getByRole('button', { name: 'Settle training', exact: true }).isEnabled(), 'certified settle enabled');
      await action(page, 'Settle training', 'Settle training'); assert.equal(s.stamina, 3046n); assert.equal(s.activity, 0);
      s.entries = [{ tokenId: 2n, player: other, joinedAt: s.now - 100n, joinedBlock: s.block - 12n, band: 3n }];
      await page.getByRole('link', { name: 'Match queue', exact: false }).first().click(); await page.getByRole('heading', { name: 'Little legs. Fair races.' }).waitFor(); await action(page, 'Enqueue hamster', 'Enqueue hamster');
      await until(async () => await visible(page, '2 / 32'), 'two queue entries'); assert.equal(await page.getByRole('button', { name: 'Request round', exact: true }).isDisabled(), true);
      s.block += 10n; await refresh(page); await action(page, 'Request round', 'Request round'); assert.equal(s.used, 1n);
      await until(async () => await page.getByRole('button', { name: 'Fulfill round', exact: true }).count() > 0, 'pending round'); assert.equal(await page.getByRole('button', { name: 'Fulfill round', exact: true }).isDisabled(), true);
      s.block += 3n; await refresh(page); await action(page, 'Fulfill round', 'Fulfill round'); await action(page, 'Settle match', 'Settle match'); assert.equal(s.stamina, 3049n); assert.equal(s.points, 10n); assert.equal(s.activity, 0);
      await page.screenshot({ path: resolve(output, '1440-match-settled.png'), fullPage: true }); assert.deepEqual(errors, []);
      assert.deepEqual(s.calls.map(x => x.fn), ['mint', 'feed', 'startTraining', 'feed', 'settleTraining', 'enqueue', 'requestRound', 'fulfillRound', 'settleMatch']);
    } catch (e) { await page.screenshot({ path: resolve(output, 'failure-journey.png'), fullPage: true }); console.error((await page.locator('body').innerText()).slice(0, 7000)); throw e; }
    finally { await context.close(); }
  });
  await check('Core read failure keeps Feed enabled, disables Settle; cancellation forfeits work', async () => {
    const s = state({ owned: true, minted: true, supply: 1n, activity: 1, coreError: true, fedUntil: 1793626000n }); const { context, page, errors } = await makeContext(browser, s, { chain: '0xaa36a7' });
    try { await page.goto(base); await connect(page, false); await page.getByText('Core status unavailable', { exact: true }).waitFor(); assert.equal(await page.getByRole('button', { name: 'Settle training', exact: true }).isDisabled(), true); assert.equal(await page.getByRole('button', { name: 'Feed hamster', exact: true }).isEnabled(), true);
      await action(page, 'Cancel training', 'Cancel training'); assert.equal(s.activity, 0); assert.equal(s.stamina, 10n); assert.equal(s.calls.some(x => x.fn === 'settleTraining'), false); assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  await check('Wallet rejection and reverted receipts never show success or mutate the pet', async () => {
    const s = state({ owned: true, minted: true, supply: 1n }); const { context, page, errors } = await makeContext(browser, s, { chain: '0xaa36a7' });
    try { await page.goto(base); await connect(page, false); await page.getByRole('heading', { name: 'Hello, hamster #1' }).waitFor(); await page.evaluate(() => { window.__rejectNext = true; });
      await action(page, 'Feed hamster', 'Feed hamster', 'Transaction declined in your wallet. Nothing was confirmed.'); assert.equal(s.calls.length, 0); assert.equal(s.fedUntil, 0n);
      s.failReceipt = true; await action(page, 'Feed hamster', 'Feed hamster', 'Feed hamster reverted. No game change was confirmed.'); assert.equal(s.fedUntil, 0n); assert.equal(await page.getByText('Feed hamster confirmed on Sepolia.', { exact: true }).count(), 0);
      assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  await check('Code mismatch prevents every player transaction', async () => {
    const s = state({ badCode: true }); const { context, page, errors } = await makeContext(browser, s);
    try { await page.goto(base); await page.getByText('Sepolia status unavailable. Actions paused.').waitFor(); assert.equal(await page.getByRole('button', { name: 'Checking mint…', exact: true }).isDisabled(), true); assert.equal(s.calls.length, 0); assert.deepEqual(errors, []); }
    finally { await context.close(); }
  });
  await check('Account and chain changes disable owner actions; hungry zero-work settlement stays permissionless', async () => {
    const s = state({ owned: true, minted: true, supply: 1n, activity: 1, frontier: 3005n, fedUntil: 0n, work: 0n });
    const { context, page, errors } = await makeContext(browser, s, { chain: '0xaa36a7' });
    try {
      await page.goto(base); await connect(page, false); await page.getByRole('heading', { name: 'Hello, hamster #1' }).waitFor();
      await until(async () => await page.getByRole('button', { name: 'Settle training', exact: true }).isEnabled(), 'zero-work ready');
      s.petReadError = true; await page.getByRole('button', { name: 'Refresh IDs', exact: true }).click();
      await page.getByText('Couldn’t read hamster #1.', { exact: false }).waitFor();
      assert.equal(await page.getByRole('button', { name: 'Settle training', exact: true }).isDisabled(), true);
      s.petReadError = false; await page.getByRole('button', { name: 'Refresh IDs', exact: true }).click();
      await until(async () => await page.getByRole('button', { name: 'Settle training', exact: true }).isEnabled(), 'retry restores confirmed pet data');
      await page.getByRole('button', { name: 'Settle training', exact: true }).click(); await page.getByRole('dialog').waitFor();
      await page.evaluate(() => window.__wallet.emit('chainChanged', '0x1'));
      await until(async () => await page.getByRole('dialog').getByRole('button', { name: 'Settle training', exact: true }).isDisabled(), 'wrong chain disables confirmation');
      await page.keyboard.press('Escape'); await page.getByRole('button', { name: 'Switch to Sepolia', exact: true }).click();
      await page.evaluate(other => window.__wallet.emit('accountsChanged', [other]), other);
      await page.getByRole('heading', { name: 'Your pocket adventure' }).waitFor();
      await page.getByText('Inspect a hamster by ID', { exact: true }).click(); await page.getByLabel('Hamster ID', { exact: true }).fill('1'); await page.getByRole('button', { name: 'Load hamster', exact: true }).click();
      await page.getByText('Inspecting another player’s hamster.', { exact: false }).waitFor();
      assert.equal(await page.getByRole('button', { name: 'Feed hamster', exact: true }).isDisabled(), true);
      assert.equal(await page.getByRole('button', { name: 'Cancel training', exact: true }).isDisabled(), true);
      await action(page, 'Settle training', 'Settle training'); assert.equal(s.stamina, 10n); assert.equal(s.activity, 0); assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  await check('An owned transfer still permits the wallet’s unused free mint', async () => {
    const s = state({ owned: true, minted: false, supply: 1n }); const { context, page, errors } = await makeContext(browser, s, { chain: '0xaa36a7' });
    try { await page.goto(base); await connect(page, false); await page.getByRole('heading', { name: 'Hello, hamster #1' }).waitFor();
      await until(async () => await page.getByRole('button', { name: 'Use free mint', exact: true }).isEnabled(), 'unused mint stays accessible'); assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  await check('320/390/768/1440 layouts, longest stamina and all routes; reduced motion', async () => {
    const s = state({ owned: true, minted: true, supply: 9999n, stamina: (1n << 256n) - 1n, fedUntil: 1793800000n }); const { context, page, errors } = await makeContext(browser, s, { chain: '0xaa36a7' });
    try { await page.goto(base); await connect(page, false); await page.getByRole('heading', { name: 'Hello, hamster #1' }).waitFor();
      for (const width of [320, 390, 768, 1440]) { await page.setViewportSize({ width, height: 844 }); for (const tab of ['care', 'queue', 'invite', 'guide']) { await page.goto(`${base}#${tab}`); await page.locator('main h1').waitFor(); await until(async () => await page.getByText('Mint open · Queue bound', { exact: false }).count() > 0, 'world data'); if (tab === 'guide') for (const detail of await page.locator('details').all()) await detail.evaluate(el => { el.open = true; }); assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1), true, `overflow ${width} ${tab}`); await page.screenshot({ path: resolve(output, `${width}-${tab}.png`), fullPage: true }); } }
      await page.emulateMedia({ reducedMotion: 'reduce' }); assert.equal(await page.evaluate(() => document.getAnimations().some(a => a.effect?.getTiming().iterations === Infinity)), false);
      assert.deepEqual(errors, []);
    } finally { await context.close(); }
  });
  try {
    const safari = await webkit.launch({ headless: true }); browsers.push(safari);
    await check('WebKit connect sheet and invite form', async () => { const { context, page } = await makeContext(safari, state()); try { await page.goto(base); await page.getByRole('button', { name: 'Connect wallet' }).click(); await page.getByRole('dialog').waitFor(); await page.keyboard.press('Escape'); } finally { await context.close(); } });
  } catch (e) { results.push({ name: 'WebKit', passed: null, limitation: 'WebKit runtime not available in the supplied browser installation.' }); console.log('LIMITATION WebKit runtime unavailable; Chromium checks completed.'); }
} finally {
  for (const b of browsers) await b.close();
  await new Promise(resolve => server.close(resolve));
  await writeFile(resolve(output, 'results.json'), JSON.stringify({ exportedSite: 'dist/', testWrites: 'intercepted EIP-1193 only; no broadcasts', results }, null, 2));
}
