import { useState, type ReactNode } from 'react';
import { formatEther } from 'viem';
import { useConnection } from 'wagmi';
import { Icon, type IconName } from './Art';
import { ACTIVITIES, BODY_CLASSES, bandRange, bodyClass, canFeed, canSettle, fedLabel, fmt } from './game';
import type { Game } from './data';
import type { Runtime } from './runtime';
import type { Action } from './transactions';

export type Ask = (action: Action) => void;
export function Meter({ label, icon, value, fill, accent = false, segments = 12, long = false }: { label: string; icon: IconName; value: ReactNode; fill: number; accent?: boolean; segments?: number; long?: boolean }) {
  return <div className={`meter-block${long ? ' full' : ''}`}><div className="meter-head"><span className="meter-label"><Icon name={icon} size={14} />{label}</span><span className="meter-value numeric">{value}</span></div>
    <div className="meter" aria-hidden="true">{Array.from({ length: segments }, (_, i) => <i key={i} className={i < Math.round(fill * segments) ? accent ? 'on accent' : 'on' : ''} />)}</div></div>;
}
export function Care({ runtime: r, game: g, tokenId, setTokenId, ask, ready, busy }: { runtime: Runtime; game: Game; tokenId?: bigint; setTokenId: (id: bigint) => void; ask: Ask; ready: boolean; busy: boolean }) {
  const { address } = useConnection();
  const [tier, setTier] = useState(1);
  const [lookup, setLookup] = useState('');
  const [lookupError, setLookupError] = useState('');
  const world = g.world.data;
  const pet = g.pet.data;
  const h = pet?.hamster;
  const owned = !!address && pet?.owner.toLowerCase() === address.toLowerCase();
  const canCare = ready && owned && !!pet && !g.pet.isError && !g.pet.isFetching;
  const mintAvailable = ready && world?.mintOpen && world.totalSupply < 9999n && g.wallet.data && !g.wallet.data.minted;
  const status = pet?.training;
  const range = pet ? bandRange(pet.band) : [0n, 499n];
  const staminaFill = h ? Number((h.stamina - range[0]) * 1000n / (range[1] - range[0] + 1n)) / 1000 : 0;
  const action = (label: string, fn: string, description: string, details?: [string, string][], value?: bigint, args?: readonly unknown[]) => ask({ label, contract: 'HamsterRunNFT', fn, args: args ?? [tokenId!], description, details, value });
  const mint = () => ask({ label: 'Mint hamster', contract: 'HamsterRunNFT', fn: 'mint', args: [], description: 'Mint one v3 hamster to this wallet. Your wallet can use its free mint once, even if you later transfer the hamster.', details: [['Mint price', 'Free'], ['Network', 'Sepolia testnet'], ['Network gas', 'Shown by your wallet']] });
  const mintLabel = busy ? 'Transaction pending' : !world ? 'Checking mint…' : !world.mintOpen ? 'Mint not open yet' : world.totalSupply >= 9999n ? 'All hamsters minted' : !address ? 'Mint a hamster' : g.wallet.data?.minted ? 'Free mint already used' : 'Mint a hamster';
  return <>
    <div className="intro"><div><h1>{h ? `Hello, hamster #${fmt(pet!.id)}` : 'Your pocket adventure'}</h1><p>{h ? 'A little care. A little certified wheel work.' : 'A free-to-mint hamster game on Sepolia.'}</p></div><span className="intro-side">Little paws, real wheel work.</span></div>
    {(address || tokenId !== undefined) && <div className="select-row">
      <label htmlFor="pet-select">My hamsters</label>
      <select id="pet-select" value={tokenId?.toString() ?? ''} onChange={e => e.target.value && setTokenId(BigInt(e.target.value))} disabled={!g.wallet.data?.ids.length}>
        {!g.wallet.data?.ids.length && <option value="">{g.wallet.isFetching ? 'Finding owned IDs…' : 'No owned hamsters'}</option>}
        {tokenId && !g.wallet.data?.ids.includes(tokenId) && <option value={tokenId.toString()}>Inspecting #{tokenId.toString()}</option>}
        {g.wallet.data?.ids.map(id => <option key={id.toString()} value={id.toString()}>Hamster #{fmt(id)}</option>)}
      </select>
      <button className="text-button" onClick={() => { void g.wallet.refetch(); void g.pet.refetch(); }} disabled={g.wallet.isFetching || busy}><Icon name="refresh" size={14} />Refresh IDs</button>
    </div>}
    {g.wallet.isError && <p className="inline-error" role="alert">Couldn’t finish the owned-ID scan. Retry Refresh IDs, or inspect a token by ID below.</p>}
    {g.pet.isError && <p className="inline-error" role="alert">Couldn’t read hamster #{tokenId?.toString()}. Check the ID and refresh. All pet actions are disabled.</p>}
    <div className="care-layout">
      <section aria-label="Hamster habitat and care HUD">
        <div className="lcd-frame">
          <div className="lcd-topline"><span className="pixel">Pocket habitat</span><span><span className="led" /> {h ? ACTIVITIES[h.activity] : 'Player one'}</span></div>
          <div className="lcd-inset">
            <img className="habitat" src="./habitat.svg" alt="A happy pixel hamster beside a little exercise wheel in a green meadow." width="640" height="320" />
            <div className="habitat-label"><span className="badge">{h ? `Hamster #${fmt(pet!.id)}` : 'A home for your hamster'}</span><span className="badge">{h ? pet?.hungry ? 'Hungry' : 'Fed & happy' : 'Illustration'}</span></div>
            <div className="habitat-hint"><Icon name={h ? pet?.hungry ? 'food' : 'heart' : 'pet'} size={16} /><span>{h ? pet?.hungry ? 'Time for a meal. Hunger locks training & queue entry.' : 'Keep that little belly full. Feed every 72 hours.' : address ? 'Mint your companion to bring this habitat to life.' : 'Connect a wallet to meet your little runner.'}</span></div>
          </div>
          <div className="meters">
            <Meter label="Stamina" icon="bolt" value={h ? fmt(h.stamina) : '–'} fill={staminaFill} long={!!h && h.stamina.toString().length > 16} />
            <Meter label="Body" icon="heart" value={h ? `${bodyClass(h.bodyScore)} · ${h.bodyScore}` : '–'} fill={h ? Number(h.bodyScore) / 100 : 0} />
            <Meter label="Fed timer" icon="food" value={h && world ? fedLabel(h.fedUntil, world.now) : '–'} fill={h && world ? Math.max(0, Math.min(1, Number(h.fedUntil - world.now) / 259200)) : 0} accent />
            <Meter label="Weekly races" icon="flag" value={pet ? `${pet.used} / 5 used` : '– / 5'} fill={pet ? Number(pet.used) / 5 : 0} segments={5} />
          </div>
          <div className="lcd-caption"><span>Stamina is uncapped{pet ? ` · band ${pet.band}` : ''}</span><span>{h ? `Weight: ${BODY_CLASSES[h.weight]}` : 'No hamster selected'}</span></div>
        </div>
        {h && <div className="helper">{h.fedUntil > 0n ? <>Fed until <time dateTime={new Date(Number(h.fedUntil) * 1000).toISOString()}>{new Date(Number(h.fedUntil) * 1000).toUTCString()}</time>.</> : 'This hamster has not been fed yet.'} Stamina meter shows progress within its current band.</div>}
        {h && !owned && <p className="helper">Inspecting another player’s hamster. Training settlement is permissionless; care actions require its owner.</p>}
        {h && <div className="collection-line"><span className="tiny muted">Collection supply: {world ? fmt(world.totalSupply) : 'Unknown'} / 9,999{g.wallet.data?.minted ? ' · Free mint used' : ''}</span>{g.wallet.data && !g.wallet.data.minted && <button className="button secondary small" disabled={!mintAvailable} onClick={mint}>Use free mint</button>}</div>}
        <details className="section-gap"><summary>Inspect a hamster by ID</summary><div className="detail-body">
          <form onSubmit={e => { e.preventDefault(); if (!/^[1-9]\d*$/.test(lookup) || BigInt(lookup) > 9999n) { setLookupError('Enter a hamster ID from 1 to 9999.'); return; } setLookupError(''); setTokenId(BigInt(lookup)); }}>
            <label className="field" htmlFor="lookup"><span>Hamster ID</span><input id="lookup" inputMode="numeric" name="tokenId" value={lookup} onChange={e => setLookup(e.target.value)} placeholder="For example, 1" aria-invalid={!!lookupError} aria-describedby={lookupError ? 'lookup-error' : undefined} /></label>
            <button className="button secondary small" type="submit">Load hamster</button>
            {lookupError && <p id="lookup-error" className="inline-error" role="alert">{lookupError}</p>}
          </form>
        </div></details>
      </section>
      <section className={h ? '' : 'onboard'} aria-label={h ? 'Care controls' : 'Get started'}>
        {!h ? <>
          <h2>A small start.<br />A big adventure.</h2>
          <div className={`step ${address ? 'done' : ''}`}><span className="step-number">{address ? <Icon name="check" size={16} /> : '1'}</span><div><h3>Connect your wallet</h3><p>{address ? 'Player connected. You’re ready to begin.' : 'Use Connect wallet above to join Sepolia.'}</p></div></div>
          <div className="step"><span className="step-number">2</span><div><h3>Meet your hamster</h3><p>One free mint per wallet. 10 stamina to start.</p></div></div>
          <div className="step"><span className="step-number">3</span><div><h3>Care, train, then race</h3><p>Feed your companion. Turn certified wheel work into stamina.</p></div></div>
          <div className="mint-box">
            <div className="mint-stats"><span>Hamsters minted</span><strong className="numeric">{world ? fmt(world.totalSupply) : '…'} <span className="muted">/ 9,999</span></strong></div>
            <div className="progress-track" aria-hidden="true"><i style={{ width: `${world ? Number(world.totalSupply) / 9999 * 100 : 0}%` }} /></div>
            <button className="button wide" disabled={!mintAvailable} onClick={mint}><span className="key" aria-hidden="true">B</span>{mintLabel}</button>
            <p className="mint-note">{!address ? 'Connect first to mint with network gas only.' : g.wallet.data?.minted ? 'Transferring a hamster does not reset your free mint.' : 'Free mint. Only Sepolia network gas applies.'}</p>
          </div>
        </> : <>
          <div className="panel"><div className="panel-header"><h2>Feed your hamster</h2><Icon name="food" /></div>
            <p>Each meal renews 72 hours. Choose food for your next training booking.</p>
            <div className="feed-tiers" role="group" aria-label="Food tier">
              {['Seeds', 'Trail mix', 'Power bowl'].map((name, i) => <button key={i} className="food-option" aria-pressed={tier === i} onClick={() => setTier(i)}>
                <Icon name="food" size={20 + i * 2} /><strong>{name}</strong><small>{world ? formatEther(world.prices[i]) : '…'} ETH</small><small>{world ? Number(world.bps[i]) / 10000 : '…'}× training</small>
              </button>)}
            </div>
            <button className="button wide" disabled={!canCare || !canFeed(h.activity) || !world} onClick={() => action('Feed hamster', 'feed', 'Feed now for 72 hours. Meals do not stack. During Training, this renews care and changes the next booking’s food; the active booking keeps its original multiplier.', [['Food', ['Seeds · tier 0', 'Trail mix · tier 1', 'Power bowl · tier 2'][tier]], ['Food price', `${formatEther(world!.prices[tier])} Sepolia ETH`], ['Next booking', `${world!.bps[tier]} bps`], ['Network gas', 'Additional, shown by your wallet']], world!.prices[tier], [tokenId!, tier])}><span className="key" aria-hidden="true">A</span>Feed hamster</button>
            {!canFeed(h.activity) && <p className="helper">Feeding is locked while {ACTIVITIES[h.activity].toLowerCase()}. Finish or leave the queue before feeding.</p>}
          </div>
          <div className="section-gap"><div className="panel-header"><h2>Wheel training</h2><Icon name="wheel" /></div>
            {h.activity === 1 ? <>
              <div className="training-data">
                <div className="data-row"><span>Booked rounds</span><strong className="numeric">{status?.trainStartRound ?? pet?.booking?.trainStartRound ?? 'Unknown'}–{status?.trainEndRound ?? pet?.booking?.trainEndRound ?? '?'}</strong></div>
                <div className="data-row"><span>Core frontier</span><strong className="numeric">{status ? fmt(status.frontier) : 'Unavailable'}</strong></div>
                <div className="data-row"><span>Captured food</span><strong>{pet?.booking ? `${Number(pet.booking.lastFeedBps) / 10000}× · tier ${pet.booking.tier}` : 'Unavailable'}</strong></div>
                <div className="data-row"><span>Certified work / gain</span><strong className="numeric">{status?.ready ? `${fmt(status.work)} / +${fmt(status.gain)}` : 'Not certified yet'}</strong></div>
              </div>
              {(status?.waitingForCertification || pet?.coreError) && <div className="lag-banner" role="status"><strong><Icon name="clock" size={16} />{pet.coreError ? 'Core status unavailable' : 'Waiting for Core certification'}</strong><p>{pet.coreError ? 'Couldn’t verify this window. Refresh before settling.' : 'Core can lag for days. This is normal. Keep feeding during the wait; Settle unlocks when your end round is certified.'}</p></div>}
              {status?.corePaused && <p className="helper">Core certifications are paused. Already-certified windows can still settle.</p>}
              <div className="training-actions"><button className="button" disabled={!ready || g.pet.isError || g.pet.isFetching || !canSettle(!!status?.active, !!status?.ready, !!pet?.coreError)} onClick={() => action('Settle training', 'settleTraining', 'Settle the booked window using certified Core work. Food expiry does not block settlement.', [['Certified work', status ? fmt(status.work) : 'Unknown'], ['Stamina gain', status ? `+${fmt(status.gain)}` : 'Unknown']])}><Icon name="check" size={16} />Settle training</button>
                <button className="button quiet small" disabled={!canCare} onClick={() => action('Cancel training', 'cancelTraining', 'Cancel this booking and unlock your hamster. You forfeit all work in this window and receive no stamina, body credit or gas refund. This cannot be undone.')}>Cancel training</button></div>
            </> : <>
              <p className="helper">Book 6 consecutive Core rounds. Settle after certification, which can take days. Food is captured when you book.</p>
              <button className="button secondary wide" disabled={!canCare || h.activity !== 0 || pet?.hungry || world?.currentRound === null} onClick={() => action('Start training', 'startTraining', 'Book six consecutive Core rounds [R, R+5] at the current round. Your hamster stays locked until certification or cancellation. Feeding stays available. Core can lag for days; there is no fixed completion time.', [['Food captured', `${Number(h.trainBps) / 10000}× · tier ${h.foodTier}`], ['Core frontier', world?.frontier === null ? 'Unavailable' : fmt(world?.frontier ?? 0n)], ['Stamina gain', 'Only known after certification']])}><Icon name="wheel" size={16} />Start training</button>
              {pet?.hungry && <p className="helper">Feed first. Hungry hamsters can’t book training.</p>}
              {h.activity > 1 && <p className="helper">Training is locked during a queue or match.</p>}
              {h.activity === 0 && world?.currentRound === null && <p className="helper">The Core clock is unavailable. New bookings are paused; feeding stays available.</p>}
            </>}
          </div>
        </>}
      </section>
    </div>
    <div className="subgrid">
      <div className="info-block"><div className="info-icon"><Icon name="food" /><h3>A well-fed little friend</h3></div><p>Feed every 72 hours. Hunger locks new training and queue entry. Your hamster is never burned.</p></div>
      <div className="info-block"><div className="info-icon"><Icon name="wheel" /><h3>Certified work, real stamina</h3></div><p>Physical wheel work → Core certification → stamina. Six booked rounds, with time for Core to catch up.</p></div>
      <div className="info-block"><div className="info-icon"><Icon name="flag" /><h3>A fairer starting line</h3></div><p>Stamina bands bring similar runners together. Five match attempts a week. No chosen opponents.</p></div>
    </div>
  </>;
}
