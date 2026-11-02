import { readFile } from 'node:fs/promises';
import { createPublicClient, fallback, http, keccak256 } from 'viem';
const release = JSON.parse(await readFile(new URL('../deployment.json', import.meta.url), 'utf8'));
const abis = Object.fromEntries(await Promise.all(release.contracts.map(async c => [c.name, JSON.parse(await readFile(new URL(`../../abi/${c.name}.json`, import.meta.url), 'utf8'))])));
const client = createPublicClient({ transport: fallback(release.network.rpcUrls.map(url => http(url, { timeout: 15000, retryCount: 1 }))) });
if (await client.getChainId() !== release.chainId) throw Error('RPC returned the wrong chain');
const block = await client.getBlock();
for (const c of release.contracts) {
  const code = await client.getBytecode({ address: c.address, blockNumber: block.number });
  if (!code || keccak256(code) !== c.runtimeCodeHash) throw Error(`Runtime mismatch: ${c.name}`);
}
const nft = release.contracts.find(c => c.name === 'HamsterRunNFT');
const queue = release.contracts.find(c => c.name === 'MatchQueue');
const read = (c, fn, args = []) => client.readContract({ address: c.address, abi: abis[c.name], functionName: fn, args, blockNumber: block.number });
if ((await read(queue, 'nft')).toLowerCase() !== nft.address.toLowerCase()) throw Error('Wrong queue NFT');
if ((await read(nft, 'core')).toLowerCase() !== release.upstream.address.toLowerCase()) throw Error('Wrong Core');
const [mintOpen, matchQueue, totalSupply, frontier, currentRound] = await Promise.all(['mintOpen', 'matchQueue', 'totalSupply', 'settledThroughRound', 'currentRound'].map(fn => read(nft, fn)));
console.log(JSON.stringify({ chainId: release.chainId, block: block.number.toString(), timestamp: block.timestamp.toString(), runtimes: 'both match compiled pinned source', mintOpen, matchQueue, totalSupply: totalSupply.toString(), frontier: frontier.toString(), currentRound: currentRound.toString() }, null, 2));
