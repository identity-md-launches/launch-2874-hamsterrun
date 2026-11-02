import test from 'node:test';
import assert from 'node:assert/strict';
import { artifact, expectedRuntime, verifyDeployment } from '../tools/record-deployment.mjs';
import { trainingStatus } from '../tools/training-status.mjs';
import { address, word, words, OWNER, CORE, CHAIN_ID } from '../tools/rpc.mjs';

// Local RPC fixtures only. The live parent addresses do not have this revision's simulated bytecode.
const nft = '0x140128b9208ee5de9690cd96b3bb7bc601d5b4ec';
const queue = '0x98d449abfaeaa0d0ebd0cf073f19faae24d32308';
const builds = Object.fromEntries(['HamsterRunNFT', 'MatchQueue'].map(n => [n, artifact(n)]));
const hash = `0x${'ab'.repeat(32)}`;
const encode = values => '0x' + values.map(word).join('');

function fixture(overrides = {}) {
  const model = { chainId: CHAIN_ID, owner: OWNER, core: CORE, bound: queue, mint: 0, ...overrides };
  const calls = [];
  const rpc = async (method, params) => {
    calls.push([method, params]);
    if (method === 'eth_chainId') return `0x${model.chainId.toString(16)}`;
    if (method === 'eth_getBlockByNumber') {
      assert.deepEqual(params, ['finalized', false]);
      return model.noFinalized ? null : { number: '0x1234', hash };
    }
    assert.deepEqual(params[1], { blockHash: hash, requireCanonical: true });
    if (method === 'eth_getCode') {
      if (params[0] === CORE) return model.missingCore ? '0x' : '0x1234';
      const name = params[0] === nft ? 'HamsterRunNFT' : 'MatchQueue';
      if (model.badRuntime === name) return '0x1234';
      return expectedRuntime(builds[name], name === 'HamsterRunNFT' ? CORE : nft);
    }
    assert.equal(method, 'eth_call', 'tools must never send transactions');
    const { to, data } = params[0];
    if (to === CORE && data === '0x6c70bee9') return encode([1, 1791847800, model.badDuration ? 601 : 600, 10000, 16, 1, 1, 10875, 40, 30, 1000000000]);
    if (to === CORE && data === '0xc19d93fb') return encode([1973, 148986, 1, 1, 1, 11266, 1657, 0]);
    const name = to === nft ? 'HamsterRunNFT' : 'MatchQueue';
    const methodIds = builds[name].methodIdentifiers;
    const signature = Object.keys(methodIds).find(k => data.slice(2, 10) === methodIds[k]);
    if (signature === 'trainingStatus(uint256)') {
      assert.equal(data.slice(10), word(1));
      return encode(model.status ?? [1, 2001, 2006, 1973, 0, 1, 0, 0, 0]);
    }
    const reads = { 'owner()': model.owner, 'core()': model.core, 'nft()': model.queueNFT ?? nft, 'matchQueue()': model.bound, 'mintOpen()': model.mint };
    if (!(signature in reads)) throw new Error('unexpected read');
    return encode([reads[signature]]);
  };
  return { rpc, calls };
}

test('address recorder verifies exact runtimes and immutable bindings at finality', async () => {
  const { rpc, calls } = fixture();
  const result = await verifyDeployment(rpc, nft, queue, builds);
  assert.equal(result.version, '3.0.0');
  assert.equal(result.status, 'confirmed');
  assert.equal(result.contracts.HamsterRunNFT.address, nft);
  assert.equal(result.contracts.MatchQueue.address, queue);
  assert.equal(result.owner, OWNER);
  assert.equal(result.upstream.SqueekCore, CORE);
  assert.deepEqual(result.initialization, { queueBound: true, mintOpen: false });
  assert.equal(result.verifiedAt.blockHash, hash);
  assert.ok(calls.every(([m]) => ['eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_call'].includes(m)));
});

