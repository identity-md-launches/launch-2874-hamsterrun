import { useQuery } from '@tanstack/react-query';
import { parseAbiItem, type Address } from 'viem';
import { useConnection } from 'wagmi';
import { read, verifyContracts, type Runtime } from './runtime';
import type { Activity } from './game';

export interface Hamster { stamina: bigint; fedUntil: bigint; trainBps: bigint; bodyScore: bigint; weight: 0 | 1 | 2; activity: Activity; foodTier: number }
export interface Training { active: boolean; trainStartRound: bigint; trainEndRound: bigint; frontier: bigint; ready: boolean; waitingForCertification: boolean; corePaused: boolean; work: bigint; gain: bigint }
export interface Booking { trainStartRound: bigint; trainEndRound: bigint; lastFeedBps: bigint; tier: number }
export interface Entry { tokenId: bigint; player: Address; joinedAt: bigint; joinedBlock: bigint }
export interface Snapshot { tokenId: bigint; player: Address; stamina: bigint; weight: number }
export interface Race { roundId: bigint; a: Snapshot; b: Snapshot; scoreA: bigint; scoreB: bigint; winner: bigint; settled: boolean }
export interface Round { id: bigint; band: bigint; entropyBlock: bigint; week: bigint; status: number; count: bigint; racers: Snapshot[]; races: (Race & { id: bigint })[]; bye: bigint }
export async function readWorld(r: Runtime) {
  const block = await r.client.getBlock();
  const at = <T,>(name: string, args: readonly unknown[] = []) => read<T>(r, 'HamsterRunNFT', name, args, block.number);
  const [mintOpen, matchQueue, totalSupply, owner, ...food] = await Promise.all([
    at<boolean>('mintOpen'), at<Address>('matchQueue'), at<bigint>('totalSupply'), at<Address>('owner'),
    ...[0n, 1n, 2n].map(i => at<bigint>('foodPrices', [i])), ...[0n, 1n, 2n].map(i => at<bigint>('foodTrainBps', [i])),
  ]);
  const core = await Promise.allSettled([at<bigint>('settledThroughRound'), at<bigint>('currentRound')]);
  return { mintOpen: mintOpen as boolean, matchQueue: matchQueue as Address, totalSupply: totalSupply as bigint, owner: owner as Address,
    prices: food.slice(0, 3) as bigint[], bps: food.slice(3) as bigint[], block: block.number, now: block.timestamp,
    frontier: core[0].status === 'fulfilled' ? core[0].value : null,
    currentRound: core[1].status === 'fulfilled' ? core[1].value : null,
    queueBound: (matchQueue as Address).toLowerCase() === r.contracts.MatchQueue.address.toLowerCase(), checkedAt: Date.now() };
}
export type World = Awaited<ReturnType<typeof readWorld>>;
const transfer = parseAbiItem('event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)');

