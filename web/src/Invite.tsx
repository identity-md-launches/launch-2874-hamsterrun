import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Icon } from './Art';
import { cleanHandle, fmt, inviteLink } from './game';
import { inviteLeaderboard, type Attribution } from './invites';
import type { Game } from './data';
import type { Runtime } from './runtime';

export function Invite({ runtime: r, game: g, attribution }: { runtime: Runtime; game: Game; attribution: Attribution | null }) {
  const [handle, setHandle] = useState(() => { try { return localStorage.getItem('hamsterrun:v3:handle') ?? ''; } catch { return ''; } });
  const [link, setLink] = useState('');
  const [error, setError] = useState('');
  const [copyStatus, setCopyStatus] = useState('');
  const service = r.deployment.inviteServiceUrl;
  const leaderboard = useQuery({ queryKey: ['invite-leaders', service], queryFn: () => inviteLeaderboard(service), enabled: !!service, retry: 1, staleTime: 30000 });
  async function copy() {
    try { await navigator.clipboard.writeText(link); setCopyStatus('Invite link copied.'); }
    catch { setCopyStatus('Copy is unavailable here. Select and copy the link above.'); }
  }
  return <>
    <div className="intro"><div><h1>Bring your little crew</h1><p>A shared adventure starts with a simple invite.</p></div><span className="intro-side">More paws at the starting line.</span></div>
    <div className="page-grid">
      <section><div className="invite-art" aria-hidden="true"><img src="./hamster.svg" alt="" width={96} height={84} /><Icon name="heart" size={32} /><img src="./hamster.svg" alt="" width={96} height={84} style={{ transform: 'scaleX(-1)' }} /></div>
        <h2>Make an invite</h2><p className="helper">Enter your X handle. No X login or signature is needed; handles are not verified.</p>
        <form onSubmit={e => { e.preventDefault(); const valid = cleanHandle(handle); if (!valid) { setError('Use 1–15 letters, numbers or underscores. A leading @ is okay.'); document.getElementById('x-handle')?.focus(); return; } setError(''); setLink(inviteLink(location.href, valid)); setCopyStatus(''); try { localStorage.setItem('hamsterrun:v3:handle', valid); } catch { /* optional */ } }}>
          <label className="field" htmlFor="x-handle"><span>Your X handle</span><input id="x-handle" name="handle" value={handle} onChange={e => setHandle(e.target.value)} placeholder="@little_runner" autoComplete="off" autoCapitalize="none" spellCheck={false} aria-invalid={!!error} aria-describedby={error ? 'handle-error' : 'handle-help'} /></label>
          <p className="helper" id="handle-help">1–15 letters, numbers or underscores.</p>{error && <p id="handle-error" className="inline-error" role="alert">{error}</p>}
          <button className="button" type="submit"><span className="key" aria-hidden="true">A</span>Create invite link</button>
        </form>
        {link && <div className="section-gap"><label htmlFor="invite-link">Your shareable invite</label><input id="invite-link" className="copy-field" style={{ width: '100%' }} value={link} readOnly onFocus={e => e.currentTarget.select()} /><div className="round-actions"><button className="button secondary small" onClick={() => void copy()}><Icon name="link" size={14} />Copy invite</button><a className="button quiet small" href={`https://twitter.com/intent/tweet?text=${encodeURIComponent('Meet your little runner in HamsterRun on Sepolia.')}&url=${encodeURIComponent(link)}`} target="_blank" rel="noreferrer">Share on X <Icon name="arrow" size={12} /></a></div><p className="helper" role="status">{copyStatus}</p></div>}
        <p className="helper">Invite attribution uses a first-visit record in your browser. Clear browser storage and that local record is lost. Invites carry no reward or airdrop promise.</p>
      </section>
      <section className="panel"><div className="panel-header"><h2>Invite leaderboard</h2><Icon name="gift" /></div>
        <div className="service-state"><span className={`led ${service && !leaderboard.isError ? '' : 'warning'}`} /><strong>{!service ? 'Invite service offline' : leaderboard.isError ? 'Service unavailable' : leaderboard.isPending ? 'Checking invite service…' : 'Shared invite counts'}</strong></div>
        {!service ? <><p>Shared invite tracking isn’t connected yet. You can still create and share a link. No global rankings or counts are being recorded.</p><div className="empty-state"><Icon name="flag" size={32} /><h3 className="section-gap">Room for your crew</h3><p>The leaderboard will appear when the invite service is available.</p></div></> : leaderboard.isError ? <><p>The service didn’t answer. Local attribution is kept for retry; no count is assumed.</p><button className="button secondary small" onClick={() => void leaderboard.refetch()}>Retry leaderboard</button></> : leaderboard.data?.length ? <table><caption className="sr-only">Unverified invite handles, ordered by recorded visits</caption><thead><tr><th>Rank</th><th>X handle</th><th>Invites</th></tr></thead><tbody>{leaderboard.data.map((row, i) => <tr key={row.handle}><td>{i + 1}</td><td>@{row.handle}</td><td>{fmt(row.invites)}</td></tr>)}</tbody></table> : !leaderboard.isPending ? <p>No invite visits have been recorded yet.</p> : null}
        <hr className="divider" /><div className="data-row"><span className="tiny">Your on-chain race points</span><strong className="numeric">{g.wallet.data ? fmt(g.wallet.data.points) : '–'}</strong></div><p>Race points come from v3 matches. They are separate from invite counts and have no promised redemption.</p>
        {attribution && <p>You arrived through <strong>@{attribution.handle}</strong>. {service ? 'The first attribution is saved locally and submitted when the service is reachable.' : 'This attribution is saved in this browser only.'}</p>}
      </section>
    </div>
  </>;
}
