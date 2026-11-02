import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { address, words, rpcClient, finalizedBlock, CHAIN_ID, OWNER, CORE } from './rpc.mjs';

const root = new URL('../', import.meta.url);

export function artifact(name) {
  const build = JSON.parse(readFileSync(new URL(`out/${name}.sol/${name}.json`, root), 'utf8'));
  const metadata = typeof build.metadata === 'string' ? JSON.parse(build.metadata) : build.metadata;
  const s = metadata.settings;
  if (!metadata.compiler.version.startsWith('0.8.26+') || s.optimizer.enabled !== true || s.optimizer.runs !== 200
      || s.evmVersion !== 'cancun' || s.metadata.bytecodeHash !== 'none' || s.viaIR) {
    throw new Error('Artifact settings differ from the release; run forge build, not coverage');
  }
  return build;
}

export function expectedRuntime(build, immutableAddress) {
  const encodedAddress = address(immutableAddress).slice(2).padStart(64, '0');
  const object = build.deployedBytecode.object.replace(/^0x/, '');
  if (!/^(?:[\da-fA-F]{2})+$/.test(object)) throw new Error('Invalid or unlinked runtime');
  const runtime = Buffer.from(object, 'hex');
  const refs = Object.values(build.deployedBytecode.immutableReferences ?? {});
  if (refs.length !== 1 || refs[0].length === 0) throw new Error('Unexpected immutable layout');
  for (const { start, length } of refs[0]) {
    if (length !== 32 || !Number.isInteger(start) || start < 0 || start + length > runtime.length) {
      throw new Error('Invalid immutable location');
    }
    Buffer.from(encodedAddress, 'hex').copy(runtime, start);
  }
  return `0x${runtime.toString('hex')}`;
}

/** Verify both deployed runtimes and all bindings at one finalized block before producing a record. */
export async function verifyDeployment(rpc, nftInput, queueInput, builds) {
  const nft = address(nftInput), queue = address(queueInput);
  if (nft === queue || nft === CORE || queue === CORE) throw new Error('Contract addresses must be distinct');
  const { block, ref } = await finalizedBlock(rpc);
  const contracts = {};
  for (const [name, location, dependency] of [['HamsterRunNFT', nft, CORE], ['MatchQueue', queue, nft]]) {
    const expected = expectedRuntime(builds[name], dependency);
    const actual = await rpc('eth_getCode', [location, ref]);
    if (typeof actual !== 'string' || actual.toLowerCase() !== expected) {
      throw new Error(`${name} runtime does not match the release at the finalized block`);
    }
    contracts[name] = { address: location, runtimeSha256: createHash('sha256').update(Buffer.from(actual.slice(2), 'hex')).digest('hex') };
  }
  const read = async (name, location, signature) => {
    const selector = builds[name].methodIdentifiers[signature];
    if (!/^[\da-fA-F]{8}$/.test(selector)) throw new Error(`Missing selector for ${signature}`);
    return words(await rpc('eth_call', [{ to: location, data: `0x${selector}` }, ref]), 1)[0];
  };
  if (await read('HamsterRunNFT', nft, 'owner()') !== BigInt(OWNER)) throw new Error('Unexpected NFT owner');
  if (await read('HamsterRunNFT', nft, 'core()') !== BigInt(CORE)) throw new Error('Unexpected Core binding');
  if (await read('MatchQueue', queue, 'nft()') !== BigInt(nft)) throw new Error('Unexpected queue NFT binding');
  const bound = await read('HamsterRunNFT', nft, 'matchQueue()');
  if (bound !== 0n && bound !== BigInt(queue)) throw new Error('NFT is bound to a different queue');
  const mintOpen = await read('HamsterRunNFT', nft, 'mintOpen()');
  if (mintOpen !== 0n && mintOpen !== 1n) throw new Error('Invalid mintOpen response');
  const coreCode = await rpc('eth_getCode', [CORE, ref]);
  if (!/^0x(?:[\da-fA-F]{2})+$/.test(coreCode)) throw new Error('Core has no code');
  const config = words(await rpc('eth_call', [{ to: CORE, data: '0x6c70bee9' }, ref]), 11);
  const state = words(await rpc('eth_call', [{ to: CORE, data: '0xc19d93fb' }, ref]), 8);
  if (config[1] === 0n || config[2] !== 600n) throw new Error('Unsupported Core clock');
  return {
    version: '3.0.0', chainId: CHAIN_ID, network: 'sepolia', status: 'confirmed', owner: OWNER,
    upstream: { SqueekCore: CORE, abi: '../abi/SqueekCore.upstream.json' },
    verifiedAt: { blockNumber: Number(BigInt(block.number)), blockHash: block.hash, tag: 'finalized' },
    contracts, initialization: { queueBound: bound === BigInt(queue), mintOpen: mintOpen === 1n },
    coreObservation: { genesisTimestamp: config[1].toString(), settledThroughRound: state[0].toString() },
  };
}

async function main() {
  const [url, nft, queue, ...extra] = process.argv.slice(2);
  if (!url || !nft || !queue || extra.length) throw new Error('Usage: node tools/record-deployment.mjs RPC_URL NFT_ADDRESS QUEUE_ADDRESS');
  const builds = Object.fromEntries(['HamsterRunNFT', 'MatchQueue'].map(name => [name, artifact(name)]));
  const record = await verifyDeployment(rpcClient(url), nft, queue, builds);
  const target = new URL('deployments/sepolia.json', root);
  const temporary = new URL('deployments/sepolia.pending.json', root);
  writeFileSync(temporary, JSON.stringify(record, null, 2) + '\n');
  renameSync(temporary, target);
  console.log('Recorded finalized runtimes, owner, Core and queue bindings in deployments/sepolia.json.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
