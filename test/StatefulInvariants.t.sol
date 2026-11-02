// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { MockSqueekCore } from "./helpers/MockSqueekCore.sol";
import { ISqueekCore } from "../src/interfaces/ISqueekCore.sol";
import { Test } from "forge-std/Test.sol";
import { GameTest } from "./helpers/GameTest.sol";
import { ForceSend } from "./helpers/Probes.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, GameMath, WeightClass } from "../src/GameMath.sol";

/// @notice Drives the whole game with several wallets, wallets holding several pets, transfers, config
///         changes, forced ETH and hostile callers. Every entry takes the same two seeds so a seeded walk
///         can call it too. An action that should work is called plainly, so with fail_on_revert a
///         surprise revert fails the campaign. An action that should fail is sent low-level and asserted.
contract WorldHandler is Test {
    HamsterRunNFT public immutable nft;
    MatchQueue public immutable queue;
    address public immutable gameOwner;
    address public immutable stranger;
    address[10] public actors;

    // ETH ledger
    uint256 public paid;
    uint256 public forced;
    uint256 public withdrawn;

    // Game ledger
    uint256 public ghostMinted;
    uint256 public ghostFreeMints;
    uint256 public ghostSettled;
    uint256 public ghostTrainingGain;
    mapping(uint256 => uint256) public ghostStamina;
    mapping(uint256 => uint256) public ghostFedUntil;
    mapping(uint256 => bool) public ghostInOpenRace;
    mapping(address => uint256) public ghostPoints;
    mapping(uint256 => mapping(uint256 => uint256)) public ghostWeeklyLocks;
    mapping(uint256 => uint8) public ghostRoundStatus;
    mapping(uint256 => bytes32) public ghostRaceHash;
    mapping(uint256 => bool) public ghostRaceSettled;

    uint256[] public bands;
    mapping(uint256 => bool) private _bandSeen;

    /// @notice Times each outcome was really reached, so a test can prove the walk is not vacuous.
    mapping(string => uint256) public hits;

    constructor(HamsterRunNFT nft_, MatchQueue queue_, address owner_) {
        nft = nft_;
        queue = queue_;
        gameOwner = owner_;
        stranger = makeAddr("world stranger");
        vm.deal(stranger, 1000 ether);
        for (uint256 i; i < 10; ++i) {
            actors[i] = makeAddr(string.concat("world actor", vm.toString(i)));
            vm.deal(actors[i], 1000 ether);
        }
        _seenBand(0);
    }

    /// @dev Six wallets free mint and two of them also hold an owner-minted second pet.
    function bootstrap() external {
        for (uint256 i; i < 6; ++i) {
            _freeMint(actors[i]);
        }
        _ownerMint(actors[0]);
        _ownerMint(actors[1]);
        for (uint256 id = 1; id <= ghostMinted; ++id) {
            _feedPet(id, id % 3 == 0 ? 2 : 1);
        }
    }

    // ------------------------------------------------------------------ minting

    function mintNew(uint256 actorSeed, uint256) external {
        address wallet = actors[actorSeed % 10];
        if (nft.freeMinted(wallet)) {
            _mustRevert(wallet, address(nft), 0, abi.encodeCall(nft.mint, ()), "second free mint");
            hits["mintRefused"]++;
            return;
        }
        _freeMint(wallet);
        hits["mintOk"]++;
    }

    function _freeMint(address wallet) private {
        vm.prank(wallet);
        uint256 id = nft.mint();
        _newPet(id, wallet);
        ++ghostFreeMints;
    }

    function _ownerMint(address wallet) private {
        vm.prank(gameOwner);
        uint256 id = nft.ownerMint(wallet);
        _newPet(id, wallet);
    }

    function _newPet(uint256 id, address wallet) private {
        ++ghostMinted;
        assertEq(id, ghostMinted, "ids are sequential");
        assertEq(nft.ownerOf(id), wallet);
        ghostStamina[id] = 10;
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        assertEq(ham.stamina, 10);
        assertEq(ham.bodyScore, 50);
        assertEq(uint256(ham.activity), uint256(Activity.Idle));
    }

    // ------------------------------------------------------------------ feeding

    function feed(uint256 petSeed, uint256 tierSeed) external {
        uint256 id = _pet(petSeed);
        uint8 tier = uint8(tierSeed % 3);
        if (nft.hamster(id).activity != Activity.Idle) {
            uint256 price = nft.foodPrices(tier);
            _mustRevert(
                nft.ownerOf(id), address(nft), price, abi.encodeCall(nft.feed, (id, tier)), "locked feed"
            );
            hits["feedLocked"]++;
            return;
        }
        _feedPet(id, tier);
        hits["feedOk"]++;
    }

    function _feedPet(uint256 id, uint8 tier) private {
        uint256 price = nft.foodPrices(tier);
        uint256 expectedBps = nft.foodTrainBps(tier);
        uint256 before = nft.hamster(id).bodyScore;
        uint256 expiry = _now() + 72 hours;
        address petOwner = nft.ownerOf(id);
        vm.prank(petOwner);
        nft.feed{ value: price }(id, tier);
        paid += price;
        ghostFedUntil[id] = expiry;
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        assertEq(ham.fedUntil, expiry);
        assertEq(ham.trainBps, expectedBps);
        assertEq(ham.foodTier, tier);
        uint256 expectedBody = tier == 0
            ? (before < 4 ? 0 : before - 4)
            : (before + (tier == 1 ? 6 : 12) > 100 ? 100 : before + (tier == 1 ? 6 : 12));
        assertEq(ham.bodyScore, expectedBody, "feed body delta");
    }

    function feedBadly(uint256 petSeed, uint256 mode) external {
        uint256 id = _pet(petSeed);
        uint8 tier = uint8(mode % 3);
        uint256 price = nft.foodPrices(tier);
        address petOwner = nft.ownerOf(id);
        bytes memory before = abi.encode(nft.hamster(id));
        uint256 balanceBefore = address(nft).balance;
        _mustRevert(petOwner, address(nft), price - 1, abi.encodeCall(nft.feed, (id, tier)), "underpaid");
        _mustRevert(petOwner, address(nft), price + 1, abi.encodeCall(nft.feed, (id, tier)), "overpaid");
        _mustRevert(
            petOwner, address(nft), price, abi.encodeCall(nft.feed, (id, uint8(3 + mode % 200))), "tier"
        );
        _mustRevert(stranger, address(nft), price, abi.encodeCall(nft.feed, (id, tier)), "stranger feed");
        assertEq(abi.encode(nft.hamster(id)), before, "a failed feed changes nothing");
        assertEq(address(nft).balance, balanceBefore);
        hits["feedRefused"]++;
    }

    // ------------------------------------------------------------------ training

    function startTraining(uint256 petSeed, uint256) external {
        uint256 id = _pet(petSeed);
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        address petOwner = nft.ownerOf(id);
        bool allowed = ham.activity == Activity.Idle && !nft.isHungry(id);
        bytes memory call_ = abi.encodeCall(nft.startTraining, (id));
        _mustRevert(stranger, address(nft), 0, call_, "stranger training");
        if (!allowed) {
            _mustRevert(petOwner, address(nft), 0, call_, "training gate");
            hits["trainRefused"]++;
            return;
        }
        vm.prank(petOwner);
        nft.startTraining(id);
        (uint64 start, uint64 end, uint256 bps, uint8 tier) = nft.training(id);
        assertEq(start, (_now() - nft.core().configuration().genesisTimestamp) / 600 + 1);
        assertEq(end, start + 5);
        assertEq(bps, ham.trainBps);
        assertEq(tier, ham.foodTier);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Training));
        hits["trainOk"]++;
    }

    function settleTraining(uint256 petSeed, uint256 callerSeed) external {
        uint256 id = _petInActivity(petSeed, Activity.Training);
        (uint64 start, uint64 end, uint256 bps, uint8 tier) = nft.training(id);
        bool ready =
            nft.hamster(id).activity == Activity.Training && nft.core().state().settledThroughRound >= end;
        address caller = _anyone(callerSeed);
        if (!ready) {
            _mustRevert(caller, address(nft), 0, abi.encodeCall(nft.settleTraining, (id)), "not ready");
            hits["settleTrainingRefused"]++;
            return;
        }
        ISqueekCore.RoundPage memory page = nft.core().roundPage(start - 1, end, 6);
        uint256 gain = uint256(page.end.cumulativeWork - page.start.cumulativeWork) * 2 * bps / 10_000;
        _settleTraining(id, gain, tier, caller);
        hits["settleTrainingOk"]++;
    }

    function _settleTraining(uint256 id, uint256 gain, uint8 tier, address caller) private {
        uint256 body = nft.hamster(id).bodyScore;
        vm.prank(caller);
        nft.settleTraining(id);
        ghostStamina[id] += gain;
        ghostTrainingGain += gain;
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        assertEq(ham.stamina, ghostStamina[id]);
        assertEq(uint256(ham.activity), uint256(Activity.Idle));
        assertEq(ham.bodyScore, _trainedBody(body, gain, tier), "training body credit");
        (uint64 start, uint64 end, uint256 bps,) = nft.training(id);
        assertEq(start, 0);
        assertEq(end, 0);
        assertEq(bps, 0);
        _mustRevert(caller, address(nft), 0, abi.encodeCall(nft.settleTraining, (id)), "settled twice");
    }

    /// @dev DESIGN: cap = 60 on low food, else 100; a score already at or above the cap is left alone.
    function _trainedBody(uint256 body, uint256 gain, uint8 tier) private pure returns (uint256) {
        if (gain == 0) return body;
        uint256 credit = 2 + 2 * uint256(tier) + (gain > 10 ? 10 : gain);
        uint256 ceiling = tier == 0 ? 60 : 100;
        if (body >= ceiling) return body;
        return body + credit > ceiling ? ceiling : body + credit;
    }

    function cancelTraining(uint256 petSeed, uint256 change) external {
        uint256 id = _petInActivity(petSeed, Activity.Training);
        address petOwner = nft.ownerOf(id);
        bytes memory call_ = abi.encodeCall(nft.cancelTraining, (id));
        _mustRevert(stranger, address(nft), 0, call_, "stranger cancel");
        if (change % 2 != 0) return; // half the work is left to finish
        if (nft.hamster(id).activity != Activity.Training) {
            _mustRevert(petOwner, address(nft), 0, call_, "nothing to cancel");
            hits["cancelRefused"]++;
            return;
        }
        vm.prank(petOwner);
        nft.cancelTraining(id);
        assertEq(nft.hamster(id).stamina, ghostStamina[id], "a cancel pays nothing");
        hits["cancelOk"]++;
    }

    // ------------------------------------------------------------------ waiting

    function enqueue(uint256 petSeed, uint256 fussy) external {
        // Three calls in four look for a pet that can enter, so rounds really form. The rest take whatever
        // pet the seed names, which is how the refusals get exercised.
        uint256 id = _pet(petSeed);
        if (fussy % 4 != 0) {
            for (uint256 i; i < ghostMinted && !_mayEnter(id); ++i) {
                id = 1 + (petSeed % ghostMinted + i) % ghostMinted;
            }
        }
        address petOwner = nft.ownerOf(id);
        bytes memory call_ = abi.encodeCall(queue.enqueue, (id));
        _mustRevert(stranger, address(queue), 0, call_, "stranger enqueue");
        if (!_mayEnter(id)) {
            _mustRevert(petOwner, address(queue), 0, call_, "enqueue gate");
            hits["enqueueRefused"]++;
            return;
        }
        _enter(id);
        hits["enqueueOk"]++;
    }

    function _enter(uint256 id) private {
        address petOwner = nft.ownerOf(id);
        uint256 quotaBefore = nft.matchesThisWeek(id);
        vm.prank(petOwner);
        queue.enqueue(id);
        _seenBand(nft.hamster(id).stamina / 25);
        assertEq(nft.matchesThisWeek(id), quotaBefore, "waiting spends no attempt");
        assertEq(queue.activeToken(petOwner), id);
    }

    /// @notice Brings every pet that may enter the first eligible pet's band, then locks a round. Without
    ///         this, single random entries rarely coincide in one band and rounds stay small and rare.
    function rally(uint256 petSeed, uint256 callerSeed) external {
        uint256 first;
        for (uint256 i; i < ghostMinted && first == 0; ++i) {
            uint256 id = 1 + (petSeed % ghostMinted + i) % ghostMinted;
            if (_mayEnter(id)) first = id;
        }
        if (first == 0) return;
        uint256 band = nft.hamster(first).stamina / 25;
        for (uint256 id = 1; id <= ghostMinted; ++id) {
            if (_mayEnter(id) && nft.hamster(id).stamina / 25 == band) _enter(id);
        }
        vm.roll(_block() + 10); // the anti-steering wait before any entry can be locked
        uint256 eligible = _eligibleCount(band);
        if (eligible < 2) return;
        address caller = _anyone(callerSeed);
        vm.prank(caller);
        uint256 round = queue.requestRound(band);
        _afterRequest(round, band, eligible);
        hits["rallyOk"]++;
    }

    function _mayEnter(uint256 id) private view returns (bool) {
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        return ham.activity == Activity.Idle && !nft.isHungry(id) && nft.matchesThisWeek(id) < 5
            && queue.activeToken(nft.ownerOf(id)) == 0 && queue.queueEntries(ham.stamina / 25).length < 32;
    }

    function leaveQueue(uint256 petSeed, uint256 change) external {
        uint256 id = _petInActivity(petSeed, Activity.Queued);
        address petOwner = nft.ownerOf(id);
        bytes memory call_ = abi.encodeCall(queue.leaveQueue, (id));
        _mustRevert(stranger, address(queue), 0, call_, "stranger leave");
        if (change % 4 != 0) return; // most waiting pets stay, or rounds would rarely fill
        if (nft.hamster(id).activity != Activity.Queued) {
            _mustRevert(petOwner, address(queue), 0, call_, "nothing to leave");
            hits["leaveRefused"]++;
            return;
        }
        vm.prank(petOwner);
        queue.leaveQueue(id);
        assertEq(queue.activeToken(petOwner), 0);
        hits["leaveOk"]++;
    }

    function evict(uint256 petSeed, uint256 callerSeed) external {
        uint256 id = _petInActivity(petSeed, Activity.Queued);
        address caller = _anyone(callerSeed);
        bytes memory call_ = abi.encodeCall(queue.evictExpired, (id));
        if (nft.hamster(id).activity != Activity.Queued || !_isExpired(id)) {
            _mustRevert(caller, address(queue), 0, call_, "evict gate");
            hits["evictRefused"]++;
            return;
        }
        vm.prank(caller);
        queue.evictExpired(id);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Idle));
        hits["evictOk"]++;
    }

    function _isExpired(uint256 id) private view returns (bool) {
        (uint256 band, uint256 index) = queue.position(id);
        MatchQueue.Entry memory entry = queue.queueEntries(band)[index - 1];
        return _now() > entry.joinedAt + 1 days || nft.isHungry(id);
    }

    // ------------------------------------------------------------------ rounds

    function requestRound(uint256 bandSeed, uint256 callerSeed) external {
        uint256 band = bands[bandSeed % bands.length];
        uint256 live = _eligibleCount(band);
        for (uint256 i; i < bands.length && live < 2; ++i) {
            band = bands[(bandSeed % bands.length + i) % bands.length];
            live = _eligibleCount(band);
        }
        if (live < 2 && callerSeed % 2 == 0) {
            // Wait out the anti-steering window, as a keeper watching eligibleCount would.
            vm.roll(_block() + 10);
            band = bands[bandSeed % bands.length];
            live = _eligibleCount(band);
            for (uint256 i; i < bands.length && live < 2; ++i) {
                band = bands[(bandSeed % bands.length + i) % bands.length];
                live = _eligibleCount(band);
            }
        }
        address caller = _anyone(callerSeed);
        assertEq(queue.eligibleCount(band), live, "eligibleCount view agrees with the restated rule");
        if (live < 2) {
            _mustRevert(caller, address(queue), 0, abi.encodeCall(queue.requestRound, (band)), "too few");
            hits["requestRefused"]++;
            return;
        }
        uint256 expected = live;
        vm.prank(caller);
        uint256 round = queue.requestRound(band);
        _afterRequest(round, band, expected);
        hits["requestOk"]++;
    }

    function _afterRequest(uint256 round, uint256 band, uint256 expected) private {
        MatchQueue.Snapshot[] memory racers = queue.roundRacers(round);
        assertEq(racers.length, expected, "every live pet past its wait window, odd counts included");
        _assertNoEligibleLeftBehind(band);
        (uint256 storedBand, uint256 target, uint256 week, MatchQueue.RoundStatus status,,) =
            queue.roundInfo(round);
        assertEq(storedBand, band);
        assertEq(target, _block() + 2);
        assertEq(week, _now() / 1 weeks);
        assertEq(uint256(status), uint256(MatchQueue.RoundStatus.Pending));
        for (uint256 i; i < racers.length; ++i) {
            uint256 id = racers[i].tokenId;
            HamsterRunNFT.Hamster memory ham = nft.hamster(id);
            assertEq(racers[i].stamina, ham.stamina, "stamina snapshot");
            assertEq(uint256(racers[i].weight), uint256(ham.weight), "weight snapshot");
            assertEq(racers[i].player, nft.ownerOf(id));
            assertEq(ham.stamina / 25, band, "only pets of this band");
            assertEq(uint256(ham.activity), uint256(Activity.Matched));
            assertFalse(nft.isHungry(id), "only fed pets lock");
            ghostInOpenRace[id] = true;
            ghostWeeklyLocks[id][week]++;
            assertLe(ghostWeeklyLocks[id][week], 5, "weekly limit per NFT");
            assertEq(nft.matchesThisWeek(id), ghostWeeklyLocks[id][week]);
        }
        ghostRoundStatus[round] = uint8(MatchQueue.RoundStatus.Pending);
    }

    function fulfillRound(uint256 roundSeed, uint256 callerSeed) external {
        uint256 round = _nextPendingRound(roundSeed);
        if (round == 0) return;
        uint256 target;
        (, target,,,,) = queue.roundInfo(round);
        address caller = _anyone(callerSeed);
        if (_block() <= target || _block() > target + 256) {
            _mustRevert(
                caller, address(queue), 0, abi.encodeCall(queue.fulfillRound, (round)), "outside window"
            );
            hits["fulfillRefused"]++;
            return;
        }
        _fulfill(round, target, caller);
        hits["fulfillOk"]++;
    }

    function _fulfill(uint256 round, uint256 target, address caller) private {
        vm.setBlockhash(target, keccak256(abi.encode("world entropy", target, round)));
        uint256 firstMatch = queue.matchCount() + 1;
        vm.prank(caller);
        queue.fulfillRound(round);
        ghostRoundStatus[round] = uint8(MatchQueue.RoundStatus.Fulfilled);
        (,,, MatchQueue.RoundStatus status, bytes32 seed,) = queue.roundInfo(round);
        assertEq(uint256(status), uint256(MatchQueue.RoundStatus.Fulfilled));
        assertTrue(seed != bytes32(0));
        MatchQueue.Snapshot[] memory racers = queue.roundRacers(round);
        uint256[] memory ids = queue.roundMatchIds(round);
        assertEq(ids.length, racers.length / 2);
        uint256 rosterSum;
        uint256 pairedSum;
        pairedSum = _checkBye(round, racers);
        // Multiset equality through a wrapping sum of hashes: order free, and a duplicate does not cancel.
        for (uint256 i; i < racers.length; ++i) {
            unchecked {
                rosterSum += uint256(keccak256(abi.encode(racers[i])));
            }
        }
        for (uint256 i; i < ids.length; ++i) {
            assertEq(ids[i], firstMatch + i);
            MatchQueue.Race memory race = queue.matchInfo(ids[i]);
            unchecked {
                pairedSum += uint256(keccak256(abi.encode(race.a)));
                pairedSum += uint256(keccak256(abi.encode(race.b)));
            }
            assertEq(race.roundId, round);
            assertFalse(race.settled);
            assertTrue(race.a.player != race.b.player, "nobody races themselves");
            _assertOutcomeIsConsistent(race);
            ghostRaceHash[ids[i]] = _raceHash(race);
        }
        assertEq(pairedSum, rosterSum, "every locked racer runs once, with its snapshot unchanged");
    }

    function _assertNoEligibleLeftBehind(uint256 band) private view {
        MatchQueue.Entry[] memory left = queue.queueEntries(band);
        for (uint256 i; i < left.length; ++i) {
            assertGt(left[i].joinedBlock + 10, _block(), "no eligible live pet is left behind");
        }
    }

    /// @return byeHash the bye's snapshot hash, or 0 for an even round
    function _checkBye(uint256 round, MatchQueue.Snapshot[] memory racers) private returns (uint256 byeHash) {
        uint256 bye = queue.roundBye(round);
        if (racers.length % 2 == 0) {
            assertEq(bye, 0, "an even round has no bye");
            return 0;
        }
        (,, uint256 week,,,) = queue.roundInfo(round);
        uint256 found;
        for (uint256 i; i < racers.length; ++i) {
            if (racers[i].tokenId != bye) continue;
            ++found;
            byeHash = uint256(keccak256(abi.encode(racers[i])));
            assertEq(queue.activeToken(racers[i].player), 0, "the bye's wallet is freed");
        }
        assertEq(found, 1, "the bye is exactly one locked racer");
        assertEq(uint256(nft.hamster(bye).activity), uint256(Activity.Idle), "the bye is released");
        ghostInOpenRace[bye] = false;
        // The attempt is handed back in the quota week it was taken from.
        ghostWeeklyLocks[bye][week]--;
        if (_now() / 1 weeks == week) {
            assertEq(nft.matchesThisWeek(bye), ghostWeeklyLocks[bye][week], "bye attempt refunded");
        }
        hits["byeOk"]++;
    }

    function _assertOutcomeIsConsistent(MatchQueue.Race memory race) private pure {
        assertTrue(race.winner == race.a.tokenId || race.winner == race.b.tokenId);
        if (race.scoreA > race.scoreB) assertEq(race.winner, race.a.tokenId);
        if (race.scoreB > race.scoreA) assertEq(race.winner, race.b.tokenId);
        // Whatever the noise was, a score stays inside what the snapshot allows.
        assertGe(race.scoreA, GameMath.raceScore(race.a.stamina, race.a.weight, 0));
        assertLe(race.scoreA, GameMath.raceScore(race.a.stamina, race.a.weight, 2000));
        assertGe(race.scoreB, GameMath.raceScore(race.b.stamina, race.b.weight, 0));
        assertLe(race.scoreB, GameMath.raceScore(race.b.stamina, race.b.weight, 2000));
    }

    function expireRound(uint256 roundSeed, uint256 callerSeed) external {
        uint256 round = _nextPendingRound(roundSeed);
        if (round == 0) return;
        uint256 target;
        (, target,,,,) = queue.roundInfo(round);
        address caller = _anyone(callerSeed);
        if (_block() <= target + 256) {
            _mustRevert(caller, address(queue), 0, abi.encodeCall(queue.expireRound, (round)), "still live");
            hits["expireRefused"]++;
            return;
        }
        _expire(round, caller);
        hits["expireOk"]++;
    }

    function _expire(uint256 round, address caller) private {
        vm.prank(caller);
        queue.expireRound(round);
        ghostRoundStatus[round] = uint8(MatchQueue.RoundStatus.Expired);
        MatchQueue.Snapshot[] memory racers = queue.roundRacers(round);
        for (uint256 i; i < racers.length; ++i) {
            ghostInOpenRace[racers[i].tokenId] = false;
        }
        assertEq(queue.roundMatchIds(round).length, 0);
    }

    function settleMatch(uint256 matchSeed, uint256 callerSeed) external {
        uint256 count = queue.matchCount();
        address caller = _anyone(callerSeed);
        if (count == 0) {
            _mustRevert(caller, address(queue), 0, abi.encodeCall(queue.settleMatch, (1)), "no such match");
            return;
        }
        uint256 matchId = 1 + matchSeed % count;
        for (uint256 i; i < count && queue.matchInfo(matchId).settled; ++i) {
            matchId = 1 + (matchSeed % count + i) % count;
        }
        if (queue.matchInfo(matchId).settled) {
            _mustRevert(
                caller, address(queue), 0, abi.encodeCall(queue.settleMatch, (matchId)), "already settled"
            );
            hits["settleMatchRefused"]++;
            return;
        }
        _settleMatch(matchId, caller);
        hits["settleMatchOk"]++;
    }

    function _settleMatch(uint256 matchId, address caller) private {
        MatchQueue.Race memory race = queue.matchInfo(matchId);
        (,, uint256 week,,,) = queue.roundInfo(race.roundId);
        uint256 weekA = queue.weeklyPoints(week, race.a.player);
        uint256 weekB = queue.weeklyPoints(week, race.b.player);
        vm.prank(caller);
        queue.settleMatch(matchId);
        bool aWon = race.winner == race.a.tokenId;
        ghostPoints[race.a.player] += aWon ? 10 : 2;
        ghostPoints[race.b.player] += aWon ? 2 : 10;
        ghostStamina[race.a.tokenId] += aWon ? 3 : 1;
        ghostStamina[race.b.tokenId] += aWon ? 1 : 3;
        ghostInOpenRace[race.a.tokenId] = false;
        ghostInOpenRace[race.b.tokenId] = false;
        ghostRaceSettled[matchId] = true;
        ++ghostSettled;
        assertEq(queue.weeklyPoints(week, race.a.player), weekA + (aWon ? 10 : 2), "lock week credit");
        assertEq(queue.weeklyPoints(week, race.b.player), weekB + (aWon ? 2 : 10), "lock week credit");
        assertEq(queue.activeToken(race.a.player), 0);
        assertEq(queue.activeToken(race.b.player), 0);
        _mustRevert(caller, address(queue), 0, abi.encodeCall(queue.settleMatch, (matchId)), "settled twice");
    }

    // ------------------------------------------------------------------ custody

    function transferPet(uint256 petSeed, uint256 toSeed) external {
        uint256 id = _pet(petSeed);
        address from = nft.ownerOf(id);
        address to = actors[toSeed % 10];
        bytes memory call_ = abi.encodeCall(nft.transferFrom, (from, to, id));
        _mustRevert(stranger, address(nft), 0, call_, "unapproved transfer");
        if (nft.hamster(id).activity != Activity.Idle) {
            _mustRevert(from, address(nft), 0, call_, "locked transfer");
            hits["transferLocked"]++;
            return;
        }
        bytes memory before = abi.encode(nft.hamster(id));
        uint256 quota = nft.matchesThisWeek(id);
        vm.prank(from);
        nft.transferFrom(from, to, id);
        assertEq(nft.ownerOf(id), to);
        assertEq(abi.encode(nft.hamster(id)), before, "a transfer resets nothing");
        assertEq(nft.matchesThisWeek(id), quota, "a transfer refunds no attempt");
        hits["transferOk"]++;
    }

    // ------------------------------------------------------------------ owner and ETH

    function withdraw(uint256 amountSeed, uint256) external {
        uint256 balance = address(nft).balance;
        if (balance == 0) {
            _mustRevert(gameOwner, address(nft), 0, abi.encodeCall(nft.withdraw, (1)), "empty");
            return;
        }
        // One in four withdraws everything.
        uint256 amount = amountSeed % 4 == 0 ? balance : 1 + amountSeed % balance;
        _mustRevert(stranger, address(nft), 0, abi.encodeCall(nft.withdraw, (amount)), "stranger withdraw");
        _mustRevert(gameOwner, address(nft), 0, abi.encodeCall(nft.withdraw, (balance + 1)), "too much");
        _mustRevert(gameOwner, address(nft), 0, abi.encodeCall(nft.withdraw, (0)), "zero");
        vm.prank(gameOwner);
        nft.withdraw(amount);
        withdrawn += amount;
        hits["withdrawOk"]++;
    }

    function forceEth(uint256 amountSeed, uint256) external {
        uint256 amount = 1 + amountSeed % 0.01 ether;
        vm.deal(address(this), amount);
        new ForceSend{ value: amount }(payable(address(nft)));
        forced += amount;
        hits["forceOk"]++;
    }

    function setFoodConfig(uint256 a, uint256 b) external {
        uint256 p0 = 1 + a % 0.001 ether;
        uint256 p1 = p0 + 1 + (a >> 64) % 0.001 ether;
        uint256 p2 = p1 + 1 + (a >> 128) % 0.001 ether;
        uint256 b0 = 10_000 + b % 5_000;
        uint256 b1 = b0 + 5000 + (b >> 64) % 10_000;
        uint256 b2 = b1 + 5000 + (b >> 128) % (45_001 - b1);
        uint256[3] memory prices = [p0, p1, p2];
        uint256[3] memory bps = [b0, b1, b2];
        _mustRevert(
            stranger, address(nft), 0, abi.encodeCall(nft.setFoodConfig, (prices, bps)), "stranger config"
        );
        uint256[3] memory bad = [p1, p1, p2];
        _mustRevert(gameOwner, address(nft), 0, abi.encodeCall(nft.setFoodConfig, (bad, bps)), "equal prices");
        vm.prank(gameOwner);
        nft.setFoodConfig(prices, bps);
        hits["configOk"]++;
    }

    /// @dev A stranger aiming at privileged entries, including every method reserved for the bound queue.
    function strangerProbes(uint256 petSeed, uint256) external {
        uint256 id = _pet(petSeed);
        address nftAddress = address(nft);
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.setMintOpen, (false)), "mintOpen");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.ownerMint, (stranger)), "ownerMint");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.setMatchQueue, (address(queue))), "bind");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.transferOwnership, (stranger)), "handover");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.acceptOwnership, ()), "accept");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.lockQueue, (id, stranger)), "lockQueue");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.lockMatch, (id)), "lockMatch");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.unlockQueue, (id)), "unlockQueue");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.releaseBye, (id)), "releaseBye");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.expireMatchLock, (id)), "expireMatchLock");
        _mustRevert(stranger, nftAddress, 0, abi.encodeCall(nft.rewardMatch, (id, true)), "rewardMatch");
        hits["strangerRefused"]++;
    }

    // ------------------------------------------------------------------ clock

    function advanceTime(uint256 seed, uint256) external {
        uint256 pick = seed % 20;
        uint256 step = pick == 0 ? seed % 8 days : pick < 4 ? seed % 36 hours : seed % 6 hours;
        vm.warp(_now() + step);
        uint64 ended = uint64((_now() - nft.core().configuration().genesisTimestamp) / 600);
        if (ended > nft.core().state().settledThroughRound && seed % 2 == 0) {
            MockSqueekCore(address(nft.core())).certify(ended, uint64(seed % 31));
        }
    }

    function advanceBlocks(uint256 seed, uint256) external {
        uint256 step = seed % 6 == 0 ? 230 + seed % 200 : 1 + seed % 5;
        vm.roll(_block() + step);
    }

    // ------------------------------------------------------------------ end of sequence recovery

    /// @notice Whatever a sequence did, permissionless and owner calls must return every pet to Idle.
    function drainEverything() external {
        for (uint256 id = 1; id <= ghostMinted; ++id) {
            Activity activity = nft.hamster(id).activity;
            if (activity == Activity.Training) {
                (uint64 start, uint64 end, uint256 bps, uint8 tier) = nft.training(id);
                uint256 elapsedAt = uint256(nft.core().configuration().genesisTimestamp) + uint256(end) * 600;
                if (_now() < elapsedAt) vm.warp(elapsedAt);
                if (nft.core().state().settledThroughRound < end) {
                    MockSqueekCore(address(nft.core())).certify(end, 5);
                }
                ISqueekCore.RoundPage memory page = nft.core().roundPage(start - 1, end, 6);
                uint256 gain = uint256(page.end.cumulativeWork - page.start.cumulativeWork) * 2 * bps / 10_000;
                _settleTraining(id, gain, tier, stranger);
            } else if (activity == Activity.Queued) {
                address petOwner = nft.ownerOf(id);
                vm.prank(petOwner);
                queue.leaveQueue(id);
            }
        }
        uint256 rounds = queue.roundCount();
        for (uint256 round = 1; round <= rounds; ++round) {
            (, uint256 target,, MatchQueue.RoundStatus status,,) = queue.roundInfo(round);
            if (status != MatchQueue.RoundStatus.Pending) continue;
            if (_block() <= target) vm.roll(target + 1);
            if (_block() <= target + 256) _fulfill(round, target, stranger);
            else _expire(round, stranger);
        }
        uint256 matches = queue.matchCount();
        for (uint256 matchId = 1; matchId <= matches; ++matchId) {
            if (!queue.matchInfo(matchId).settled) _settleMatch(matchId, stranger);
        }
    }

    // ------------------------------------------------------------------ helpers

    function bandCount() external view returns (uint256) {
        return bands.length;
    }

    function hitsOf(string calldata label) external view returns (uint256) {
        return hits[label];
    }

    function _raceHash(MatchQueue.Race memory race) private pure returns (bytes32) {
        return keccak256(abi.encode(race.roundId, race.a, race.b, race.scoreA, race.scoreB, race.winner));
    }

    function raceHashOf(uint256 matchId) external view returns (bytes32) {
        return _raceHash(queue.matchInfo(matchId));
    }

    function _liveCount(uint256 band) private view returns (uint256 live) {
        MatchQueue.Entry[] memory entries = queue.queueEntries(band);
        for (uint256 i; i < entries.length; ++i) {
            if (!nft.isHungry(entries[i].tokenId) && _now() <= entries[i].joinedAt + 1 days) ++live;
        }
    }

    /// @dev Restates DESIGN's rule: live (fed, within TTL) and at least 10 blocks since joining.
    function _eligibleCount(uint256 band) private view returns (uint256 eligible) {
        MatchQueue.Entry[] memory entries = queue.queueEntries(band);
        for (uint256 i; i < entries.length; ++i) {
            if (
                !nft.isHungry(entries[i].tokenId) && _now() <= entries[i].joinedAt + 1 days
                    && _block() >= entries[i].joinedBlock + 10
            ) ++eligible;
        }
    }

    function _nextPendingRound(uint256 seed) private view returns (uint256) {
        uint256 count = queue.roundCount();
        for (uint256 i; i < count; ++i) {
            uint256 round = 1 + (seed % count + i) % count;
            (,,, MatchQueue.RoundStatus status,,) = queue.roundInfo(round);
            if (status == MatchQueue.RoundStatus.Pending) return round;
        }
        return 0;
    }

    function _pet(uint256 seed) private view returns (uint256) {
        return 1 + seed % ghostMinted;
    }

    /// @dev Prefers a pet in `wanted`, so the matching action fires often. Falls back to any pet.
    function _petInActivity(uint256 seed, Activity wanted) private view returns (uint256) {
        for (uint256 i; i < ghostMinted; ++i) {
            uint256 id = 1 + (seed % ghostMinted + i) % ghostMinted;
            if (nft.hamster(id).activity == wanted) return id;
        }
        return _pet(seed);
    }

    function _anyone(uint256 seed) private view returns (address) {
        uint256 pick = seed % 12;
        return pick < 10 ? actors[pick] : pick == 10 ? stranger : gameOwner;
    }

    function _seenBand(uint256 band) private {
        if (_bandSeen[band]) return;
        _bandSeen[band] = true;
        bands.push(band);
    }

    function _now() private view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _block() private view returns (uint256) {
        return vm.getBlockNumber();
    }

    function _mustRevert(address from, address target, uint256 value, bytes memory data, string memory why)
        private
    {
        vm.prank(from);
        (bool ok,) = target.call{ value: value }(data);
        assertFalse(ok, why);
    }

    receive() external payable { }
}

