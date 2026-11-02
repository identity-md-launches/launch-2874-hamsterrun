import { readFile, writeFile, mkdir, copyFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { keccak256, toHex } from 'viem';

const root = new URL('../', import.meta.url);
const release = JSON.parse(await readFile(new URL('deployment.json', root), 'utf8'));
const canonical = v => Array.isArray(v) ? v.map(canonical) : v && typeof v === 'object'
  ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canonical(v[k])])) : v;
await mkdir(new URL('public/abi/', root), { recursive: true });
for (const c of release.contracts) {
  const source = new URL(`../abi/${c.name}.json`, root);
  const abi = JSON.parse(await readFile(source, 'utf8'));
  if (keccak256(toHex(JSON.stringify(canonical(abi)))) !== `0x${c.abiHash}`) throw Error(`Unpinned ABI: ${c.name}`);
  await copyFile(source, new URL(`public/${c.abi}`, root));
}
await writeFile(new URL('public/imd-deployment.json', root), await readFile(new URL('deployment.json', root)));
console.log('Prepared v3 runtime handoff and 2 hash-checked ABIs at', fileURLToPath(new URL('public/', root)));
