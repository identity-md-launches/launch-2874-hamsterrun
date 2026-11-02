import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bandForStamina, bandRange, bodyClass, canFeed, canSettle, cleanHandle, fulfillState, hungryAt, inviteLink, trainingGain } from '../src/game';

test('geometric bands at every contract boundary and uint256 maximum', () => {
  for (const [s, b] of [[0n, 0n], [10n, 0n], [499n, 0n], [500n, 1n], [999n, 1n], [1000n, 2n], [1999n, 2n], [2000n, 3n], [8000n, 5n], [(1n << 256n) - 1n, 248n]]) assert.equal(bandForStamina(s), b);
  for (let band = 0n; band <= 248n; band++) {
    const [low, high] = bandRange(band); assert.equal(bandForStamina(low), band);
    if (high < 1n << 256n) assert.equal(bandForStamina(high), band);
  }
});
test('certified work stays zero when zero, and floors non-default bps', () => {
  assert.equal(trainingGain(0n, 20000n), 0n);
  for (const [bps, gain] of [[10000n, 2024n], [15000n, 3036n], [20000n, 4048n]]) assert.equal(trainingGain(1012n, bps), gain);
  assert.equal(trainingGain(1n, 12500n), 2n);
});
test('hunger equality, body boundaries and Core lag gates', () => {
  assert.equal(hungryAt(0n, 0n), true); assert.equal(hungryAt(100n, 100n), false); assert.equal(hungryAt(100n, 101n), true);
  assert.deepEqual([0n, 34n, 35n, 69n, 70n, 100n].map(bodyClass), ['Obese', 'Obese', 'Normal', 'Normal', 'Fit', 'Fit']);
  assert.equal(canFeed(1), true); assert.equal(canFeed(2), false); assert.equal(canFeed(3), false);
  assert.equal(canSettle(true, false, false), false); assert.equal(canSettle(true, true, false), true); assert.equal(canSettle(true, true, true), false);
});
test('future-block fulfillment uses exact inclusive deadline', () => {
  assert.equal(fulfillState(102n, 102n), 'waiting'); assert.equal(fulfillState(103n, 102n), 'ready'); assert.equal(fulfillState(358n, 102n), 'ready'); assert.equal(fulfillState(359n, 102n), 'expired');
});
test('invite handles reject URL injection and keep static gateway subpaths', () => {
  assert.equal(cleanHandle(' @Little_Runner '), 'little_runner');
  for (const invalid of ['', 'longer_than_fifteen_characters', 'a/b', '<script>', 'foo?bar', 'hello world', 'https://x.com/ham']) assert.equal(cleanHandle(invalid), null);
  assert.equal(inviteLink('https://gateway.example/ipfs/hash/?old=yes#queue', '@little_runner'), 'https://gateway.example/ipfs/hash/?ref=little_runner');
});