/// @notice A contract that keeps value, supply and points needs properties over random call sequences.
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract StatefulInvariantsTest is GameTest {
    WorldHandler private world;

    function setUp() public override {
        super.setUp();
        world = new WorldHandler(nft, queue, owner);
        world.bootstrap();
        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = world.feed.selector;
        selectors[1] = world.feedBadly.selector;
        selectors[2] = world.startTraining.selector;
        selectors[3] = world.settleTraining.selector;
        selectors[4] = world.cancelTraining.selector;
        selectors[5] = world.enqueue.selector;
        selectors[6] = world.leaveQueue.selector;
        selectors[7] = world.evict.selector;
        selectors[8] = world.requestRound.selector;
        selectors[9] = world.fulfillRound.selector;
        selectors[10] = world.expireRound.selector;
        selectors[11] = world.settleMatch.selector;
        selectors[12] = world.transferPet.selector;
        selectors[13] = world.withdraw.selector;
        selectors[14] = world.forceEth.selector;
        selectors[15] = world.setFoodConfig.selector;
        selectors[16] = world.strangerProbes.selector;
        selectors[17] = world.advanceTime.selector;
        selectors[18] = world.advanceBlocks.selector;
        selectors[19] = world.rally.selector;
        targetContract(address(world));
        targetSelector(FuzzSelector({ addr: address(world), selectors: selectors }));
        // Minting changes the set of pets every invariant loops over, so it has its own test below.
    }

    // ------------------------------------------------------------------ conservation

    /// @dev Everything that ever entered is still here or reached the owner, and only the owner.
    function invariant_ethInEqualsEthHeldPlusEthWithdrawn() public view {
        assertEq(address(nft).balance + world.withdrawn(), world.paid() + world.forced());
        assertEq(owner.balance, world.withdrawn(), "fees reach the owner and nobody else");
        assertEq(address(queue).balance, 0, "the queue never holds ETH");
    }

    function invariant_pointsComeOnlyFromSettledRaces() public view {
        uint256 sum;
        for (uint256 i; i < 10; ++i) {
            address actor = world.actors(i);
            assertEq(queue.points(actor), world.ghostPoints(actor));
            sum += queue.points(actor);
        }
        assertEq(queue.points(world.stranger()), 0, "a keeper earns no points");
        assertEq(queue.points(owner), 0, "the owner earns no points");
        assertEq(queue.totalPoints(), sum);
        assertEq(sum, world.ghostSettled() * 12, "each race pays exactly 10 + 2");
    }

    function invariant_staminaComesOnlyFromTrainingAndRaces() public view {
        uint256 supply = nft.totalSupply();
        uint256 sum;
        for (uint256 id = 1; id <= supply; ++id) {
            uint256 stamina = nft.hamster(id).stamina;
            assertEq(stamina, world.ghostStamina(id));
            assertGe(stamina, 10, "stamina never falls below the start value");
            sum += stamina;
        }
        assertEq(sum, supply * 10 + world.ghostTrainingGain() + world.ghostSettled() * 4);
    }

    function invariant_supplyIsExactlyWhatWasMinted() public view {
        uint256 supply = nft.totalSupply();
        assertEq(supply, world.ghostMinted());
        assertLe(supply, 9999);
        uint256 balances;
        for (uint256 i; i < 10; ++i) {
            balances += nft.balanceOf(world.actors(i));
        }
        assertEq(balances, supply, "every pet is held by a tracked wallet");
        for (uint256 id = 1; id <= supply; ++id) {
            assertTrue(nft.ownerOf(id) != address(0));
        }
    }

    // ------------------------------------------------------------------ flag and data agree

    function invariant_queueAndActivityDescribeTheSameThing() public view {
        uint256 supply = nft.totalSupply();
        uint256 queued;
        for (uint256 id = 1; id <= supply; ++id) {
            HamsterRunNFT.Hamster memory ham = nft.hamster(id);
            (uint256 band, uint256 index) = queue.position(id);
            if (ham.activity == Activity.Queued) {
                ++queued;
                assertEq(band, ham.stamina / 25, "stamina cannot move while waiting");
                MatchQueue.Entry[] memory entries = queue.queueEntries(band);
                assertGt(index, 0);
                assertLe(index, entries.length);
                assertEq(entries[index - 1].tokenId, id);
                assertEq(entries[index - 1].player, nft.ownerOf(id));
            } else {
                assertEq(index, 0, "only waiting pets have a queue position");
            }
        }
        uint256 waiting;
        uint256 bandTotal = world.bandCount();
        for (uint256 i; i < bandTotal; ++i) {
            uint256 length = queue.queueEntries(world.bands(i)).length;
            assertLe(length, 32);
            waiting += length;
        }
        assertEq(waiting, queued, "no tombstones and no entry without a waiting pet");
    }

    function invariant_walletLockMatchesTheOnePetItNames() public view {
        uint256 supply = nft.totalSupply();
        for (uint256 i; i < 10; ++i) {
            address actor = world.actors(i);
            uint256 active = queue.activeToken(actor);
            uint256 racing;
            for (uint256 id = 1; id <= supply; ++id) {
                Activity activity = nft.hamster(id).activity;
                if (nft.ownerOf(id) == actor && (activity == Activity.Queued || activity == Activity.Matched))
                {
                    ++racing;
                    assertEq(active, id, "the lock names the racing pet");
                }
            }
            assertLe(racing, 1, "one active pet per wallet");
            if (racing == 0) assertEq(active, 0, "a free wallet holds no stale lock");
        }
    }

    function invariant_lockedActivityMatchesItsBackingRecord() public view {
        uint256 supply = nft.totalSupply();
        for (uint256 id = 1; id <= supply; ++id) {
            Activity activity = nft.hamster(id).activity;
            assertEq(activity == Activity.Matched, world.ghostInOpenRace(id), "Matched iff in an open race");
            (uint64 start, uint64 end, uint256 bps,) = nft.training(id);
            assertEq(activity == Activity.Training, start != 0, "Training iff a booking exists");
            assertEq(activity == Activity.Training, bps != 0);
            if (activity == Activity.Training) assertEq(end, start + 5);
        }
    }

    function invariant_bodyAndFoodStayInRange() public view {
        uint256 supply = nft.totalSupply();
        uint256 timestamp = vm.getBlockTimestamp();
        for (uint256 id = 1; id <= supply; ++id) {
            HamsterRunNFT.Hamster memory ham = nft.hamster(id);
            assertLe(ham.bodyScore, 100);
            // Pinned class bands, restated so a mistake in weightClass cannot hide.
            WeightClass expected = ham.bodyScore >= 70
                ? WeightClass.Fit
                : ham.bodyScore >= 35 ? WeightClass.Normal : WeightClass.Obese;
            assertEq(uint256(ham.weight), uint256(expected));
            assertEq(ham.fedUntil, world.ghostFedUntil(id));
            assertLe(ham.fedUntil, timestamp + 72 hours);
            assertEq(nft.isHungry(id), ham.fedUntil == 0 || timestamp > ham.fedUntil);
            assertLe(ham.foodTier, 2);
            assertGe(ham.trainBps, 10_000);
            assertLe(ham.trainBps, 50_000);
            assertLe(nft.matchesThisWeek(id), 5);
        }
    }

    // ------------------------------------------------------------------ finished states never reopen

    function invariant_roundsAndRacesNeverLeaveAFinishedState() public view {
        uint256 rounds = queue.roundCount();
        for (uint256 round = 1; round <= rounds; ++round) {
            (,,, MatchQueue.RoundStatus status, bytes32 seed, uint256 count) = queue.roundInfo(round);
            assertEq(uint8(status), world.ghostRoundStatus(round), "only legal transitions");
            assertGe(count, 2);
            _assertByeRecord(round, status == MatchQueue.RoundStatus.Fulfilled && count % 2 == 1);
            assertLe(count, 32);
            uint256 raceCount = queue.roundMatchIds(round).length;
            if (status == MatchQueue.RoundStatus.Fulfilled) {
                assertTrue(seed != bytes32(0));
                assertEq(raceCount, count / 2);
            } else {
                assertEq(seed, bytes32(0));
                assertEq(raceCount, 0);
            }
        }
        uint256 matches = queue.matchCount();
        for (uint256 matchId = 1; matchId <= matches; ++matchId) {
            assertEq(
                world.raceHashOf(matchId), world.ghostRaceHash(matchId), "a stored outcome never changes"
            );
            assertEq(queue.matchInfo(matchId).settled, world.ghostRaceSettled(matchId));
        }
    }

    function _assertByeRecord(uint256 round, bool expectBye) private view {
        if (expectBye) assertTrue(queue.roundBye(round) != 0, "a fulfilled odd round names its bye");
        else assertEq(queue.roundBye(round), 0, "only a fulfilled odd round has a bye");
    }

    // ------------------------------------------------------------------ liveness

    /// @dev Runs once after each sequence. No sequence may strand a pet, a wallet lock or a fee.
    function afterInvariant() public {
        _drainAndAssertEverythingIsFree();
    }

    function _drainAndAssertEverythingIsFree() private {
        world.drainEverything();
        uint256 supply = nft.totalSupply();
        for (uint256 id = 1; id <= supply; ++id) {
            HamsterRunNFT.Hamster memory ham = nft.hamster(id);
            assertEq(uint256(ham.activity), uint256(Activity.Idle), "stranded pet");
            assertEq(queue.activeToken(nft.ownerOf(id)), 0, "stranded wallet lock");
            assertEq(ham.stamina, world.ghostStamina(id));
        }
        uint256 bandTotal = world.bandCount();
        for (uint256 i; i < bandTotal; ++i) {
            assertEq(queue.queueEntries(world.bands(i)).length, 0, "stranded queue entry");
        }
        uint256 balance = address(nft).balance;
        if (balance > 0) {
            vm.prank(owner);
            nft.withdraw(balance);
        }
        assertEq(address(nft).balance, 0);
        assertEq(owner.balance, world.paid() + world.forced(), "the owner can always take everything out");

        // A freed pet is still a fully working pet, whatever happened to it.
        uint256 feedPrice = nft.foodPrices(2);
        for (uint256 id = 1; id <= supply; ++id) {
            address petOwner = nft.ownerOf(id);
            vm.prank(petOwner);
            nft.feed{ value: feedPrice }(id, 2);
            vm.prank(petOwner);
            nft.startTraining(id);
        }
    }

    // ------------------------------------------------------------------ anti-vacuity

    /// @dev A seeded walk through the same handler, in the same proportions as the campaign. It proves that
    ///      each branch the invariants lean on is reached, so they are not passing over an empty game.
    function test_seededWalkReachesEveryOutcomeAndKeepsEveryInvariant() public {
        string[25] memory labels = [
            "feedOk",
            "feedLocked",
            "feedRefused",
            "trainOk",
            "trainRefused",
            "settleTrainingOk",
            "settleTrainingRefused",
            "cancelOk",
            "enqueueOk",
            "enqueueRefused",
            "leaveOk",
            "evictOk",
            "requestOk",
            "rallyOk",
            "requestRefused",
            "fulfillOk",
            "expireOk",
            "settleMatchOk",
            "transferOk",
            "transferLocked",
            "withdrawOk",
            "forceOk",
            "configOk",
            "strangerRefused",
            "byeOk"
        ];
        bytes4[20] memory selectors = [
            world.feed.selector,
            world.feedBadly.selector,
            world.startTraining.selector,
            world.settleTraining.selector,
            world.cancelTraining.selector,
            world.enqueue.selector,
            world.leaveQueue.selector,
            world.evict.selector,
            world.requestRound.selector,
            world.fulfillRound.selector,
            world.expireRound.selector,
            world.settleMatch.selector,
            world.transferPet.selector,
            world.withdraw.selector,
            world.forceEth.selector,
            world.setFoodConfig.selector,
            world.strangerProbes.selector,
            world.advanceTime.selector,
            world.advanceBlocks.selector,
            world.rally.selector
        ];
        for (uint256 step; step < 1200; ++step) {
            uint256 a = uint256(keccak256(abi.encode("walk a", step)));
            uint256 b = uint256(keccak256(abi.encode("walk b", step)));
            (bool ok, bytes memory reason) =
                address(world).call(abi.encodeWithSelector(selectors[a % 20], a >> 8, b));
            if (!ok) {
                emit log_named_uint("step", step);
                emit log_named_uint("entry", a % 20);
                emit log_named_bytes("reason", reason);
                fail();
            }
            if (step % 100 == 0) _allInvariants();
        }
        for (uint256 i; i < labels.length; ++i) {
            emit log_named_uint(labels[i], world.hitsOf(labels[i]));
            assertGt(world.hitsOf(labels[i]), 0, labels[i]);
        }
        _allInvariants();
        _drainAndAssertEverythingIsFree();
    }

    function test_freeMintsKeepTheSupplyAndAllocationLedgers() public {
        for (uint256 i; i < 10; ++i) {
            world.mintNew(i, 0);
        }
        assertEq(world.ghostFreeMints(), 10, "each of the ten wallets got exactly one");
        for (uint256 i; i < 10; ++i) {
            world.mintNew(i, 0);
            assertTrue(nft.freeMinted(world.actors(i)));
        }
        assertEq(world.ghostFreeMints(), 10, "a second free mint added nothing");
        assertEq(world.hitsOf("mintRefused"), 16, "six wallets once more than the other four");
        assertEq(nft.totalSupply(), 12);
        _allInvariantsExceptFood();
    }

    function _allInvariants() private view {
        invariant_bodyAndFoodStayInRange();
        _allInvariantsExceptFood();
    }

    function _allInvariantsExceptFood() private view {
        invariant_ethInEqualsEthHeldPlusEthWithdrawn();
        invariant_pointsComeOnlyFromSettledRaces();
        invariant_staminaComesOnlyFromTrainingAndRaces();
        invariant_supplyIsExactlyWhatWasMinted();
        invariant_queueAndActivityDescribeTheSameThing();
        invariant_walletLockMatchesTheOnePetItNames();
        invariant_lockedActivityMatchesItsBackingRecord();
        invariant_roundsAndRacesNeverLeaveAFinishedState();
    }
}
