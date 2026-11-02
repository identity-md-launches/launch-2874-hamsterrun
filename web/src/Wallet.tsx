import { useState } from 'react';
import { useConnection, useConnect, useConnectors, useDisconnect, type Connector } from 'wagmi';
import { getAddress } from 'viem';
import { Dialog } from './Dialog';
import { Icon } from './Art';
import { shortAddress } from './game';
import type { Runtime } from './runtime';

export const OPEN_IN = [
  { id: 'metamask', name: 'MetaMask', href: (url: string) => `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, '')}` },
  { id: 'coinbase', name: 'Coinbase Wallet', href: (url: string) => `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}` },
  { id: 'rabby', name: 'Rabby', href: (url: string) => `https://go.rabby.io/mobile/?dapp=${encodeURIComponent(url)}` },
  { id: 'phantom', name: 'Phantom', href: (url: string) => `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}` },
];
type Provider = { request: (args: { method: string; params?: unknown[] }) => Promise<unknown> };
export function Wallet({ runtime: r, busy }: { runtime: Runtime; busy: boolean }) {
  const account = useConnection();
  const connectors = useConnectors();
  const { mutateAsync: connect, isPending, variables, reset } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const [open, setOpen] = useState(false);
  const [note, setNote] = useState('');
  const [switching, setSwitching] = useState(false);
  const mobile = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) && !connectors.some(c => c.type === 'injected' && c.id !== 'injected') && !(window as unknown as { ethereum?: unknown }).ethereum;
  const named = connectors.some(c => c.type === 'injected' && c.id !== 'injected');
  const listed = [...connectors.filter(c => c.type === 'injected'), ...connectors.filter(c => c.type !== 'injected')]
    .filter(c => !(c.id === 'injected' && (named || mobile)));
  const wrongChain = account.isConnected && account.chainId !== r.chain.id;
  const close = () => { setOpen(false); setNote(''); reset(); };
  async function choose(c: Connector) {
    setNote('');
    try { await connect({ connector: c }); close(); }
    catch (error) {
      const code = (error as { code?: number }).code;
      setNote(code === 4001 || /reject|denied/i.test(String(error)) ? 'Connection declined. Choose a wallet to try again.' : c.id === 'injected' ? 'No browser wallet found. Install a wallet extension, or choose Coinbase Wallet.' : 'Could not connect. Open your wallet, then try again.');
    }
  }
  async function switchNetwork() {
    setNote(''); setSwitching(true);
    try {
      const provider = await account.connector?.getProvider() as Provider | undefined;
      if (!provider) throw Error('No wallet');
      try { await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: r.deployment.walletAddChain.chainId }] }); }
      catch (error) {
        if ((error as { code?: number }).code !== 4902) throw error;
        await provider.request({ method: 'wallet_addEthereumChain', params: [r.deployment.walletAddChain] });
        await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: r.deployment.walletAddChain.chainId }] });
      }
    } catch { setNote('Switch declined or unavailable. Select Sepolia in your wallet and try again.'); setOpen(true); }
    finally { setSwitching(false); }
  }
  const label = (c: Connector) => c.id === 'injected' ? 'Browser wallet' : c.id === 'coinbaseWalletSDK' || c.type === 'coinbaseWallet' ? mobile ? 'Coinbase Smart Wallet' : 'Coinbase Wallet' : c.name;
  return <>
    <button className="button connect-button" onClick={() => wrongChain ? void switchNetwork() : setOpen(true)} disabled={switching} aria-haspopup="dialog">
      <span className="key" aria-hidden="true">A</span>
      {switching ? 'Switching…' : wrongChain ? 'Switch to Sepolia' : account.address ? shortAddress(getAddress(account.address)) : 'Connect wallet'}
    </button>
    {open && <Dialog title={account.isConnected ? 'Player wallet' : 'Connect a wallet'} onClose={close}>
      {account.isConnected && account.address ? <>
        <p>Connected with {account.connector?.name}.</p><div className="copy-field numeric">{getAddress(account.address)}</div>
        <p>{wrongChain ? 'Switch to Sepolia to play.' : 'Sepolia testnet. Each game action is a wallet transaction.'}</p>
        {wrongChain && <button className="button wide" disabled={switching} onClick={() => void switchNetwork()}>Switch to Sepolia</button>}
        <button className="wallet-row" disabled={busy} onClick={() => { disconnect(); close(); }}><Icon name="wallet" />Disconnect wallet</button>
        {busy && <p>A transaction is pending. Wait for its result before disconnecting.</p>}
      </> : <>
        <p>Choose a wallet. You’ll play on Sepolia with test ETH.</p>
        {mobile && OPEN_IN.map(w => <a className="wallet-row" href={w.href(location.href)} key={w.id}><img src={`./wallets/${w.id}.svg`} alt="" width={28} height={28} /><span>Open in {w.name}</span></a>)}
        {listed.map(c => <button className="wallet-row" key={c.uid} disabled={isPending} onClick={() => void choose(c)}>
          {c.icon ? <img src={c.icon} alt="" width={28} height={28} /> : c.type === 'coinbaseWallet' || c.id === 'coinbaseWalletSDK' ? <img src="./wallets/coinbase.svg" alt="" width={28} height={28} /> : <Icon name="wallet" size={28} />}
          <span>{label(c)}{isPending && (variables?.connector as Connector | undefined)?.uid === c.uid ? ' · Opening…' : ''}</span>
        </button>)}
        {mobile && <p>Rabby link unavailable? Open Rabby’s browser and paste this page’s address.</p>}
        <p>No wallet prompt opens until you choose one.</p>
      </>}
      <div role="status" aria-live="polite">{note && <p className="inline-error">{note}</p>}</div>
    </Dialog>}
  </>;
}
