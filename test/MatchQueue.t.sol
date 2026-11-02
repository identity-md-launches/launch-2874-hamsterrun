// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest, HamsterHarness } from "./helpers/GameTest.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, WeightClass } from "../src/GameMath.sol";

/// @dev A contract wallet that tries to enter a band and lock the waiting pet in one transaction.
contract QueueSniper {
    HamsterRunNFT internal immutable nft;
    MatchQueue internal immutable queue;
    uint256 public id;

    constructor(HamsterRunNFT nft_, MatchQueue queue_) payable {
        nft = nft_;
        queue = queue_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function prepare() external {
        id = nft.mint();
        nft.feed{ value: 0.0003 ether }(id, 2);
    }

    function enter() external {
        queue.enqueue(id);
    }

    function enterAndLock(uint256 band) external returns (uint256) {
        queue.enqueue(id);
        return queue.requestRound(band);
    }
}

contract MatchQueueTest is GameTest {
    function test_endToEndMintFeedTrainQueueRandomMatchSettle() public {
        uint256 a = _mintFed(alice, 2);
        uint256 b = _mintFed(bob, 2);
        vm.prank(alice);
        nft.startTraining(a);
        vm.prank(bob);
        nft.startTraining(b);
        _certifyTraining(nft, a, 5);
        nft.settleTraining(a);
        nft.settleTraining(b);
        assertEq(nft.hamster(a).stamina, 30);
        assertEq(queue.bandOf(a), 1);
        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("smoke path future block"));
        assertEq(ids.length, 1);
        vm.prank(keeper);
        queue.settleMatch(ids[0]);
        MatchQueue.Race memory race = queue.matchInfo(ids[0]);
        assertTrue(race.settled);
        assertEq(nft.hamster(a).stamina + nft.hamster(b).stamina, 64);
        assertEq(queue.points(alice) + queue.points(bob), 12);
        assertEq(queue.totalPoints(), 12);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        assertEq(uint256(nft.hamster(b).activity), uint256(Activity.Idle));
        assertEq(queue.activeToken(alice), 0);
        assertEq(queue.activeToken(bob), 0);
        assertEq(nft.matchesThisWeek(a), 1);
        vm.expectRevert(MatchQueue.MatchAlreadySettled.selector);
        queue.settleMatch(ids[0]);
        vm.expectRevert(MatchQueue.RoundNotPending.selector);
        queue.fulfillRound(round);
        vm.expectRevert(MatchQueue.RoundNotPending.selector);
        queue.expireRound(round);
    }

    function test_cannotEnqueueOthersDuplicateOrTwoPetsForOneWallet() public {
        uint256 a = _mintFed(alice, 0);
        vm.prank(owner);
        uint256 a2 = nft.ownerMint(alice);
        _feed(alice, a2, 0);
        vm.prank(bob);
        vm.expectRevert(MatchQueue.NotTokenOwner.selector);
        queue.enqueue(a);
        _enqueue(alice, a);
        vm.startPrank(alice);
        vm.expectRevert(MatchQueue.PlayerAlreadyActive.selector);
        queue.enqueue(a);
        vm.expectRevert(MatchQueue.PlayerAlreadyActive.selector);
        queue.enqueue(a2);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(MatchQueue.NotTokenOwner.selector);
        queue.leaveQueue(a);
        vm.prank(alice);
        queue.leaveQueue(a);
        _enqueue(alice, a2);
    }

    function test_queueAndMatchLocksPreventTransfersFeedingTrainingAndCancellation() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        vm.prank(alice);
        nft.setApprovalForAll(carol, true);
        _enqueue(alice, a);
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.feed{ value: 0.0001 ether }(a, 0);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(a);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.transferFrom(alice, bob, a);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.safeTransferFrom(alice, carol, a);
        _enqueue(bob, b);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        vm.startPrank(alice);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.leaveQueue(a);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.feed{ value: 0.0001 ether }(a, 0);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.transferFrom(alice, bob, a);
        vm.stopPrank();
        _fulfill(round, keccak256("lock test"));
        vm.prank(alice);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.leaveQueue(a);
        queue.settleMatch(1);
        vm.prank(carol);
        nft.safeTransferFrom(alice, carol, a);
    }

    function test_distinctStaminaBandsCannotPair() public {
        uint256 a = _mintFed(alice, 2);
        uint256 b = _mintFed(bob, 0);
        _train(alice, a);
        assertEq(queue.bandOf(a), 1);
        assertEq(queue.bandOf(b), 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _waitQueueWindow();
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(type(uint256).max);
    }

    function test_oddRosterLocksEveryoneAndEntropyChoosesTheBye() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _enqueue(carol, c);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 3);
        assertEq(queue.queueEntries(0).length, 0);
        assertEq(nft.matchesThisWeek(c), 1);
        assertEq(uint256(nft.hamster(c).activity), uint256(Activity.Matched));
        assertEq(queue.roundBye(round), 0);
        (, uint256 target,,,,) = queue.roundInfo(round);
        vm.roll(target + 1);
        uint256 saved = vm.snapshotState();
        bool byeVaries;
        uint256 firstBye;
        for (uint256 attempt; attempt < 12; ++attempt) {
            assertTrue(vm.revertToState(saved));
            vm.setBlockhash(target, keccak256(abi.encode("odd roster", attempt)));
            vm.prank(keeper);
            queue.fulfillRound(round);
            uint256 bye = queue.roundBye(round);
            assertTrue(bye == a || bye == b || bye == c);
            if (attempt == 0) firstBye = bye;
            else if (bye != firstBye) byeVaries = true;
            uint256[] memory ids = queue.roundMatchIds(round);
            assertEq(ids.length, 1);
            MatchQueue.Race memory race = queue.matchInfo(ids[0]);
            assertTrue(race.a.tokenId != bye && race.b.tokenId != bye);
            // The bye is unlocked at once, keeps its attempt and earns nothing.
            assertEq(uint256(nft.hamster(bye).activity), uint256(Activity.Idle));
            assertEq(nft.matchesThisWeek(bye), 0);
            assertEq(queue.activeToken(nft.ownerOf(bye)), 0);
            assertEq(nft.hamster(bye).stamina, 10);
            assertEq(uint256(nft.hamster(race.a.tokenId).activity), uint256(Activity.Matched));
            queue.settleMatch(ids[0]);
            assertEq(queue.totalPoints(), 12);
            assertEq(queue.points(nft.ownerOf(bye)), 0);
            assertEq(nft.matchesThisWeek(race.a.tokenId), 1);
            // The bye can enter the next round immediately.
            _enqueue(nft.ownerOf(bye), bye);
        }
        assertTrue(byeVaries, "entropy must choose the bye");
    }

    function test_expiredOddRoundReleasesEveryoneAndNobodyIsRefunded() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _enqueue(carol, c);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        (, uint256 target,,,,) = queue.roundInfo(round);
        vm.roll(target + 257);
        queue.expireRound(round);
        assertEq(queue.roundBye(round), 0);
        assertEq(nft.matchesThisWeek(a) + nft.matchesThisWeek(b) + nft.matchesThisWeek(c), 3);
        assertEq(uint256(nft.hamster(c).activity), uint256(Activity.Idle));
        assertEq(queue.activeToken(carol), 0);
    }

    function test_cannotEnqueueAndLockInOneTransaction() public {
        uint256 victim = _mintFed(alice, 0);
        _enqueue(alice, victim);
        _waitQueueWindow();
        QueueSniper sniper = new QueueSniper{ value: 1 ether }(nft, queue);
        sniper.prepare();
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        sniper.enterAndLock(0);
        assertEq(queue.queueEntries(0).length, 1);
        assertEq(uint256(nft.hamster(victim).activity), uint256(Activity.Queued));
        // Entered separately, the sniper's pet waits like anyone else and is not lockable before its window ends.
        sniper.enter();
        assertEq(queue.eligibleCount(0), 1);
        assertEq(queue.queueEntries(0).length, 2);
        vm.roll(vm.getBlockNumber() + queue.QUEUE_WAIT_BLOCKS() - 1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        assertEq(nft.matchesThisWeek(victim), 0);
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(queue.eligibleCount(0), 2);
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 2);
    }

    function test_requestLocksWholeEligibleRosterSoLateEntrantCannotFlushTheQueue() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _enqueue(carol, c);
        _waitQueueWindow();
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
        uint256 d = _mintFed(attacker, 0);
        _enqueue(attacker, d);
        vm.prank(attacker);
        uint256 round = queue.requestRound(0);
        // All three eligible pets are committed together; the newcomer waits and cannot pick a leftover.
        assertEq(queue.roundRacers(round).length, 3);
        assertEq(queue.queueEntries(0).length, 1);
        assertEq(queue.queueEntries(0)[0].tokenId, d);
        assertEq(uint256(nft.hamster(d).activity), uint256(Activity.Queued));
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        _waitQueueWindow();
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        assertEq(nft.matchesThisWeek(d), 0);
    }

    function test_eligibilityIsPerEntryAndSurvivesSwapRemoval() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        _enqueue(alice, a);
        _waitQueueWindow();
        _enqueue(bob, b);
        vm.roll(vm.getBlockNumber() + 3);
        _enqueue(carol, c);
        vm.prank(alice);
        queue.leaveQueue(a); // swap-and-pop moves c into a's slot; c keeps its own join block
        assertEq(queue.eligibleCount(0), 0);
        vm.roll(vm.getBlockNumber() + queue.QUEUE_WAIT_BLOCKS() - 3);
        assertEq(queue.eligibleCount(0), 1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        vm.roll(vm.getBlockNumber() + 3);
        assertEq(queue.eligibleCount(0), 2);
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 2);
    }

    function test_leaveMiddleEntryRepairsPositionAndDoesNotConsumeQuota() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        _enqueue(carol, c);
        vm.prank(bob);
        queue.leaveQueue(b);
        (, uint256 index) = queue.position(c);
        assertEq(index, 2);
        vm.prank(carol);
        queue.leaveQueue(c);
        assertEq(queue.queueEntries(0).length, 1);
        assertEq(nft.matchesThisWeek(b), 0);
        assertEq(queue.activeToken(bob), 0);
        assertEq(queue.activeToken(carol), 0);
    }

    function test_queueTTLAndHungryExpiryCanBeEvictedPermissionlessly() public {
        uint256 a = _mintFed(alice, 0);
        _enqueue(alice, a);
        uint256 joinedAt = block.timestamp;
        vm.expectRevert(MatchQueue.EntryStillLive.selector);
        queue.evictExpired(a);
        vm.warp(joinedAt + queue.QUEUE_TTL());
        vm.expectRevert(MatchQueue.EntryStillLive.selector);
        queue.evictExpired(a);
        vm.warp(block.timestamp + 1);
        vm.prank(keeper);
        queue.evictExpired(a);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        assertEq(queue.activeToken(alice), 0);
        assertEq(nft.matchesThisWeek(a), 0);
        vm.warp(nft.hamster(a).fedUntil);
        _enqueue(alice, a); // exact fedUntil is still fed
        vm.warp(block.timestamp + 1);
        queue.evictExpired(a);
        assertTrue(nft.isHungry(a));
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.evictExpired(a);
    }

    function test_requestPrunesStaleEntriesWithoutBlockingHealthyPair() public {
        uint256 a = _mintFed(alice, 0);
        _enqueue(alice, a);
        vm.warp(block.timestamp + queue.QUEUE_TTL() + 1);
        uint256 b = _mintFed(bob, 0);
        uint256 c = _mintFed(carol, 0);
        _enqueue(bob, b);
        _enqueue(carol, c);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 2);
        assertEq(queue.activeToken(alice), 0);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        assertEq(nft.matchesThisWeek(a), 0);
    }

    function test_randomnessCannotUseCurrentFutureOrZeroHash() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        (, uint256 target,,,,) = queue.roundInfo(round);
        assertEq(target, block.number + 2);
        vm.expectRevert(MatchQueue.RandomnessNotReady.selector);
        queue.fulfillRound(round);
        vm.roll(target);
        vm.expectRevert(MatchQueue.RandomnessNotReady.selector);
        queue.fulfillRound(round);
        vm.roll(target + 1);
        vm.setBlockhash(target, bytes32(0));
        vm.expectRevert(MatchQueue.RandomnessUnavailable.selector);
        queue.fulfillRound(round);
        vm.setBlockhash(target, keccak256("available hash"));
        queue.fulfillRound(round);
    }

    function test_lastRandomnessBlockIsUsableAndCannotExpireEarly() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        (, uint256 target,,,,) = queue.roundInfo(round);
        vm.roll(target + 256);
        vm.setBlockhash(target, keccak256("last hash block"));
        vm.expectRevert(MatchQueue.RandomnessStillLive.selector);
        queue.expireRound(round);
        queue.fulfillRound(round);
        queue.settleMatch(1);
    }

    function test_expiredRandomnessReleasesBothPetsWithoutRewardAndRetainsQuota() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        (, uint256 target,,,,) = queue.roundInfo(round);
        vm.roll(target + 257);
        vm.expectRevert(MatchQueue.RandomnessExpired.selector);
        queue.fulfillRound(round);
        vm.prank(keeper);
        queue.expireRound(round);
        (,,, MatchQueue.RoundStatus status,,) = queue.roundInfo(round);
        assertEq(uint256(status), uint256(MatchQueue.RoundStatus.Expired));
        assertEq(nft.hamster(a).stamina, 10);
        assertEq(nft.hamster(b).stamina, 10);
        assertEq(queue.totalPoints(), 0);
        assertEq(queue.activeToken(alice), 0);
        assertEq(queue.activeToken(bob), 0);
        assertEq(nft.matchesThisWeek(a), 1);
        assertEq(nft.matchesThisWeek(b), 1);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        vm.expectRevert(MatchQueue.RoundNotPending.selector);
        queue.expireRound(round);
        vm.expectRevert(MatchQueue.RoundNotPending.selector);
        queue.fulfillRound(round);
        _pair(alice, a, bob, b);
    }

    function test_weightChangesActualRaceOutcomeWithEqualStamina() public {
        uint256 fit = _mintFed(alice, 2);
        _feed(alice, fit, 2); // 74: Fit
        uint256 obese = _mintFed(bob, 0);
        for (uint256 i; i < 3; ++i) {
            _feed(bob, obese, 0); // 34: Obese
        }
        uint256 round = _pair(alice, fit, bob, obese);
        MatchQueue.Snapshot[] memory snapshots = queue.roundRacers(round);
        assertEq(uint256(snapshots[0].weight), uint256(WeightClass.Fit));
        assertEq(uint256(snapshots[1].weight), uint256(WeightClass.Obese));
        vm.warp(block.timestamp + 30 days); // live bodies degrade; locked race must not change
        assertEq(uint256(nft.hamster(fit).weight), uint256(WeightClass.Obese));
        uint256[] memory ids = _fulfill(round, keccak256("weight affects race"));
        MatchQueue.Race memory race = queue.matchInfo(ids[0]);
        assertEq(race.winner, fit);
        assertTrue(race.scoreA != race.scoreB);
        queue.settleMatch(ids[0]);
        assertEq(queue.points(alice), 10);
        assertEq(queue.points(bob), 2);
        assertEq(nft.hamster(fit).stamina, 13);
        assertEq(nft.hamster(obese).stamina, 11);
        assertTrue(nft.isHungry(fit));
    }

    function test_weeklyQuotaIsPerNFTAndSettlementCreditsLockWeek() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 week = block.timestamp / 1 weeks;
        for (uint256 i; i < 5; ++i) {
            uint256 round = _pair(alice, a, bob, b);
            uint256[] memory ids = _fulfill(round, keccak256(abi.encode("quota", i)));
            queue.settleMatch(ids[0]);
        }
        assertEq(nft.matchesThisWeek(a), 5);
        assertEq(nft.matchesThisWeek(b), 5);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.WeeklyQuotaExceeded.selector);
        queue.enqueue(a);
        vm.prank(alice);
        nft.transferFrom(alice, carol, a);
        vm.prank(carol);
        vm.expectRevert(HamsterRunNFT.WeeklyQuotaExceeded.selector);
        queue.enqueue(a);
        assertEq(queue.weeklyPoints(week, alice) + queue.weeklyPoints(week, bob), 60);
        assertEq(queue.points(carol), 0);

        vm.warp((week + 1) * 1 weeks);
        _feed(carol, a, 2);
        _feed(bob, b, 2);
        // Different rewards may have moved one pet into the next band; train both into band 1.
        _train(carol, a);
        _train(bob, b);
        assertEq(nft.matchesThisWeek(a), 0);
        uint256 next = _pair(carol, a, bob, b);
        uint256[] memory nextIds = _fulfill(next, keccak256("next week"));
        vm.warp((week + 2) * 1 weeks);
        queue.settleMatch(nextIds[0]);
        assertEq(queue.weeklyPoints(week + 1, carol) + queue.weeklyPoints(week + 1, bob), 12);
        assertEq(queue.weeklyPoints(week + 2, carol), 0);
        assertEq(queue.totalPoints(), 72);
    }

    function test_queueQuotaUsesLockWeekAcrossWeekBoundary() public {
        uint256 week = block.timestamp / 1 weeks;
        vm.warp((week + 1) * 1 weeks - 1);
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        vm.warp(block.timestamp + 1);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        (,, uint256 lockWeek,,,) = queue.roundInfo(round);
        (uint256 quotaWeek, uint256 used) = nft.matchQuota(a);
        assertEq(lockWeek, week + 1);
        assertEq(quotaWeek, lockWeek);
        assertEq(used, 1);
    }

    function test_invalidIdsCannotCreateStateOrRewards() public {
        vm.expectRevert(MatchQueue.InvalidRound.selector);
        queue.fulfillRound(0);
        vm.expectRevert(MatchQueue.InvalidRound.selector);
        queue.expireRound(1);
        vm.expectRevert(MatchQueue.InvalidRound.selector);
        queue.roundRacers(1);
        vm.expectRevert(MatchQueue.InvalidMatch.selector);
        queue.settleMatch(0);
        vm.expectRevert(MatchQueue.InvalidMatch.selector);
        queue.matchInfo(1);
        assertEq(queue.totalPoints(), 0);
        assertEq(queue.roundCount(), 0);
    }

    function test_staleOnlyRequestCanBeRecoveredByExplicitEviction() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        _enqueue(bob, b);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        // A revert also rolls back pruning; explicit bounded eviction remains available.
        assertEq(queue.queueEntries(0).length, 2);
        queue.evictExpired(a);
        queue.evictExpired(b);
        assertEq(queue.queueEntries(0).length, 0);
        assertEq(nft.matchesThisWeek(a), 0);
    }

    function test_failedRewardRollsBackBothStaminaAndPointsAtomically() public {
        HamsterHarness harness = new HamsterHarness(owner, address(core));
        nft = harness;
        queue = new MatchQueue(address(nft));
        vm.startPrank(owner);
        nft.setMintOpen(true);
        nft.setMatchQueue(address(queue));
        vm.stopPrank();
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        _fulfill(round, keccak256("atomic reward failure"));
        MatchQueue.Race memory race = queue.matchInfo(1);
        // Artificially reach an impossible practical state, forcing the second reward to overflow.
        harness.setStaminaForTest(race.b.tokenId, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        queue.settleMatch(1);
        assertFalse(queue.matchInfo(1).settled);
        assertEq(nft.hamster(race.a.tokenId).stamina, 10);
        assertEq(queue.totalPoints(), 0);
        assertEq(queue.points(alice), 0);
        assertEq(queue.points(bob), 0);
        assertEq(queue.activeToken(alice), a);
        assertEq(queue.activeToken(bob), b);
        harness.setStaminaForTest(race.b.tokenId, 10);
        queue.settleMatch(1);
        assertEq(queue.totalPoints(), 12);
    }

    function test_multipleRoundsInSameBandDoNotInterfere() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 first = _pair(alice, a, bob, b);
        uint256 c = _mintFed(carol, 0);
        address dave = makeAddr("dave");
        vm.deal(dave, 1 ether);
        uint256 d = _mintFed(dave, 0);
        uint256 second = _pair(carol, c, dave, d);
        _fulfill(second, keccak256("shared future block"));
        queue.fulfillRound(first);
        (,,,, bytes32 seedA,) = queue.roundInfo(first);
        (,,,, bytes32 seedB,) = queue.roundInfo(second);
        assertTrue(seedA != seedB);
        uint256[] memory firstIds = queue.roundMatchIds(first);
        uint256[] memory secondIds = queue.roundMatchIds(second);
        queue.settleMatch(firstIds[0]);
        assertEq(queue.activeToken(carol), c);
        assertEq(queue.activeToken(dave), d);
        queue.settleMatch(secondIds[0]);
        assertEq(queue.totalPoints(), 24);
    }

    function test_fullQueueBoundAndMaximumRoundGas() public {
        for (uint256 i; i < 32; ++i) {
            address player = makeAddr(string.concat("player", vm.toString(i)));
            vm.deal(player, 1 ether);
            uint256 id = _mintFed(player, 0);
            _enqueue(player, id);
        }
        uint256 extra = _mintFed(alice, 0);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.QueueFull.selector);
        queue.enqueue(extra);
        _waitQueueWindow();
        uint256 before = gasleft();
        uint256 round = queue.requestRound(0);
        uint256 lockGas = before - gasleft();
        assertLt(lockGas, 12_000_000);
        _readyRound(round, keccak256("full roster"));
        before = gasleft();
        queue.fulfillRound(round);
        uint256 fulfillGas = before - gasleft();
        assertLt(fulfillGas, 12_000_000);
        emit log_named_uint("32-player round lock gas", lockGas);
        emit log_named_uint("32-player round fulfill gas", fulfillGas);
        uint256[] memory ids = queue.roundMatchIds(round);
        assertEq(ids.length, 16);
        for (uint256 i; i < ids.length; ++i) {
            queue.settleMatch(ids[i]);
        }
        assertEq(queue.totalPoints(), 16 * 12);
        assertEq(queue.queueEntries(0).length, 0);
        _enqueue(alice, extra);
    }
}
