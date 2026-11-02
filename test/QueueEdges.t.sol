// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest, HamsterHarness } from "./helpers/GameTest.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, WeightClass } from "../src/GameMath.sol";

/// @notice Queue, round, randomness and settlement paths the happy flow never reaches.
contract QueueEdgesTest is GameTest {
    function _harness() private returns (HamsterHarness harness) {
        harness = new HamsterHarness(owner, address(core));
        nft = harness;
        queue = new MatchQueue(address(nft));
        vm.startPrank(owner);
        nft.setMintOpen(true);
        nft.setMatchQueue(address(queue));
        vm.stopPrank();
    }

    function _wallet(string memory label) private returns (address wallet) {
        wallet = makeAddr(label);
        vm.deal(wallet, 1 ether);
    }

    function _status(uint256 round) private view returns (MatchQueue.RoundStatus status) {
        (,,, status,,) = queue.roundInfo(round);
    }

    function _target(uint256 round) private view returns (uint256 target) {
        (, target,,,,) = queue.roundInfo(round);
    }

    // ---------------------------------------------------------------- band and wallet locks

    function test_bandEdgesSeparateAt500AndPairInsideTheBand() public {
        HamsterHarness harness = _harness();
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        harness.setStaminaForTest(a, 499);
        harness.setStaminaForTest(b, 500);
        harness.setStaminaForTest(c, 999);
        assertEq(queue.bandOf(a), 0);
        assertEq(queue.bandOf(b), 1);
        assertEq(queue.bandOf(c), 1);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _waitQueueWindow();
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(1);
        _enqueue(carol, c);
        _waitQueueWindow();
        uint256 round = queue.requestRound(1);
        assertEq(queue.roundRacers(round).length, 2);
        (uint256 band,,,,,) = queue.roundInfo(round);
        assertEq(band, 1);
        assertEq(queue.queueEntries(0)[0].tokenId, a, "the other band is left alone");
    }

    function test_oneWalletRacesOnePetAcrossAllBandsUntilSettled() public {
        HamsterHarness harness = _harness();
        uint256 low = _mintFed(alice, 0);
        vm.prank(owner);
        uint256 high = nft.ownerMint(alice);
        _feed(alice, high, 2);
        harness.setStaminaForTest(high, 2000);
        assertEq(queue.bandOf(low), 0);
        assertEq(queue.bandOf(high), 3);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, low);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.PlayerAlreadyActive.selector);
        queue.enqueue(high);
        uint256 round = _pairIn(bob, b, 0);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.PlayerAlreadyActive.selector);
        queue.enqueue(high);
        uint256[] memory ids = _fulfill(round, keccak256("wallet lock"));
        vm.prank(alice);
        vm.expectRevert(MatchQueue.PlayerAlreadyActive.selector);
        queue.enqueue(high);
        queue.settleMatch(ids[0]);
        _enqueue(alice, high);
        assertEq(queue.activeToken(alice), high);
    }

    function _pairIn(address player, uint256 id, uint256 band) private returns (uint256) {
        _enqueue(player, id);
        _waitQueueWindow();
        return queue.requestRound(band);
    }

    function test_idlePetTransferredAwayDoesNotCarryTheWalletLock() public {
        uint256 a = _mintFed(alice, 0);
        vm.prank(owner);
        uint256 spare = nft.ownerMint(alice);
        _feed(alice, spare, 0);
        _enqueue(alice, a);
        vm.prank(alice);
        nft.transferFrom(alice, bob, spare);
        _enqueue(bob, spare);
        assertEq(queue.activeToken(alice), a);
        assertEq(queue.activeToken(bob), spare);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.NotTokenOwner.selector);
        queue.leaveQueue(spare);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        uint256[] memory ids = _fulfill(round, keccak256("new owner earns"));
        queue.settleMatch(ids[0]);
        assertEq(queue.points(alice) + queue.points(bob), 12);
        assertGe(queue.points(bob), 2, "the racing owner earns, not the wallet that minted the pet");
    }

    function test_pointsStayWithTheRacerAfterThePetIsSold() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("points stay"));
        queue.settleMatch(ids[0]);
        uint256 earned = queue.points(alice);
        assertGt(earned, 0);
        vm.prank(alice);
        nft.transferFrom(alice, carol, a);
        assertEq(queue.points(alice), earned);
        assertEq(queue.points(carol), 0);
    }

    // ---------------------------------------------------------------- liveness boundaries at lock

    function test_requestIncludesAnEntryAtExactTtlAndPrunesItOneSecondLater() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        uint256 joined = block.timestamp;
        _waitQueueWindow();
        uint256 saved = vm.snapshotState();
        vm.warp(joined + queue.QUEUE_TTL());
        assertEq(queue.roundRacers(queue.requestRound(0)).length, 2);
        assertTrue(vm.revertToState(saved));
        vm.warp(joined + queue.QUEUE_TTL() + 1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
    }

    function test_requestIncludesAPetAtExactFedUntilAndPrunesItOneSecondLater() public {
        uint256 a = _mintFed(alice, 0);
        vm.warp(block.timestamp + 72 hours - 1);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        uint256 c = _mintFed(carol, 0);
        _enqueue(carol, c);
        _waitQueueWindow();
        uint256 saved = vm.snapshotState();

        // Second 72h - 1 plus one: alice is at her exact deadline and is still fed.
        vm.warp(block.timestamp + 1);
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round)[0].tokenId, a);

        assertTrue(vm.revertToState(saved));
        vm.warp(block.timestamp + 2);
        round = queue.requestRound(0);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle), "alice was pruned");
        assertEq(queue.activeToken(alice), 0);
        assertEq(nft.matchesThisWeek(a), 0);
        assertEq(queue.roundRacers(round).length, 2);
    }

    function test_mixedStaleAndOddRosterLocksEveryEligiblePetAndLeavesOnlyTheNewcomer() public {
        address[6] memory wallets = [alice, bob, carol, _wallet("dave"), _wallet("erin"), _wallet("frank")];
        uint256[6] memory pets;
        pets[0] = _mintFed(wallets[0], 0);
        pets[2] = _mintFed(wallets[2], 0);
        _enqueue(wallets[0], pets[0]);
        _enqueue(wallets[2], pets[2]);
        vm.warp(block.timestamp + queue.QUEUE_TTL() + 1);
        pets[1] = _mintFed(wallets[1], 0);
        pets[3] = _mintFed(wallets[3], 0);
        pets[4] = _mintFed(wallets[4], 0);
        _enqueue(wallets[1], pets[1]);
        _enqueue(wallets[3], pets[3]);
        _enqueue(wallets[4], pets[4]);
        _waitQueueWindow();
        // Joins in the very block of the request: live, but not yet eligible.
        pets[5] = _mintFed(wallets[5], 0);
        _enqueue(wallets[5], pets[5]);
        assertEq(queue.eligibleCount(0), 3, "stale pets and the newcomer are not counted");

        uint256 round = queue.requestRound(0);
        MatchQueue.Snapshot[] memory racers = queue.roundRacers(round);
        assertEq(racers.length, 3, "an odd eligible roster is locked whole");
        uint256 lockedSum;
        for (uint256 i; i < 3; ++i) {
            lockedSum += racers[i].tokenId;
            assertTrue(racers[i].tokenId != pets[5], "the newcomer is never locked");
            assertEq(uint256(nft.hamster(racers[i].tokenId).activity), uint256(Activity.Matched));
        }
        assertEq(lockedSum, pets[1] + pets[3] + pets[4]);
        assertEq(uint256(nft.hamster(pets[0]).activity), uint256(Activity.Idle));
        assertEq(uint256(nft.hamster(pets[2]).activity), uint256(Activity.Idle));
        MatchQueue.Entry[] memory left = queue.queueEntries(0);
        assertEq(left.length, 1);
        assertEq(left[0].tokenId, pets[5]);
        (uint256 band, uint256 index) = queue.position(pets[5]);
        assertEq(band, 0);
        assertEq(index, 1, "swap removal repaired the newcomer's index");
        assertEq(left[0].joinedBlock, vm.getBlockNumber(), "swap removal keeps the original join block");
        assertEq(uint256(nft.hamster(pets[5]).activity), uint256(Activity.Queued));
        assertEq(nft.matchesThisWeek(pets[5]), 0, "the waiting newcomer paid nothing");

        // The newcomer becomes eligible only after its own wait, and alone it still cannot race.
        _waitQueueWindow();
        assertEq(queue.eligibleCount(0), 1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
    }

    function test_fullBandOfStaleEntriesBlocksEntryUntilOneIsEvicted() public {
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            address player = _wallet(string.concat("stale", vm.toString(i)));
            ids[i] = _mintFed(player, 0);
            _enqueue(player, ids[i]);
        }
        vm.warp(block.timestamp + queue.QUEUE_TTL() + 1);
        uint256 fresh = _mintFed(alice, 0);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.QueueFull.selector);
        queue.enqueue(fresh);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        assertEq(queue.queueEntries(0).length, 32, "the failed request rolled its pruning back");

        vm.prank(keeper);
        queue.evictExpired(ids[0]);
        _enqueue(alice, fresh);
        (, uint256 index) = queue.position(ids[31]);
        assertEq(index, 1, "the last entry filled the evicted slot");

        // One live pet joins a second; a request then clears every stale entry at once.
        uint256 second = _mintFed(bob, 0);
        vm.prank(keeper);
        queue.evictExpired(ids[31]);
        _enqueue(bob, second);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 2);
        assertEq(queue.queueEntries(0).length, 0);
        assertEq(queue.activeToken(makeAddr("stale5")), 0);
    }

    function test_oneFullBandLeavesOtherBandsOpen() public {
        for (uint256 i; i < 32; ++i) {
            address player = _wallet(string.concat("filler", vm.toString(i)));
            _enqueue(player, _mintFed(player, 0));
        }
        uint256 high = _mintFed(alice, 2);
        vm.prank(alice);
        nft.startTraining(high);
        _certifyTraining(nft, high, 250); // 1000 stamina at high food: band 2
        nft.settleTraining(high);
        _feed(alice, high, 2);
        _enqueue(alice, high);
        assertEq(queue.queueEntries(2).length, 1);
    }

    function test_leaveAndEvictRejectPetsThatAreNotWaiting() public {
        uint256 a = _mintFed(alice, 0);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.leaveQueue(a);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.evictExpired(a);
        vm.prank(alice);
        nft.startTraining(a);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.evictExpired(a);
        vm.prank(alice);
        nft.cancelTraining(a);

        uint256 b = _mintFed(bob, 0);
        _pair(alice, a, bob, b);
        vm.warp(block.timestamp + 40 days);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.evictExpired(a);
    }

    function test_leavingIsAllowedAfterStalenessAndReportsAsVoluntary() public {
        uint256 a = _mintFed(alice, 0);
        _enqueue(alice, a);
        vm.warp(block.timestamp + 30 days);
        vm.expectEmit(true, true, true, true, address(queue));
        emit MatchQueue.LeftQueue(a, alice, false);
        vm.prank(alice);
        queue.leaveQueue(a);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        queue.enqueue(a);
        assertEq(queue.activeToken(alice), 0, "the failed entry left no lock behind");
        assertEq(queue.queueEntries(0).length, 0);
    }

    function test_evictionReportsExpiryAndTheOwnerKeepsThePet() public {
        uint256 a = _mintFed(alice, 0);
        _enqueue(alice, a);
        vm.warp(block.timestamp + queue.QUEUE_TTL() + 1);
        vm.expectEmit(true, true, true, true, address(queue));
        emit MatchQueue.LeftQueue(a, alice, true);
        vm.prank(keeper);
        queue.evictExpired(a);
        assertEq(nft.ownerOf(a), alice);
        assertEq(nft.matchesThisWeek(a), 0);
    }

    // ---------------------------------------------------------------- snapshot timing

    function test_snapshotUsesWeightAtRoundLockNotAtEnqueue() public {
        HamsterHarness harness = _harness();
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        harness.setBodyForTest(a, 35);
        _enqueue(alice, a);
        _enqueue(bob, b);
        assertEq(uint256(nft.hamster(a).weight), uint256(WeightClass.Normal));
        vm.warp(block.timestamp + 1 days);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        assertEq(
            uint256(queue.roundRacers(round)[0].weight), uint256(WeightClass.Obese), "35 - 5 idle damage"
        );
    }

    function test_lockedRacersCannotImproveTheirSnapshotAndNewcomersCannotJoin() public {
        uint256 a = _mintFed(alice, 2);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        MatchQueue.Snapshot memory before = queue.roundRacers(round)[0];
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.feed{ value: 0.0003 ether }(a, 2);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(a);
        vm.expectRevert(MatchQueue.PlayerAlreadyActive.selector);
        queue.enqueue(a);
        vm.stopPrank();
        uint256 c = _mintFed(carol, 0);
        _enqueue(carol, c);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 2);
        assertEq(keccak256(abi.encode(queue.roundRacers(round)[0])), keccak256(abi.encode(before)));
    }

    function test_trainingPetCannotEnterAndTheFailedEntryLeavesNoTrace() public {
        uint256 a = _mintFed(alice, 2);
        vm.prank(alice);
        nft.startTraining(a);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        queue.enqueue(a);
        assertEq(queue.activeToken(alice), 0, "the failed entry left nothing behind");
        assertEq(queue.queueEntries(0).length, 0);
        (, uint256 index) = queue.position(a);
        assertEq(index, 0);
    }

    // ---------------------------------------------------------------- randomness window

    function testFuzz_exactlyOneResolutionPathExistsAtEveryBlock(uint16 offsetSeed) public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        uint256 requestedAt = vm.getBlockNumber();
        uint256 target = _target(round);
        assertEq(target, requestedAt + 2);

        uint256 current = requestedAt + bound(offsetSeed, 0, 600);
        vm.roll(current);
        if (current <= target) {
            vm.expectRevert(MatchQueue.RandomnessNotReady.selector);
            queue.fulfillRound(round);
            vm.expectRevert(MatchQueue.RandomnessStillLive.selector);
            queue.expireRound(round);
            assertEq(uint256(_status(round)), uint256(MatchQueue.RoundStatus.Pending));
        } else if (current <= target + 256) {
            vm.setBlockhash(target, keccak256(abi.encode(offsetSeed)));
            vm.expectRevert(MatchQueue.RandomnessStillLive.selector);
            queue.expireRound(round);
            queue.fulfillRound(round);
            assertEq(uint256(_status(round)), uint256(MatchQueue.RoundStatus.Fulfilled));
        } else {
            vm.expectRevert(MatchQueue.RandomnessExpired.selector);
            queue.fulfillRound(round);
            queue.expireRound(round);
            assertEq(uint256(_status(round)), uint256(MatchQueue.RoundStatus.Expired));
        }
    }

    function test_resultDependsOnlyOnTheTargetBlockHashAcrossTheWholeWindow() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        uint256 target = _target(round);
        bytes32 hash = keccak256("the only hash that counts");
        uint256 saved = vm.snapshotState();

        vm.roll(target + 1);
        vm.setBlockhash(target, hash);
        queue.fulfillRound(round);
        bytes32 early = keccak256(abi.encode(queue.matchInfo(1)));
        (,,,, bytes32 earlySeed,) = queue.roundInfo(round);

        assertTrue(vm.revertToState(saved));
        vm.roll(target + 256);
        vm.setBlockhash(target, hash);
        vm.setBlockhash(target + 1, keccak256("a later hash an attacker might prefer"));
        vm.setBlockhash(target - 1, keccak256("an earlier hash anyone already knew"));
        queue.fulfillRound(round);
        assertEq(keccak256(abi.encode(queue.matchInfo(1))), early);
        (,,,, bytes32 lateSeed,) = queue.roundInfo(round);
        assertEq(lateSeed, earlySeed);

        assertTrue(vm.revertToState(saved));
        vm.roll(target + 1);
        vm.setBlockhash(target, keccak256("a different target hash"));
        queue.fulfillRound(round);
        (,,,, bytes32 otherSeed,) = queue.roundInfo(round);
        assertTrue(otherSeed != earlySeed);
    }

    function test_seedIsBoundToChainContractAndRound() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        uint256 target = _target(round);
        bytes32 hash = keccak256("same hash");
        vm.roll(target + 1);
        vm.setBlockhash(target, hash);
        uint256 saved = vm.snapshotState();
        queue.fulfillRound(round);
        (,,,, bytes32 seed,) = queue.roundInfo(round);
        assertTrue(vm.revertToState(saved));
        vm.chainId(block.chainid + 1);
        queue.fulfillRound(round);
        (,,,, bytes32 otherChain,) = queue.roundInfo(round);
        assertTrue(otherChain != seed, "another chain with the same hash gets another seed");
    }

    /// @dev A two-player round follows DESIGN.md end to end. A failure here means code and spec have parted,
    ///      which a relational property could not see.
    function testFuzz_twoPlayerRoundMatchesThePinnedFormulas(bytes32 entropySeed) public {
        bytes32 entropy = keccak256(abi.encode(entropySeed));
        uint256 a = _mintFed(alice, 2);
        _feed(alice, a, 2); // 74, Fit
        uint256 b = _mintFed(bob, 1); // 56, Normal
        uint256 round = _pair(alice, a, bob, b);
        _fulfill(round, entropy);
        MatchQueue.Race memory race = queue.matchInfo(1);

        bytes32 seed = keccak256(abi.encode(entropy, block.chainid, address(queue), round));
        (,,,, bytes32 storedSeed,) = queue.roundInfo(round);
        assertEq(storedSeed, seed);

        _assertRaceFollowsTheFormulas(seed, race, a, b);

        queue.settleMatch(1);
        assertEq(nft.hamster(race.winner).stamina, 13);
        address winnerWallet = race.winner == a ? alice : bob;
        address loserWallet = race.winner == a ? bob : alice;
        assertEq(queue.points(winnerWallet), 10);
        assertEq(queue.points(loserWallet), 2);
    }

    /// @dev `fit` runs at weight bps 11500 and `normal` at 10000, both at stamina 10.
    function _assertRaceFollowsTheFormulas(
        bytes32 seed,
        MatchQueue.Race memory race,
        uint256 fit,
        uint256 normal
    ) private pure {
        bool swapped = uint256(keccak256(abi.encode(seed, "PAIR", uint256(1)))) % 2 == 0;
        uint256 first = swapped ? normal : fit;
        uint256 second = swapped ? fit : normal;
        assertEq(race.a.tokenId, first);
        assertEq(race.b.tokenId, second);

        uint256 noiseFirst = uint256(keccak256(abi.encode(seed, "NOISE", uint256(0), first))) % 2001;
        uint256 noiseSecond = uint256(keccak256(abi.encode(seed, "NOISE", uint256(0), second))) % 2001;
        uint256 scoreFirst = 10 * ((first == fit ? 11_500 : 10_000) - 1000 + noiseFirst) / 20_000;
        uint256 scoreSecond = 10 * ((second == fit ? 11_500 : 10_000) - 1000 + noiseSecond) / 20_000;
        assertEq(race.scoreA, scoreFirst);
        assertEq(race.scoreB, scoreSecond);

        bool firstWins = scoreFirst > scoreSecond
            || (scoreFirst == scoreSecond && uint256(keccak256(abi.encode(seed, "TIE", uint256(0)))) % 2 == 0);
        assertEq(race.winner, firstWins ? first : second);
    }

    /// @dev The hash inputs are fixed, so this cannot flake. It fails if the shuffle stops mixing, for example
    ///      if an off-by-one left some opponent unreachable.
    function test_shuffleReachesEveryOpponentAboutEvenly() public {
        for (uint256 i; i < 4; ++i) {
            address player = _wallet(string.concat("shuffle", vm.toString(i)));
            _enqueue(player, _mintFed(player, 0));
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        uint256 target = _target(round);
        vm.roll(target + 1);
        uint256 saved = vm.snapshotState();
        uint256[5] memory timesOpponent;
        uint256 trials = 150;
        for (uint256 t; t < trials; ++t) {
            assertTrue(vm.revertToState(saved));
            vm.setBlockhash(target, keccak256(abi.encode("shuffle trial", t)));
            queue.fulfillRound(round);
            for (uint256 m = 1; m <= 2; ++m) {
                MatchQueue.Race memory race = queue.matchInfo(m);
                if (race.a.tokenId == 1) ++timesOpponent[race.b.tokenId];
                if (race.b.tokenId == 1) ++timesOpponent[race.a.tokenId];
            }
        }
        assertEq(timesOpponent[2] + timesOpponent[3] + timesOpponent[4], trials);
        for (uint256 id = 2; id <= 4; ++id) {
            assertGt(timesOpponent[id], trials / 6, "each opponent should take about a third");
        }
    }

    // ---------------------------------------------------------------- weight in the race

    /// @return firstWins how many of `trials` future hashes let the first pet win.
    function _duel(uint256 staminaA, uint256 bodyA, uint256 staminaB, uint256 bodyB, uint256 trials)
        private
        returns (uint256 firstWins)
    {
        HamsterHarness harness = _harness();
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        harness.setStaminaForTest(a, staminaA);
        harness.setStaminaForTest(b, staminaB);
        harness.setBodyForTest(a, bodyA);
        harness.setBodyForTest(b, bodyB);
        _enqueue(alice, a);
        _enqueue(bob, b);
        uint256 band = queue.bandForStamina(staminaA);
        _waitQueueWindow();
        uint256 round = queue.requestRound(band);
        uint256 target = _target(round);
        vm.roll(target + 1);
        uint256 saved = vm.snapshotState();
        for (uint256 t; t < trials; ++t) {
            assertTrue(vm.revertToState(saved));
            vm.setBlockhash(target, keccak256(abi.encode("duel", t)));
            queue.fulfillRound(round);
            if (queue.matchInfo(1).winner == a) ++firstWins;
        }
    }

    function test_atEqualStaminaFitBeatsObeseUnderEveryHash() public {
        assertEq(_duel(1000, 80, 1000, 10, 100), 100, "Fit floor 525 is above Obese ceiling 475");
    }

    function test_fitUsuallyBeatsNormalButTheNoiseKeepsItAContest() public {
        uint256 wins = _duel(1000, 80, 1000, 50, 200);
        assertGt(wins, 180, "the Fit bonus must show");
        assertLt(wins, 200, "Normal's top noise overlaps Fit's bottom noise");
    }

    function test_normalUsuallyBeatsObeseButTheNoiseKeepsItAContest() public {
        uint256 wins = _duel(1000, 50, 1000, 10, 200);
        assertGt(wins, 180);
        assertLt(wins, 200);
    }

    function test_identicalPetsAreAFairCoinOverManyHashes() public {
        uint256 wins = _duel(1000, 50, 1000, 50, 200);
        assertGt(wins, 70);
        assertLt(wins, 130);
    }

    function test_identicalLowStaminaPetsStillSplitWinsWhenScoresOftenTie() public {
        uint256 wins = _duel(10, 50, 10, 50, 200);
        assertGt(wins, 70, "a tie must not always favour the same pet");
        assertLt(wins, 130);
    }

    function test_aBigStaminaLeadInsideABandOutweighsTheClassGap() public {
        // Obese at 49 scores at least 18. Fit at 25 scores at most 15.
        assertEq(_duel(49, 10, 25, 80, 50), 50);
    }

    function test_snapshotWeightDecidesEvenIfTheLivePetWentDownhillAfterLock() public {
        HamsterHarness harness = _harness();
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        harness.setStaminaForTest(a, 1000);
        harness.setStaminaForTest(b, 1000);
        harness.setBodyForTest(a, 100);
        harness.setBodyForTest(b, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _waitQueueWindow();
        uint256 round = queue.requestRound(2); // 1000 stamina sits in [500 * 2, 500 * 4)
        vm.warp(block.timestamp + 365 days);
        assertEq(uint256(nft.hamster(a).weight), uint256(WeightClass.Obese));
        uint256[] memory ids = _fulfill(round, keccak256("old snapshot"));
        assertEq(queue.matchInfo(ids[0]).winner, a);
    }

    // ---------------------------------------------------------------- settlement order and failure

    function test_racesInOneRoundSettleInAnyOrderAndOnlyFreeTheirOwnPair() public {
        address[4] memory wallets = [alice, bob, carol, _wallet("dave")];
        for (uint256 i; i < 4; ++i) {
            _enqueue(wallets[i], _mintFed(wallets[i], 0));
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        uint256[] memory ids = _fulfill(round, keccak256("settle order"));
        assertEq(ids.length, 2);
        MatchQueue.Race memory later = queue.matchInfo(ids[1]);
        MatchQueue.Race memory earlier = queue.matchInfo(ids[0]);

        queue.settleMatch(ids[1]);
        assertEq(queue.activeToken(later.a.player), 0);
        assertEq(queue.activeToken(later.b.player), 0);
        assertEq(queue.activeToken(earlier.a.player), earlier.a.tokenId);
        assertEq(queue.activeToken(earlier.b.player), earlier.b.tokenId);
        assertEq(uint256(nft.hamster(earlier.a.tokenId).activity), uint256(Activity.Matched));

        // A freed pet can already run again while its round-mates are unsettled.
        _enqueue(later.a.player, later.a.tokenId);
        vm.prank(earlier.a.player);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(earlier.a.tokenId);

        queue.settleMatch(ids[0]);
        assertEq(queue.totalPoints(), 24);
        vm.expectRevert(MatchQueue.MatchAlreadySettled.selector);
        queue.settleMatch(ids[1]);
        vm.expectRevert(MatchQueue.MatchAlreadySettled.selector);
        queue.settleMatch(ids[0]);
    }

    function test_settlingYearsLaterChangesNothingAboutTheRaceOrItsWeek() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 week = block.timestamp / 1 weeks;
        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("late settle"));
        MatchQueue.Race memory before = queue.matchInfo(ids[0]);
        vm.warp(block.timestamp + 730 days);
        vm.roll(block.number + 5_000_000);
        vm.prank(owner);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(20_000), 30_000, 40_000]);
        vm.prank(keeper);
        queue.settleMatch(ids[0]);
        MatchQueue.Race memory afterwards = queue.matchInfo(ids[0]);
        assertEq(afterwards.winner, before.winner);
        assertEq(afterwards.scoreA, before.scoreA);
        assertEq(afterwards.scoreB, before.scoreB);
        assertTrue(afterwards.settled);
        assertEq(queue.weeklyPoints(week, alice) + queue.weeklyPoints(week, bob), 12);
        assertEq(queue.weeklyPoints(block.timestamp / 1 weeks, alice), 0);
    }

    function test_firstRewardFailureRollsBackJustAsTheSecondDoes() public {
        HamsterHarness harness = _harness();
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("first reward fails"));
        MatchQueue.Race memory race = queue.matchInfo(ids[0]);
        harness.setStaminaForTest(race.a.tokenId, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        queue.settleMatch(ids[0]);
        assertFalse(queue.matchInfo(ids[0]).settled);
        assertEq(queue.totalPoints(), 0);
        assertEq(uint256(nft.hamster(race.a.tokenId).activity), uint256(Activity.Matched));
        assertEq(uint256(nft.hamster(race.b.tokenId).activity), uint256(Activity.Matched));
        assertEq(queue.activeToken(alice), a);
    }

    function test_settlementEmitsTheOutcomeAndPointsTotals() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 week = block.timestamp / 1 weeks;
        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("events"));
        MatchQueue.Race memory race = queue.matchInfo(ids[0]);
        bool aWon = race.winner == race.a.tokenId;
        vm.expectEmit(true, true, true, true, address(queue));
        emit PointsEvent.PointsAwarded(race.a.player, week, aWon ? 10 : 2, aWon ? 10 : 2);
        vm.expectEmit(true, true, true, true, address(queue));
        emit PointsEvent.PointsAwarded(race.b.player, week, aWon ? 2 : 10, aWon ? 2 : 10);
        vm.expectEmit(true, true, true, true, address(queue));
        emit MatchQueue.MatchSettled(ids[0], race.winner, race.scoreA, race.scoreB);
        queue.settleMatch(ids[0]);
    }

    // ---------------------------------------------------------------- expiry

    function test_expiredRoundHasNoRacesAndHungryRacersRecoverToo() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        vm.warp(block.timestamp + 30 days);
        vm.roll(_target(round) + 257);
        vm.prank(keeper);
        queue.expireRound(round);
        assertEq(queue.roundMatchIds(round).length, 0);
        (,,,, bytes32 seed,) = queue.roundInfo(round);
        assertEq(seed, bytes32(0));
        assertEq(queue.matchCount(), 0);
        vm.expectRevert(MatchQueue.InvalidMatch.selector);
        queue.settleMatch(1);
        assertTrue(nft.isHungry(a));
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        vm.prank(alice);
        nft.transferFrom(alice, carol, a);
    }

    function test_fiveExpiredRoundsExhaustTheWeekUntilItTurns() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        for (uint256 i; i < 5; ++i) {
            uint256 round = _pair(alice, a, bob, b);
            vm.roll(_target(round) + 257);
            queue.expireRound(round);
        }
        assertEq(queue.totalPoints(), 0);
        assertEq(nft.hamster(a).stamina, 10);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.WeeklyQuotaExceeded.selector);
        queue.enqueue(a);
        assertEq(queue.activeToken(alice), 0);
        vm.warp((block.timestamp / 1 weeks + 1) * 1 weeks);
        _feed(alice, a, 0);
        _feed(bob, b, 0);
        uint256 next = _pair(alice, a, bob, b);
        assertEq(uint256(_status(next)), uint256(MatchQueue.RoundStatus.Pending));
    }

    function test_expiringAFullRosterStaysBoundedAndFreesEveryone() public {
        address[] memory wallets = new address[](32);
        uint256[] memory ids = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            wallets[i] = _wallet(string.concat("full expire", vm.toString(i)));
            ids[i] = _mintFed(wallets[i], 0);
            _enqueue(wallets[i], ids[i]);
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        vm.roll(_target(round) + 257);
        uint256 before = gasleft();
        queue.expireRound(round);
        assertLt(before - gasleft(), 12_000_000);
        for (uint256 i; i < 32; ++i) {
            assertEq(queue.activeToken(wallets[i]), 0);
            assertEq(uint256(nft.hamster(ids[i]).activity), uint256(Activity.Idle));
        }
    }

    // ---------------------------------------------------------------- wait window and bye

    function test_entriesBecomeLockableExactlyTenBlocksAfterJoining() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 joined = vm.getBlockNumber();
        _enqueue(alice, a);
        _enqueue(bob, b);
        assertEq(queue.QUEUE_WAIT_BLOCKS(), 10);
        vm.roll(joined + 9);
        assertEq(queue.eligibleCount(0), 0);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        assertEq(
            uint256(nft.hamster(a).activity), uint256(Activity.Queued), "the failed request changed nothing"
        );
        vm.roll(joined + 10);
        assertEq(queue.eligibleCount(0), 2);
        assertEq(queue.roundRacers(queue.requestRound(0)).length, 2);
    }

    function test_nobodyCanJoinAndLockAgainstALoneWaiterInOneTransaction() public {
        uint256 lone = _mintFed(alice, 0);
        _enqueue(alice, lone);
        _waitQueueWindow();
        uint256 sniper = _mintFed(bob, 0);
        JoinAndLock attacker = new JoinAndLock(queue);
        vm.prank(bob);
        nft.transferFrom(bob, address(attacker), sniper);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        attacker.joinAndLock(sniper, 0);
        assertEq(queue.roundCount(), 0);
        assertEq(uint256(nft.hamster(lone).activity), uint256(Activity.Queued));
    }

    function test_rejoiningRestartsTheWait() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _waitQueueWindow();
        vm.prank(bob);
        queue.leaveQueue(b);
        _enqueue(bob, b);
        assertEq(queue.eligibleCount(0), 1, "the rejoined entry carries its new join block");
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
    }

    function test_oddRoundGivesTheShuffleChosenByeItsAttemptBack() public {
        address[3] memory wallets = [alice, bob, carol];
        uint256[3] memory pets;
        for (uint256 i; i < 3; ++i) {
            pets[i] = _mintFed(wallets[i], 0);
            _enqueue(wallets[i], pets[i]);
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        for (uint256 i; i < 3; ++i) {
            assertEq(nft.matchesThisWeek(pets[i]), 1, "everyone pays at lock");
        }
        assertEq(queue.roundBye(round), 0, "no bye before the entropy");
        uint256[] memory ids = _fulfill(round, keccak256("odd round"));
        assertEq(ids.length, 1);
        uint256 bye = queue.roundBye(round);
        MatchQueue.Race memory race = queue.matchInfo(ids[0]);
        assertTrue(bye != 0 && bye != race.a.tokenId && bye != race.b.tokenId, "the bye races nobody");
        address byeWallet = nft.ownerOf(bye);
        assertEq(uint256(nft.hamster(bye).activity), uint256(Activity.Idle));
        assertEq(nft.matchesThisWeek(bye), 0, "the bye's attempt is refunded");
        assertEq(queue.activeToken(byeWallet), 0);
        assertEq(nft.hamster(bye).stamina, 10, "a bye earns no stamina");
        queue.settleMatch(ids[0]);
        assertEq(queue.points(byeWallet), 0, "a bye earns no points");
        assertEq(queue.totalPoints(), 12);
        _enqueue(byeWallet, bye);
        assertEq(queue.activeToken(byeWallet), bye, "the bye may queue again at once");
    }

    /// @dev Over many hashes each of the three racers sits out sometimes: the caller cannot pick the bye.
    function test_byeIsSpreadAcrossTheRoster() public {
        address[3] memory wallets = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            _enqueue(wallets[i], _mintFed(wallets[i], 0));
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        uint256 target = _target(round);
        vm.roll(target + 1);
        uint256 saved = vm.snapshotState();
        uint256[4] memory times;
        uint256 trials = 120;
        for (uint256 t; t < trials; ++t) {
            assertTrue(vm.revertToState(saved));
            vm.setBlockhash(target, keccak256(abi.encode("bye trial", t)));
            queue.fulfillRound(round);
            ++times[queue.roundBye(round)];
        }
        for (uint256 id = 1; id <= 3; ++id) {
            assertGt(times[id], trials / 6, "each racer is the bye about a third of the time");
        }
    }

    function test_expiredOddRoundRefundsNobody() public {
        address[3] memory wallets = [alice, bob, carol];
        uint256[3] memory pets;
        for (uint256 i; i < 3; ++i) {
            pets[i] = _mintFed(wallets[i], 0);
            _enqueue(wallets[i], pets[i]);
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        vm.roll(_target(round) + 257);
        queue.expireRound(round);
        assertEq(queue.roundBye(round), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(nft.matchesThisWeek(pets[i]), 1, "expiry refunds no attempt, bye or not");
            assertEq(uint256(nft.hamster(pets[i]).activity), uint256(Activity.Idle));
        }
        vm.expectRevert(MatchQueue.InvalidRound.selector);
        queue.roundBye(round + 1);
    }

    function test_onlyTheBoundQueueCanReleaseABye() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _pair(alice, a, bob, b);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        nft.releaseBye(a);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Matched));
        assertEq(nft.matchesThisWeek(a), 1);
    }

    // ---------------------------------------------------------------- callers and views

    function test_anyCallerBuildsTheSameRoster() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _waitQueueWindow();
        uint256 saved = vm.snapshotState();
        vm.prank(keeper);
        uint256 byKeeper = queue.requestRound(0);
        bytes32 keeperRoster = keccak256(abi.encode(queue.roundRacers(byKeeper)));
        assertTrue(vm.revertToState(saved));
        vm.prank(alice);
        uint256 byPlayer = queue.requestRound(0);
        assertEq(keccak256(abi.encode(queue.roundRacers(byPlayer))), keeperRoster);
    }

    function test_emptyAndUnknownViewsBehave() public {
        assertEq(queue.queueEntries(type(uint256).max).length, 0);
        vm.expectRevert(MatchQueue.InvalidRound.selector);
        queue.roundMatchIds(0);
        vm.expectRevert(MatchQueue.InvalidRound.selector);
        queue.roundInfo(1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        assertEq(queue.roundCount(), 0);
    }

    function test_constantsArePinnedToTheDocumentedValues() public view {
        assertEq(nft.MAX_SUPPLY(), 9999);
        assertEq(nft.START_STAMINA(), 10);
        assertEq(nft.FEED_SECONDS(), 259_200);
        assertEq(nft.TRAIN_ROUNDS(), 6);
        assertEq(nft.ROUND_SECONDS(), 600);
        assertEq(nft.WEEKLY_MATCH_LIMIT(), 5);
        assertEq(nft.MAX_TRAIN_BPS(), 50_000);
        assertEq(queue.BAND_WIDTH(), 500);
        assertEq(nft.STAMINA_PER_WORK(), 2);
        assertEq(queue.MAX_QUEUE_SIZE(), 32);
        assertEq(queue.QUEUE_TTL(), 86_400);
        assertEq(queue.RANDOM_DELAY(), 2);
        assertEq(queue.RANDOM_WINDOW(), 256);
        assertEq(queue.WIN_POINTS(), 10);
        assertEq(queue.LOSS_POINTS(), 2);
    }
}

/// @dev PointsAwarded is declared on an abstract base, so this names it for vm.expectEmit.
library PointsEvent {
    event PointsAwarded(address indexed player, uint256 indexed week, uint256 amount, uint256 total);
}

/// @dev Owns a pet and tries to enter and lock a round in one transaction.
contract JoinAndLock {
    MatchQueue public immutable queue;

    constructor(MatchQueue queue_) {
        queue = queue_;
    }

    function joinAndLock(uint256 id, uint256 band) external returns (uint256) {
        queue.enqueue(id);
        return queue.requestRound(band);
    }
}
