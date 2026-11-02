/** Read-only JSON-RPC utilities. No keys, environment access, polling, signing, or dependencies. */
export const CHAIN_ID = 11155111;
export const OWNER = '0x6c14430adacc99e27f6180bc5a74d6768616bf4a';
export const CORE = '0x74665daeca35a2303e767e76a2ff1fb6f93e119f';

export function address(value) {
  if (typeof value !== 'string' || !/^0x[\da-fA-F]{40}$/.test(value) || BigInt(value) === 0n) {
    throw new Error('A nonzero 20-byte address is required');
  }
  return value.toLowerCase();
}

export function word(value) {
  const n = BigInt(value);
  if (n < 0n || n >= 1n << 256n) throw new Error('Value is outside uint256');
  return n.toString(16).padStart(64, '0');
}

export function words(data, expected) {
  if (typeof data !== 'string' || !/^0x(?:[\da-fA-F]{64})*$/.test(data)) {
    throw new Error('Malformed ABI response');
  }
  const result = (data.slice(2).match(/.{64}/g) ?? []).map(n => BigInt(`0x${n}`));
  if (expected !== undefined && result.length !== expected) throw new Error('Unexpected ABI response length');
  return result;
}

export function rpcClient(url) {
  if (!/^https?:\/\//.test(url)) throw new Error('An HTTP(S) Sepolia RPC URL is required');
  const allowed = new Set(['eth_chainId', 'eth_getBlockByNumber', 'eth_getCode', 'eth_call']);
  return async (method, params) => {
    if (!allowed.has(method)) throw new Error('Only read-only RPC methods are permitted');
    try {
      const response = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(20_000),
      });
      if (!response.ok) throw new Error('transport');
      const data = await response.json();
      if (data.error || data.result === undefined) throw new Error('rpc');
      return data.result;
    } catch {
      // Never echo an RPC URL: operators may supply a private provider URL.
      throw new Error(`RPC failed during ${method}; no address record was written`);
    }
  };
}

export async function finalizedBlock(rpc) {
  if (BigInt(await rpc('eth_chainId', [])) !== BigInt(CHAIN_ID)) throw new Error('RPC is not Sepolia');
  const block = await rpc('eth_getBlockByNumber', ['finalized', false]);
  if (!block || !/^0x[\da-fA-F]{64}$/.test(block.hash)) throw new Error('No finalized block available');
  return { block, ref: { blockHash: block.hash, requireCanonical: true } };
}