/** Scan only incoming transfers, then confirm current ownership. No indexer or v1/v2 data. */
export async function ownedIds(r: Runtime, address: Address, signal?: AbortSignal) {
  const block = await r.client.getBlockNumber();
  const balance = await read<bigint>(r, 'HamsterRunNFT', 'balanceOf', [address], block);
  if (balance === 0n) return [] as bigint[];
  const start = BigInt(r.contracts.HamsterRunNFT.blockNumber);
  const seen = new Set<bigint>();
  const owned = new Set<bigint>();
  let to = block;
  for (let page = 0; to >= start && page < 200; page++) {
    signal?.throwIfAborted();
    const from = to - start < 9999n ? start : to - 9999n;
    const logs = await r.client.getLogs({ address: r.contracts.HamsterRunNFT.address, event: transfer, args: { to: address }, fromBlock: from, toBlock: to });
    const candidates = [...new Set(logs.map(log => log.args.tokenId).filter((id): id is bigint => id !== undefined && !seen.has(id)))];
    for (let i = 0; i < candidates.length; i += 30) {
      signal?.throwIfAborted();
      await Promise.all(candidates.slice(i, i + 30).map(async id => {
        seen.add(id);
        if ((await read<Address>(r, 'HamsterRunNFT', 'ownerOf', [id], block)).toLowerCase() === address.toLowerCase()) owned.add(id);
      }));
    }
    if (BigInt(owned.size) === balance) return [...owned].sort((a, b) => a < b ? -1 : 1);
    if (from === start) break;
    to = from - 1n;
  }
  throw Error('The transfer scan could not confirm all owned IDs. Load a hamster by ID below.');
}
export function useGame(r: Runtime, tokenId: bigint | undefined) {
  const { address } = useConnection();
  const verification = useQuery({ queryKey: ['verification'], queryFn: () => verifyContracts(r), staleTime: Infinity, retry: 1 });
  const world = useQuery({ queryKey: ['world'], queryFn: () => readWorld(r), enabled: verification.data === true, refetchInterval: 20000, staleTime: 10000, retry: 1 });
  const wallet = useQuery({ queryKey: ['wallet', address], enabled: !!address && !!world.data,
    queryFn: async ({ signal }) => {
      const [ids, minted, points] = await Promise.all([
        ownedIds(r, address!, signal), read<boolean>(r, 'HamsterRunNFT', 'freeMinted', [address!]), read<bigint>(r, 'MatchQueue', 'points', [address!]),
      ]); return { ids, minted, points };
    }, refetchInterval: 30000, staleTime: 10000, retry: 1 });
  const pet = useQuery({ queryKey: ['pet', address, tokenId?.toString(), world.data?.block.toString()], enabled: tokenId !== undefined && verification.data === true,
    queryFn: async () => {
      const at = <T,>(name: string, args: readonly unknown[] = [tokenId]) => read<T>(r, 'HamsterRunNFT', name, args, world.data?.block);
      const [hamster, hungry, used, band, owner, activeToken] = await Promise.all([
        at<Hamster>('hamster'), at<boolean>('isHungry'), at<bigint>('matchesThisWeek'), read<bigint>(r, 'MatchQueue', 'bandOf', [tokenId], world.data?.block),
        at<Address>('ownerOf'), address ? read<bigint>(r, 'MatchQueue', 'activeToken', [address], world.data?.block) : Promise.resolve(0n),
      ]);
      const status = await Promise.allSettled([at<Training>('trainingStatus'), at<[bigint, bigint, bigint, number]>('training')]);
      const training = status[0].status === 'fulfilled' ? status[0].value : null;
      const t = status[1].status === 'fulfilled' ? status[1].value : null;
      const booking = t ? { trainStartRound: t[0], trainEndRound: t[1], lastFeedBps: t[2], tier: t[3] } : null;
      return { id: tokenId!, hamster, hungry, used, band, owner, activeToken, training, booking, coreError: status[0].status === 'rejected' };
    }, staleTime: 10000, retry: 1 });
  return { verification, world, wallet, pet };
}
export type Game = ReturnType<typeof useGame>;
export async function readRound(r: Runtime, id: bigint, block: bigint): Promise<Round> {
  const [info, racers, matchIds, bye] = await Promise.all([
    read<[bigint, bigint, bigint, number, string, bigint]>(r, 'MatchQueue', 'roundInfo', [id], block),
    read<Snapshot[]>(r, 'MatchQueue', 'roundRacers', [id], block), read<bigint[]>(r, 'MatchQueue', 'roundMatchIds', [id], block), read<bigint>(r, 'MatchQueue', 'roundBye', [id], block),
  ]);
  const races = await Promise.all(matchIds.map(async id => ({ ...await read<Race>(r, 'MatchQueue', 'matchInfo', [id], block), id })));
  return { id, band: info[0], entropyBlock: info[1], week: info[2], status: info[3], count: info[5], racers, races, bye };
}
export function useQueue(r: Runtime, world: World | undefined, band: bigint, archived?: bigint) {
  return useQuery({ queryKey: ['queue', band.toString(), world?.block.toString(), archived?.toString()], enabled: !!world,
    queryFn: async () => {
      const block = world!.block;
      const [entries, eligible, total] = await Promise.all([
        read<Entry[]>(r, 'MatchQueue', 'queueEntries', [band], block), read<bigint>(r, 'MatchQueue', 'eligibleCount', [band], block), read<bigint>(r, 'MatchQueue', 'roundCount', [], block),
      ]);
      const ids = Array.from({ length: Number(total < 12n ? total : 12n) }, (_, i) => total - BigInt(i));
      if (archived && !ids.includes(archived)) ids.unshift(archived);
      const rounds = await Promise.all(ids.map(id => readRound(r, id, block)));
      return { entries, eligible, rounds, total };
    }, staleTime: 10000, retry: 1 });
}
