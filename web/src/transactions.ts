import { useEffect, useRef, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useConnection, useWriteContract } from 'wagmi';
import { BaseError, ContractFunctionRevertedError, type Address, type Hex } from 'viem';
import { getConnection } from '@wagmi/core';
import { type Runtime, type ContractName } from './runtime';

export interface Action {
  label: string; contract: ContractName; fn: string; args: readonly unknown[]; value?: bigint;
  description: string; details?: [string, string][];
}
export interface Notice { kind: 'pending' | 'success' | 'error'; message: string; hash?: Hex }
const errors: Record<string, string> = {
  MintClosed: 'Minting is closed. Refresh live status and try when the owner opens minting.', AlreadyMinted: 'This wallet has already used its free mint.', SoldOut: 'All 9,999 hamsters have been minted.',
  Hungry: 'Your hamster is hungry. Feed it before starting training or joining the queue.', Locked: 'This action is unavailable in the current activity. Refresh the hamster status.',
  NotTokenOwner: 'This wallet no longer owns the selected hamster. Refresh your owned IDs.', IncorrectPayment: 'The food price changed. Refresh and review the new price before feeding.',
  CoreCertificationLag: 'Core has not certified this window yet. Keep feeding and check back later.', QueueNotConfigured: 'The owner has not bound the queue yet.',
  NotEnoughPlayers: 'This band needs at least two eligible hamsters, each waiting 10 blocks.', PlayerAlreadyActive: 'This wallet already has an active hamster in the queue or a match.',
  QueueFull: 'This band is full. Try again when a place opens.', WeeklyQuotaExceeded: 'This hamster has used its five attempts for the current week.',
  RandomnessNotReady: 'The entropy block has not passed. Wait for another block and refresh.', RandomnessExpired: 'This round’s blockhash window expired. Use Expire round to unlock the pets.',
  MatchAlreadySettled: 'This match was already settled. Refresh to see the result.', RoundNotPending: 'This round has already changed. Refresh the queue.',
  NoTraining: 'There is no active training booking. Refresh the hamster status.', WrongActivity: 'The hamster’s activity changed. Refresh before trying again.',
};
export function friendlyError(error: unknown) {
  if (error instanceof BaseError) {
    const reverted = error.walk(e => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError && reverted.data?.errorName) return errors[reverted.data.errorName] ?? `The contract refused this action (${reverted.data.errorName}). Refresh before trying again.`;
  }
  if (/reject|denied|4001/i.test(String(error))) return 'Transaction declined in your wallet. Nothing was confirmed.';
  if (/insufficient funds/i.test(String(error))) return 'Not enough Sepolia ETH for this action and gas. Add test ETH from a faucet.';
  if (/chain|network/i.test(String(error)) && /mismatch|different|wrong/i.test(String(error))) return 'Switch your wallet to Sepolia, then try again.';
  return 'The action could not be confirmed. Refresh live status before retrying; if a hash is shown, check it on the explorer first.';
}
export function useTransactions(r: Runtime) {
  const { address } = useConnection();
  const { mutateAsync: write } = useWriteContract();
  const cache = useQueryClient();
  const [notice, setNotice] = useState<Notice | null>(null);
  const [busy, setBusy] = useState(false);
  const lock = useRef(false);
  const pendingKey = (a: Address) => `hamsterrun:v3:pending:${r.chain.id}:${r.contracts.HamsterRunNFT.address}:${a.toLowerCase()}`;
  const refresh = () => { void cache.invalidateQueries({ queryKey: ['world'] }); void cache.invalidateQueries({ queryKey: ['wallet'] }); void cache.invalidateQueries({ queryKey: ['pet'] }); void cache.invalidateQueries({ queryKey: ['queue'] }); };
  async function wait(hash: Hex, a: Address, label: string) {
    setNotice({ kind: 'pending', message: `${label} submitted. Waiting for confirmation…`, hash });
    try {
      const receipt = await r.client.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 120000 });
      try { localStorage.removeItem(pendingKey(a)); } catch { /* storage is optional */ }
      setNotice({ kind: receipt.status === 'success' ? 'success' : 'error', message: receipt.status === 'success' ? `${label} confirmed on Sepolia.` : `${label} reverted. No game change was confirmed.`, hash });
      refresh();
    } catch {
      setNotice({ kind: 'error', message: 'Confirmation is taking longer than expected. Check the transaction on the explorer before sending again.', hash });
    } finally { lock.current = false; setBusy(false); }
  }
  useEffect(() => {
    if (!address || lock.current) return;
    try {
      const raw = localStorage.getItem(pendingKey(address));
      if (!raw) return;
      const saved = JSON.parse(raw) as { hash: Hex; label: string };
      if (!/^0x[\da-fA-F]{64}$/.test(saved.hash)) return;
      lock.current = true; setBusy(true); void wait(saved.hash, address, saved.label || 'Transaction');
    } catch { /* a blocked or invalid local store never enables a write */ }
  }, [address]);
  async function send(action: Action) {
    if (lock.current) return;
    const account = getConnection(r.wagmi);
    if (!account.isConnected || !account.address || account.chainId !== r.chain.id) { setNotice({ kind: 'error', message: 'Connect your wallet and switch to Sepolia before playing.' }); return; }
    lock.current = true; setBusy(true);
    setNotice({ kind: 'pending', message: `Checking ${action.label.toLowerCase()}…` });
    let hash: Hex | undefined;
    try {
      const c = r.contracts[action.contract];
      await r.client.simulateContract({ address: c.address, abi: c.abiData, functionName: action.fn, args: action.args, account: account.address, value: action.value });
      const latest = getConnection(r.wagmi);
      if (latest.address !== account.address || latest.chainId !== r.chain.id) throw Error('Wallet chain mismatch');
      setNotice({ kind: 'pending', message: `Confirm ${action.label.toLowerCase()} in your wallet.` });
      hash = await write({ address: c.address, abi: c.abiData, functionName: action.fn, args: action.args, value: action.value, chainId: r.chain.id });
      try { localStorage.setItem(pendingKey(account.address), JSON.stringify({ hash, label: action.label })); } catch { /* optional */ }
      await wait(hash, account.address, action.label);
    } catch (error) {
      setNotice({ kind: 'error', message: friendlyError(error), hash });
      lock.current = false; setBusy(false); refresh();
    }
  }
  return { send, busy, notice, dismiss: () => setNotice(null), refresh };
}
