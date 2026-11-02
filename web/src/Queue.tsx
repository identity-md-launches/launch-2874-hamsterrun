import { useEffect, useState } from 'react';
import { useConnection } from 'wagmi';
import { Icon } from './Art';
import { bandRange, fmt, fulfillState, shortAddress } from './game';
import { useQueue, type Game, type Round } from './data';
import type { Runtime } from './runtime';
import type { Ask } from './Care';

export function Queue({ runtime: r, game: g, ask, ready }: { runtime: Runtime; game: Game; ask: Ask; ready: boolean }) {
  const { address } = useConnection();
  const pet = g.pet.data;
  const world = g.world.data;
  const [band, setBand] = useState(pet?.band ?? 0n);
  const [archiveInput, setArchiveInput] = useState('');
  const [archived, setArchived] = useState<bigint>();
  const [archiveError, setArchiveError] = useState('');
  const q = useQueue(r, world, band, archived);
  useEffect(() => { if (pet) setBand(pet.band); }, [pet?.id]);
  const allowed = ready && !!world?.queueBound && !q.isError && !q.isFetching;
  const owner = !!address && pet?.owner.toLowerCase() === address.toLowerCase();
  const petHealthy = !!pet && !g.pet.isError && !g.pet.isFetching;
  const eligibleToJoin = allowed && petHealthy && owner && pet?.hamster.activity === 0 && !pet.hungry && pet.used < 5n && pet.activeToken === 0n && (band !== pet.band || (q.data?.entries.length ?? 32) < 32);
  const [low, high] = bandRange(band);
  const call = (label: string, fn: string, arg: bigint, description: string, details?: [string, string][]) => ask({ label, contract: 'MatchQueue', fn, args: [arg], description, details });
  function roundView(round: Round) {
    const state = world ? fulfillState(world.block, round.entropyBlock) : 'waiting';
    return <div className="round" key={round.id.toString()}>
      <div className="round-top"><h3>Round #{fmt(round.id)} <span className="muted">· band {fmt(round.band)}</span></h3><span className="badge">{round.status === 1 ? state === 'expired' ? 'Window expired' : 'Pending' : round.status === 2 ? 'Fulfilled' : 'Expired'}</span></div>
      <p>{round.count.toString()} runners · entropy block <span className="numeric">{fmt(round.entropyBlock)}</span></p>
      {round.racers.length > 0 && <p>Roster: {round.racers.map(x => `#${x.tokenId}`).join(', ')}</p>}
      {round.status === 1 && <>
        <p className="helper">{state === 'waiting' ? `Fulfill after block ${fmt(round.entropyBlock)}. Refresh when the next block arrives.` : state === 'expired' ? 'The blockhash deadline passed. Expire this round to unlock every runner; attempts stay spent.' : `Fulfillment is available through block ${fmt(round.entropyBlock + 256n)}. Anyone can help.`}</p>
        <div className="round-actions">{state === 'expired' ? <button className="button secondary small" disabled={!allowed} onClick={() => call('Expire round', 'expireRound', round.id, 'Unlock all runners in this pending round without rewards. Their match attempts remain spent.', [['Round', `#${round.id}`]])}>Expire round</button>
          : <button className="button secondary small" disabled={!allowed || state !== 'ready'} onClick={() => call('Fulfill round', 'fulfillRound', round.id, 'Use the committed future blockhash to shuffle this fixed roster and create matches. An odd runner gets a bye and an attempt refund.', [['Round', `#${round.id}`], ['Deadline block', fmt(round.entropyBlock + 256n)]])}>Fulfill round</button>}</div>
      </>}
      {round.status === 2 && <>
        {round.bye !== 0n && <p className="helper">Hamster #{round.bye.toString()} received a bye. Its attempt was refunded; no reward was earned.</p>}
        {round.races.map(race => <div className="row-state" key={race.id.toString()}>
          <div><h3>Match #{race.id.toString()} · #{race.a.tokenId.toString()} vs #{race.b.tokenId.toString()}</h3><p>Winner: #{race.winner.toString()} · score {fmt(race.scoreA)} / {fmt(race.scoreB)}</p></div>
          {race.settled ? <span className="badge"><Icon name="check" size={12} />Settled</span> : <button className="button secondary small" disabled={!allowed} onClick={() => call('Settle match', 'settleMatch', race.id, 'Apply this persisted match outcome. The winner gains 3 stamina and 10 points; the other runner gains 1 stamina and 2 points. Points have no promised redemption.', [['Match', `#${race.id}`], ['Winner', `Hamster #${race.winner}`]])}>Settle match</button>}
        </div>)}
      </>}
    </div>;
  }
  return <>
    <div className="intro"><div><h1>Little legs. Fair races.</h1><p>Find your stamina band. Let the queue choose the company.</p></div><span className="intro-side">Five attempts. One little champion.</span></div>
    <div className="page-grid">
      <section>
        <div className="select-row"><label htmlFor="band-select">Stamina band</label><select id="band-select" value={band.toString()} onChange={e => setBand(BigInt(e.target.value))}>{Array.from({ length: 249 }, (_, i) => <option key={i} value={i}>Band {i}{BigInt(i) === pet?.band ? ' · your hamster' : ''}</option>)}</select>{pet && band !== pet.band && <button className="text-button" onClick={() => setBand(pet.band)}>View my band</button>}</div>
        <p className="helper numeric">Band {band.toString()}: {fmt(low)}–{fmt(high)} stamina.</p>
        <div className="stats-row"><div className="stat"><span>In this band</span><strong>{q.data?.entries.length ?? '–'} / 32</strong></div><div className="stat"><span>Eligible to race</span><strong>{q.data ? fmt(q.data.eligible) : '–'}</strong></div><div className="stat"><span>Entry wait</span><strong>10 blocks</strong></div></div>
        <div className="panel-header"><h2>Starting line</h2><button className="text-button" onClick={() => { void g.world.refetch(); void q.refetch(); }} disabled={q.isFetching}><Icon name="refresh" size={14} />Refresh</button></div>
        {q.isError ? <div className="lag-banner" role="alert"><strong>Queue read unavailable</strong><p>Refresh live status to retry. No queue action is enabled until the current state is known.</p></div> : q.isPending ? <p className="helper" role="status">Reading the v3 queue…</p> : q.data.entries.length === 0 ? <div className="empty-state"><img src="./hamster.svg" alt="" width={80} height={70} /><h3>A quiet starting line</h3><p>No runners are waiting in this band. A round needs at least two fed hamsters, each past the ten-block wait.</p></div> : <div className="table-wrap"><table><caption className="sr-only">Hamsters waiting in stamina band {band.toString()}</caption><thead><tr><th>Hamster</th><th>Player</th><th>Wait</th></tr></thead><tbody>{q.data.entries.map(entry => <tr key={entry.tokenId.toString()}><td>#{entry.tokenId.toString()}{entry.player.toLowerCase() === address?.toLowerCase() ? ' · you' : ''}</td><td><a href={`${r.deployment.network.explorer}/address/${entry.player}`} target="_blank" rel="noreferrer" aria-label={`View player ${entry.player} on Etherscan`}>{shortAddress(entry.player)}</a></td><td>{world && world.now > entry.joinedAt + 86400n ? 'Expired' : world && world.block >= entry.joinedBlock + 10n ? 'Wait complete' : world ? `${entry.joinedBlock + 10n - world.block} blocks` : 'Unknown'}</td></tr>)}</tbody></table></div>}
        <div className="round-actions"><button className="button secondary" disabled={!allowed || (q.data?.eligible ?? 0n) < 2n} onClick={() => call('Request round', 'requestRound', band, 'Lock every eligible live runner in this band. Each spends one weekly attempt. You cannot choose opponents; the future blockhash shuffles the fixed roster.', [['Stamina band', band.toString()], ['Eligible runners', q.data?.eligible.toString() ?? 'Unknown']])}><Icon name="flag" size={16} />Request round</button></div>
        <p className="helper">Anyone can request a round once at least two runners qualify. No automatic keeper is promised.</p>
      </section>
      <aside>
        <div className="panel"><div className="panel-header"><h2>Your race pass</h2><Icon name="flag" /></div>
          {pet ? <>
            <div className="training-data"><div className="data-row"><span>Hamster</span><strong>#{pet.id.toString()}</strong></div><div className="data-row"><span>Stamina band</span><strong>{pet.band.toString()}</strong></div><div className="data-row"><span>Weekly attempts</span><strong>{pet.used.toString()} / 5 used</strong></div><div className="data-row"><span>Status</span><strong>{['Idle', 'Training', 'Queued', 'Matched'][pet.hamster.activity]}{pet.hungry ? ' · Hungry' : ''}</strong></div></div>
            <button className="button wide" disabled={!eligibleToJoin} onClick={() => call('Enqueue hamster', 'enqueue', pet.id, 'Join this hamster’s geometric stamina band. Feeding and transfers are locked while queued. You can leave before a round locks. Entry is eligible after ten blocks; a round requires at least two live runners.', [['Hamster', `#${pet.id}`], ['Band', pet.band.toString()], ['Stamina', fmt(pet.hamster.stamina)]])}><span className="key" aria-hidden="true">A</span>Enqueue hamster</button>
            {pet.hamster.activity === 2 && <button className="button secondary wide section-gap" disabled={!allowed || !owner || !petHealthy} onClick={() => call('Leave queue', 'leaveQueue', pet.id, 'Leave the waiting line and unlock care and transfers. No attempt is spent before a round locks.')}>Leave queue</button>}
            <p className="helper">{!owner ? 'Only this hamster’s owner can enqueue or leave.' : pet.hungry ? pet.hamster.activity === 2 ? 'Hungry in the queue? Leave first, then feed in My hamster.' : 'Feed your hamster in My hamster before joining.' : pet.hamster.activity === 1 ? 'Settle or cancel training before joining.' : pet.hamster.activity === 3 ? 'Find this hamster’s round below. Fulfill, then settle its match to unlock.' : pet.used >= 5n ? 'Your five weekly attempts are used. The quota resets on Thursday at 00:00 UTC.' : pet.activeToken !== 0n && pet.activeToken !== pet.id ? `Hamster #${pet.activeToken} is already active for this wallet.` : 'One active hamster per wallet. Attempts are spent when the round locks.'}</p>
          </> : <><p>Select an owned hamster in My hamster to see its band, quota and queue controls.</p><a className="button secondary wide" href="#care"><Icon name="pet" size={16} />Go to my hamster</a></>}
        </div>
        <div className="info-block section-gap"><div className="info-icon"><Icon name="clock" /><h3>No camping at the wheel</h3></div><p>Every entrant waits 10 blocks. Hungry pets and entries older than 24 hours may be evicted. Rounds lock all eligible runners, so nobody hand-picks an opponent.</p><a className="text-button" href="#guide">Read the race rules <Icon name="arrow" size={12} /></a></div>
      </aside>
    </div>
    <section className="section-gap"><div className="panel-header"><h2>Recent rounds</h2><span className="muted tiny">{q.data ? `${fmt(q.data.total)} total · latest 12` : 'Live v3 rounds'}</span></div>
      {q.data?.rounds.length ? q.data.rounds.map(roundView) : <p className="helper">{q.isPending ? 'Checking rounds…' : q.isError ? 'Rounds could not be read. Refresh to retry.' : 'No rounds have been requested yet. The first race starts with two eligible runners.'}</p>}
      <details><summary>Find an older round</summary><div className="detail-body"><form onSubmit={e => { e.preventDefault(); if (!/^[1-9]\d*$/.test(archiveInput) || BigInt(archiveInput) > (q.data?.total ?? 0n)) { setArchiveError('Enter an existing round ID.'); return; } setArchiveError(''); setArchived(BigInt(archiveInput)); }}><label className="field" htmlFor="round-id"><span>Round ID</span><input id="round-id" inputMode="numeric" value={archiveInput} onChange={e => setArchiveInput(e.target.value)} aria-invalid={!!archiveError} aria-describedby={archiveError ? 'round-error' : undefined} placeholder="For example, 1" /></label><button className="button secondary small" type="submit">Load round</button>{archiveError && <p className="inline-error" id="round-error" role="alert">{archiveError}</p>}</form></div></details>
    </section>
  </>;
}
