import { useEffect, useRef, useState } from 'react';
import { useConnection } from 'wagmi';
import { Dpad, Icon, type IconName } from './Art';
import { Wallet } from './Wallet';
import { Care } from './Care';
import { Queue } from './Queue';
import { Invite } from './Invite';
import { Guide } from './Guide';
import { Dialog } from './Dialog';
import { useGame } from './data';
import { fmt } from './game';
import { captureAttribution, sendAttribution } from './invites';
import { useTransactions, type Action } from './transactions';
import type { Runtime } from './runtime';

const tabs: { id: string; label: string; icon: IconName }[] = [{ id: 'care', label: 'My hamster', icon: 'pet' }, { id: 'queue', label: 'Match queue', icon: 'flag' }, { id: 'invite', label: 'Invite & ranks', icon: 'gift' }, { id: 'guide', label: 'How to play', icon: 'book' }];
const screenFromHash = () => tabs.some(t => `#${t.id}` === location.hash) ? location.hash.slice(1) : 'care';
export function App({ runtime: r }: { runtime: Runtime }) {
  const [screen, setScreen] = useState(screenFromHash);
  const [tokenId, setTokenId] = useState<bigint>();
  const [confirm, setConfirm] = useState<Action | null>(null);
  const [attribution] = useState(() => captureAttribution(location.href));
  const { address, isConnected, chainId } = useConnection();
  const game = useGame(r, tokenId);
  const tx = useTransactions(r);
  const main = useRef<HTMLElement>(null);
  const initialScreen = useRef(true);
  const world = game.world.data;
  useEffect(() => { const change = () => setScreen(screenFromHash()); addEventListener('hashchange', change); return () => removeEventListener('hashchange', change); }, []);
  useEffect(() => { if (initialScreen.current) { initialScreen.current = false; return; } main.current?.focus({ preventScroll: true }); window.scrollTo({ top: 0 }); }, [screen]);
  useEffect(() => { setTokenId(undefined); }, [address]);
  useEffect(() => { if (game.wallet.data?.ids.length && tokenId === undefined) setTokenId(game.wallet.data.ids[0]); }, [game.wallet.data, tokenId]);
  useEffect(() => { if (attribution && r.deployment.inviteServiceUrl) void sendAttribution(r.deployment.inviteServiceUrl, attribution).catch(() => { /* retries on next load; local attribution remains intact */ }); }, []);
  const dataHealthy = game.verification.data === true && !!world && !game.world.isError && Date.now() - world.checkedAt < 60000;
  const ready = dataHealthy && isConnected && chainId === r.chain.id && !tx.busy;
  const refresh = () => { if (game.verification.isError) void game.verification.refetch(); tx.refresh(); };
  const coreLag = world?.frontier !== null && world?.currentRound !== null && world?.frontier !== undefined && world.currentRound !== undefined && world.currentRound - world.frontier > 6n;
  const stateError = game.verification.isError || game.world.isError;
  const status = stateError ? 'Sepolia status unavailable. Actions paused.' : !world ? 'Checking live Sepolia status…' : `${world.mintOpen ? 'Mint open' : 'Mint not open yet'} · ${world.queueBound ? 'Queue bound' : world.matchQueue === '0x0000000000000000000000000000000000000000' ? 'Queue unbound' : 'Queue binding mismatch'}${coreLag ? ' · Core catching up' : world.frontier === null ? ' · Core status unavailable' : world.currentRound === null ? ' · Core clock unavailable' : ''}`;
  return <>
    <a href="#main-content" className="skip">Skip to content</a>
    <div className="site">
      <div className="handheld">
        <header className="header"><a className="brand" href="#care" aria-label="HamsterRun home"><img src="./favicon.svg" width={44} height={44} alt="" /><div><span className="brand-name">HamsterRun</span><small>A pocket-sized adventure · v3</small></div></a>
          <div className="header-controls"><span className="network"><span className="led" />Sepolia testnet</span><Wallet runtime={r} busy={tx.busy} /></div>
        </header>
        <nav className="nav" aria-label="Game navigation">{tabs.map((t, i) => <a key={t.id} href={`#${t.id}`} aria-current={screen === t.id ? 'page' : undefined}><Icon name={t.icon} /><span>{t.label}</span><span className="num" aria-hidden="true">0{i + 1}</span></a>)}</nav>
        <div className="status-strip"><Icon name={stateError ? 'refresh' : world?.mintOpen && world.queueBound ? 'check' : 'clock'} size={16} /><span className="status-copy" role="status">{status}</span>
          {stateError ? <button className="text-button" onClick={refresh}>Retry reads</button> : !world?.queueBound || !world.mintOpen ? <a href="#guide">Owner setup <Icon name="arrow" size={12} /></a> : <button className="text-button" onClick={refresh} disabled={game.world.isFetching}><Icon name="refresh" size={12} />{game.world.isFetching ? 'Checking…' : 'Refresh'}</button>}
        </div>
        {game.verification.isError && <p className="inline-error" role="alert">{game.verification.error.message.startsWith('The v3') || game.verification.error.message.includes('does not match') ? game.verification.error.message : 'Could not verify the v3 contract code and bindings. Retry reads before playing.'}</p>}
        {tx.notice && <div className={`notice ${tx.notice.kind === 'error' ? 'error' : ''}`} role={tx.notice.kind === 'error' ? 'alert' : 'status'}><div><p>{tx.notice.message}</p>{tx.notice.hash && <a href={`${r.deployment.network.explorer}/tx/${tx.notice.hash}`} target="_blank" rel="noreferrer">View transaction <Icon name="arrow" size={12} /></a>}</div>{tx.notice.kind !== 'pending' && <button className="icon-button" aria-label="Dismiss transaction notice" onClick={tx.dismiss}><Icon name="close" size={14} /></button>}</div>}
        {isConnected && chainId !== r.chain.id && <div className="lag-banner" role="status"><strong>Switch your wallet to Sepolia</strong><p>Use Switch to Sepolia above. The public data below is Sepolia; transactions stay disabled until your wallet is on the same chain.</p></div>}
        <main id="main-content" tabIndex={-1} ref={main}>
          {screen === 'care' ? <Care runtime={r} game={game} tokenId={tokenId} setTokenId={setTokenId} ask={setConfirm} ready={ready} busy={tx.busy} /> : screen === 'queue' ? <Queue runtime={r} game={game} ask={setConfirm} ready={ready} /> : screen === 'invite' ? <Invite runtime={r} game={game} attribution={attribution} /> : <Guide runtime={r} game={game} />}
        </main>
        <div className="shell-bottom" aria-hidden="true"><div className="shell-signature"><Dpad /><div className="shell-wordmark"><strong>HAM Pocket</strong><span>Good things come in little paws.</span></div></div><div className="speaker">{[0, 1, 2, 3, 4, 5].map(i => <span key={i} />)}</div></div>
      </div>
      <footer className="footer"><p>HamsterRun v3 · Sepolia · Just a little testnet adventure.</p><div className="footer-links"><a href="#guide">Game guide</a><a href={`${r.deployment.sourceUrl}/tree/${r.deployment.sourceCommit}`} target="_blank" rel="noreferrer">v3 source <Icon name="arrow" size={10} /></a><a href={`${r.deployment.network.explorer}/address/${r.contracts.HamsterRunNFT.address}`} target="_blank" rel="noreferrer">Contracts <Icon name="arrow" size={10} /></a></div></footer>
      {world && <p className="chain-stamp tiny muted">Read at block {fmt(world.block)} · Refreshes every 20 seconds while open.</p>}
    </div>
    {confirm && <Dialog title={confirm.label} onClose={() => setConfirm(null)}><p>{confirm.description}</p><div className="confirm-data">{(confirm.details ?? [['Network', 'Sepolia testnet'], ['Network gas', 'Shown by your wallet']]).map(([label, value]) => <div className="data-row" key={label}><span>{label}</span><strong className="numeric">{value}</strong></div>)}</div><p>No success is shown until a transaction receipt confirms it.</p><div className="confirm-actions"><button className="button secondary" onClick={() => setConfirm(null)}>Go back</button><button className="button" disabled={!ready} onClick={() => { const action = confirm; setConfirm(null); void tx.send(action); }}>{confirm.label}</button></div></Dialog>}
  </>;
}
