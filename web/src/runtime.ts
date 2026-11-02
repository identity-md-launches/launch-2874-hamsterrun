import { createPublicClient, defineChain, fallback, http, keccak256, toHex, type Abi, type Address, type Hex } from 'viem';
import { createConfig } from 'wagmi';
import { injected } from 'wagmi/connectors/injected';
import { coinbaseWallet } from 'wagmi/connectors/coinbaseWallet';
import { canonical } from './game';

export type ContractName = 'HamsterRunNFT' | 'MatchQueue';
export interface Contract {
  name: ContractName; address: Address; abi: string; abiHash: string; runtimeCodeHash: Hex; blockNumber: number;
}
export interface Deployment {
  version: number; siteVersion: string; chainId: number; sourceCommit: string; sourceUrl: string;
  contracts: Contract[];
  upstream: { name: string; address: Address };
  network: { chainId: number; name: string; testnet: boolean; rpcUrls: string[]; explorer: string; nativeCurrency: { name: string; symbol: string; decimals: number }; faucets: string[] };
  walletAddChain: { chainId: Hex; chainName: string; rpcUrls: string[]; nativeCurrency: { name: string; symbol: string; decimals: number }; blockExplorerUrls: string[] };
  inviteServiceUrl: string;
}
async function localJson(path: string) {
  const response = await fetch(new URL(path, document.baseURI), { cache: 'no-cache' });
  if (!response.ok) throw Error('A required v3 application file is unavailable. Reload to retry.');
  return response.json();
}
export async function loadRuntime() {
  const deployment = await localJson('./imd-deployment.json') as Deployment;
  if (deployment.version !== 1 || deployment.chainId !== 11155111 || deployment.network.chainId !== deployment.chainId
    || deployment.contracts.length !== 2 || deployment.contracts.some(c => !/^0x[\da-f]{40}$/i.test(c.address) || !/^0x[\da-f]{64}$/i.test(c.runtimeCodeHash))) {
    throw Error('The v3 deployment handoff is invalid. Transactions are unavailable.');
  }
  const contracts = {} as Record<ContractName, Contract & { abiData: Abi }>;
  for (const c of deployment.contracts) {
    if (!['HamsterRunNFT', 'MatchQueue'].includes(c.name) || !/^abi\/[A-Za-z]+\.json$/.test(c.abi)) throw Error('Invalid v3 contract handoff.');
    const abi = await localJson(c.abi) as Abi;
    if (keccak256(toHex(JSON.stringify(canonical(abi)))) !== `0x${c.abiHash}`) throw Error(`The ${c.name} ABI does not match the pinned v3 release.`);
    contracts[c.name] = { ...c, abiData: abi };
  }
  if (!contracts.HamsterRunNFT || !contracts.MatchQueue) throw Error('Missing v3 contracts.');
  const chain = defineChain({ id: deployment.chainId, name: deployment.network.name, testnet: deployment.network.testnet,
    nativeCurrency: deployment.network.nativeCurrency, rpcUrls: { default: { http: deployment.network.rpcUrls } },
    blockExplorers: { default: { name: 'Etherscan', url: deployment.network.explorer } } });
  const transport = () => fallback(deployment.network.rpcUrls.map(url => http(url, { timeout: 9000, retryCount: 1, batch: { wait: 20, batchSize: 50 } })), { rank: false });
  const client = createPublicClient({ chain, transport: transport() });
  const wagmi = createConfig({ chains: [chain], multiInjectedProviderDiscovery: true,
    connectors: [injected(), coinbaseWallet({ appName: 'HamsterRun', appLogoUrl: new URL('./favicon.svg', document.baseURI).href, preference: { options: 'all' } })],
    transports: { [chain.id]: transport() } });
  return { deployment, contracts, chain, client, wagmi };
}
export type Runtime = Awaited<ReturnType<typeof loadRuntime>>;
export async function read<T>(r: Runtime, name: ContractName, functionName: string, args: readonly unknown[] = [], blockNumber?: bigint): Promise<T> {
  const c = r.contracts[name];
  return await r.client.readContract({ address: c.address, abi: c.abiData, functionName, args, blockNumber }) as T;
}
export async function verifyContracts(r: Runtime) {
  if (await r.client.getChainId() !== r.chain.id) throw Error('The RPC returned another chain. Transactions are disabled.');
  const block = await r.client.getBlock();
  for (const c of Object.values(r.contracts)) {
    const code = await r.client.getBytecode({ address: c.address, blockNumber: block.number });
    if (!code || keccak256(code) !== c.runtimeCodeHash) throw Error(`${c.name} code does not match the pinned v3 source. Transactions are disabled.`);
  }
  const [nft, core, coreCode] = await Promise.all([
    read<Address>(r, 'MatchQueue', 'nft', [], block.number), read<Address>(r, 'HamsterRunNFT', 'core', [], block.number),
    r.client.getBytecode({ address: r.deployment.upstream.address, blockNumber: block.number }),
  ]);
  if (nft.toLowerCase() !== r.contracts.HamsterRunNFT.address.toLowerCase() || core.toLowerCase() !== r.deployment.upstream.address.toLowerCase() || !coreCode || coreCode === '0x') {
    throw Error('The v3 upstream bindings could not be verified. Transactions are disabled.');
  }
  return true;
}
