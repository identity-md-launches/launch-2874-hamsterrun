import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';

const root = new URL('../', import.meta.url);
const checking = process.argv.includes('--check');
const hashes = {};
const read = path => JSON.parse(readFileSync(new URL(path, root), 'utf8'));
for (const name of ['HamsterRunNFT', 'MatchQueue', 'ISqueekCore']) {
  const abi = read(`out/${name}.sol/${name}.json`).abi;
  const path = `abi/${name}.json`;
  const contents = JSON.stringify(abi, null, 2) + '\n';
  if (checking) {
    if (readFileSync(new URL(path, root), 'utf8') !== contents) throw new Error(`Stale ABI: ${path}`);
  } else {
    writeFileSync(new URL(path, root), contents);
  }
  hashes[path] = createHash('sha256').update(contents).digest('hex');
  console.log(`${name}: ${checking ? 'checked' : 'exported'} ${abi.length} entries`);
}

// Compare the exact parameter/return structure, independently of compiler-only internalType names.
const clean = value => Array.isArray(value) ? value.map(clean) : value && typeof value === 'object'
  ? Object.fromEntries(Object.entries(value).filter(([k]) => k !== 'internalType').map(([k, v]) => [k, clean(v)]))
  : value;
const published = read('abi/SqueekCore.upstream.json');
for (const entry of read('abi/ISqueekCore.json')) {
  const upstream = published.find(e => e.type === entry.type && e.name === entry.name);
  if (!isDeepStrictEqual(clean(entry), clean(upstream))) throw new Error(`Upstream ABI mismatch: ${entry.name}`);
}
hashes['abi/SqueekCore.upstream.json'] = createHash('sha256')
  .update(readFileSync(new URL('abi/SqueekCore.upstream.json', root))).digest('hex');
const contents = JSON.stringify(hashes, null, 2) + '\n';
if (checking) {
  if (readFileSync(new URL('abi/SHA256.json', root), 'utf8') !== contents) throw new Error('Stale ABI hashes');
} else {
  writeFileSync(new URL('abi/SHA256.json', root), contents);
}
console.log('Core read interface matches the pinned published v3 ABI.');