test('recording is allowed before the owner binds the queue, with setup status explicit', async () => {
  const { rpc } = fixture({ bound: 0 });
  assert.equal((await verifyDeployment(rpc, nft, queue, builds)).initialization.queueBound, false);
});

for (const [label, change, expected] of [
  ['wrong chain', { chainId: 1 }, /not Sepolia/],
  ['no finalized block', { noFinalized: true }, /finalized/],
  ['old NFT runtime', { badRuntime: 'HamsterRunNFT' }, /runtime/],
  ['old queue runtime', { badRuntime: 'MatchQueue' }, /runtime/],
  ['wrong owner', { owner: nft }, /owner/],
  ['wrong Core', { core: nft }, /Core binding/],
  ['wrong queue NFT', { queueNFT: queue }, /queue NFT/],
  ['wrong reverse binding', { bound: nft }, /different queue/],
  ['malformed boolean', { mint: 2 }, /mintOpen/],
  ['missing upstream', { missingCore: true }, /no code/],
  ['changed round length', { badDuration: true }, /clock/],
]) {
  test(`recorder refuses ${label}`, async () => {
    await assert.rejects(verifyDeployment(fixture(change).rpc, nft, queue, builds), expected);
  });
}

test('runtime patching refuses missing or multiple immutables', () => {
  const changed = structuredClone(builds.HamsterRunNFT);
  changed.deployedBytecode.immutableReferences = {};
  assert.throws(() => expectedRuntime(changed, CORE), /layout/);
  changed.deployedBytecode.immutableReferences = { a: [{ start: 0, length: 20 }] };
  assert.throws(() => expectedRuntime(changed, CORE), /location/);
  assert.notEqual(expectedRuntime(builds.HamsterRunNFT, CORE), expectedRuntime(builds.HamsterRunNFT, nft));
});

test('status renders certification lag without promising zero work or a timer-based gain', async () => {
  const text = await trainingStatus(fixture().rpc, nft, 1, builds.HamsterRunNFT.methodIdentifiers);
  assert.match(text, /Core frontier 1973; booked rounds 2001–2006/);
  assert.match(text, /WAITING FOR CORE CERTIFICATION/);
  assert.match(text, /No gain is known yet/);
  assert.doesNotMatch(text, /0 certified physical work/);
});

test('status distinguishes certified zero work from an unknown window', async () => {
  const rpc = fixture({ status: [1, 2001, 2006, 2006, 1, 0, 0, 0, 0] }).rpc;
  const text = await trainingStatus(rpc, nft, 1, builds.HamsterRunNFT.methodIdentifiers);
  assert.match(text, /Ready to settle: 0 certified physical work; 0 stamina gain/);
  assert.doesNotMatch(text, /WAITING/);
});

test('status shows certified gain even when Core is paused', async () => {
  const rpc = fixture({ status: [1, 2001, 2006, 2010, 1, 0, 1, 5, 20] }).rpc;
  const text = await trainingStatus(rpc, nft, 1, builds.HamsterRunNFT.methodIdentifiers);
  assert.match(text, /5 certified physical work; 20 stamina gain/);
  assert.match(text, /Core is paused/);
});

test('status has no training claim for an inactive token', async () => {
  const rpc = fixture({ status: [0, 0, 0, 0, 0, 0, 0, 0, 0] }).rpc;
  assert.equal(await trainingStatus(rpc, nft, 1, builds.HamsterRunNFT.methodIdentifiers), 'No booked training window.');
});

test('RPC encodings reject missing addresses, overflowing words and malformed returns', () => {
  assert.throws(() => address('0x' + '00'.repeat(20)), /nonzero/);
  assert.throws(() => address('placeholder'), /nonzero/);
  assert.throws(() => word(-1), /uint256/);
  assert.throws(() => word(1n << 256n), /uint256/);
  assert.throws(() => words('0x00'), /Malformed/);
  assert.throws(() => words(encode([1]), 2), /length/);
});
