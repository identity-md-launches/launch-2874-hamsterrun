import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { address, word, words, rpcClient, finalizedBlock, CORE } from './rpc.mjs';

/** A one-shot, read-only smoke view; a lagged window is never displayed as earned zero work. */
export async function trainingStatus(rpc, nftInput, tokenId, methodIds) {
  const nft = address(nftInput);
  const { block, ref } = await finalizedBlock(rpc);
  const read = async (signature, args = '') => {
    const selector = methodIds[signature];
    if (!/^[\da-fA-F]{8}$/.test(selector)) throw new Error(`Missing selector: ${signature}`);
    return rpc('eth_call', [{ to: nft, data: `0x${selector}${args}` }, ref]);
  };
  if (words(await read('core()'), 1)[0] !== BigInt(CORE)) throw new Error('NFT does not use the requested Core');
  const s = words(await read('trainingStatus(uint256)', word(tokenId)), 9);
  const [active, start, end, frontier, ready, waiting, paused, work, gain] = s;
  if ([active, ready, waiting, paused].some(n => n !== 0n && n !== 1n)) throw new Error('Invalid status flags');
  if (active === 0n) return 'No booked training window.';
  const lines = [`Finalized block ${BigInt(block.number)}: Core frontier ${frontier}; booked rounds ${start}–${end} (inclusive).`];
  if (waiting === 1n) lines.push('WAITING FOR CORE CERTIFICATION — settle is unavailable. No gain is known yet.');
  else if (ready === 1n) lines.push(`Ready to settle: ${work} certified physical work; ${gain} stamina gain.`);
  else throw new Error('Inconsistent readiness flags');
  if (paused === 1n) lines.push('Core is paused. Already-certified windows remain settleable; owners may cancel pending training.');
  return lines.join('\n');
}

async function main() {
  const [url, nft, tokenId, ...extra] = process.argv.slice(2);
  if (!url || !nft || !tokenId || extra.length) throw new Error('Usage: node tools/training-status.mjs RPC_URL NFT_ADDRESS TOKEN_ID');
  const build = JSON.parse(readFileSync(new URL('../out/HamsterRunNFT.sol/HamsterRunNFT.json', import.meta.url), 'utf8'));
  console.log(await trainingStatus(rpcClient(url), nft, tokenId, build.methodIdentifiers));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(`CORE / RPC UNAVAILABLE: ${error.message}`); process.exitCode = 1; });
}
