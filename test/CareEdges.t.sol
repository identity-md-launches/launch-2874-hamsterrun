// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest, HamsterHarness } from "./helpers/GameTest.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, GameMath, WeightClass } from "../src/GameMath.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @notice Boundaries and failure paths of feeding, training and body weight. Expected values are the
///         literals that DESIGN.md's formulas give by hand, not values recomputed through GameMath.
contract CareEdgesTest is GameTest {
    function _harness() private returns (HamsterHarness harness) {
        harness = new HamsterHarness(owner, address(core));
        nft = harness;
        queue = new MatchQueue(address(nft));
        vm.startPrank(owner);
        nft.setMintOpen(true);
        nft.setMatchQueue(address(queue));
        vm.stopPrank();
    }

    function _body(uint256 id) private view returns (uint256) {
        return nft.hamster(id).bodyScore;
    }

    // ---------------------------------------------------------------- hunger and neglect schedule

    /// @dev DESIGN: a never-fed newborn's hunger clock starts at birth + 72h, though it is gated as hungry.
    function test_newbornNeglectFollowsThePinnedSchedule() public {
        uint256 id = _mint(alice);
        uint256 born = block.timestamp;
        assertEq(_body(id), 50);
        assertTrue(nft.isHungry(id), "a newborn is hungry for every gate");
        vm.warp(born + 1);
        assertEq(_body(id), 50, "no hunger damage inside the newborn's first window");
        vm.warp(born + 1 days - 1);
        assertEq(_body(id), 50);
        vm.warp(born + 1 days);
        assertEq(_body(id), 45, "first complete idle day");
        vm.warp(born + 3 days);
        assertEq(_body(id), 35, "three idle days, still no hunger at birth + 72h exactly");
        vm.warp(born + 3 days + 1);
        assertEq(_body(id), 30, "first begun hungry day one second after the newborn window");
        vm.warp(born + 4 days);
        assertEq(_body(id), 25, "fourth complete idle day");
        vm.warp(born + 4 days + 1);
        assertEq(_body(id), 20, "second begun hungry day");
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Obese));
    }

    /// @dev The newborn window is what makes mint-then-feed-later equal mint-and-feed-now, up to idle days.
    function testFuzz_feedingAnywhereInTheNewbornWindowCostsOnlyIdleDays(uint32 delaySeed, uint8 tierSeed)
        public
    {
        uint8 tier = uint8(bound(tierSeed, 0, 2));
        uint256 delay = bound(delaySeed, 0, 72 hours);
        uint256 id = _mint(alice);
        vm.warp(vm.getBlockTimestamp() + delay);
        _feed(alice, id, tier);
        uint256 food = tier == 0 ? 46 : tier == 1 ? 56 : 62;
        assertEq(_body(id), food - 5 * (delay / 1 days));
    }

    function test_feedingOneSecondAfterTheNewbornWindowPaysOneHungerDay() public {
        uint256 id = _mint(alice);
        vm.warp(vm.getBlockTimestamp() + 72 hours + 1);
        _feed(alice, id, 2);
        assertEq(_body(id), 50 - 15 - 5 + 12);
    }

    function test_feedingStopsHungerDamageButNeverRefundsIdleDamage() public {
        uint256 id = _mintFed(alice, 1); // 56
        uint256 start = block.timestamp;
        uint256 fedAt = start + 5 days + 1;
        vm.warp(fedAt);
        // idle: 5 complete days. hunger: 2 days + 1 second past expiry is the third begun day.
        assertEq(_body(id), 56 - 25 - 15);
        _feed(alice, id, 1);
        assertEq(_body(id), 22, "16 + 6 food, already applied neglect is not charged twice");
        assertEq(nft.hamster(id).fedUntil, fedAt + 72 hours);
        vm.warp(fedAt + 1 days);
        assertEq(_body(id), 17, "one more idle day and no hunger while fed");
        vm.warp(fedAt + 3 days);
        assertEq(_body(id), 7, "exact expiry is still not hungry");
        vm.warp(fedAt + 3 days + 1);
        assertEq(_body(id), 2, "hunger restarts counting from the new expiry");
    }

    function test_longNeglectSaturatesAtZeroAndFoodRecoversFromThere() public {
        uint256 id = _mintFed(alice, 2);
        vm.warp(block.timestamp + 3650 days);
        assertEq(_body(id), 0);
        _feed(alice, id, 0);
        assertEq(_body(id), 0, "low food cannot go below zero");
        _feed(alice, id, 2);
        assertEq(_body(id), 12);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Obese));
    }

    function test_repeatedFoodSaturatesBothEndsOfTheBodyRange() public {
        uint256 up = _mint(alice);
        for (uint256 i; i < 5; ++i) {
            _feed(alice, up, 2);
        }
        assertEq(_body(up), 100, "50 + 5 * 12 clamps");
        _feed(alice, up, 2);
        assertEq(_body(up), 100, "feeding at the ceiling keeps it");

        uint256 down = _mint(bob);
        for (uint256 i; i < 13; ++i) {
            _feed(bob, down, 0);
        }
        assertEq(_body(down), 0, "50 - 13 * 4 clamps");
    }

    function testFuzz_neglectIsPathIndependentAndIdempotent(uint8 tierSeed, uint32 first, uint32 second)
        public
    {
        uint256 d1 = bound(first, 0, 40 days);
        uint256 d2 = bound(second, 0, 40 days);
        uint256 id = _mintFed(alice, uint8(bound(tierSeed, 0, 2)));
        uint256 start = vm.getBlockTimestamp();
        uint256 clean = vm.snapshotState();

        // Touch part way, then touch again at the end.
        vm.warp(start + d1);
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        vm.warp(start + d1 + d2);
        uint256 touched = _body(id);
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        assertEq(_body(id), touched, "a state touch only stores what the view already reported");

        // No touches at all gives the same score at the same instant.
        assertTrue(vm.revertToState(clean));
        vm.warp(start + d1 + d2);
        assertEq(_body(id), touched, "touching can neither dodge nor double-charge neglect");
    }

    function testFuzz_scoreNeverRisesFromTimeAlone(uint8 tierSeed, uint32 first, uint32 second) public {
        uint256 id = _mintFed(alice, uint8(bound(tierSeed, 0, 2)));
        uint256 t1 = vm.getBlockTimestamp() + bound(first, 0, 30 days);
        vm.warp(t1);
        uint256 earlier = _body(id);
        vm.warp(t1 + bound(second, 0, 30 days));
        assertLe(_body(id), earlier);
    }

    // ---------------------------------------------------------------- weight classes

    function test_weightClassBoundariesArePinned() public pure {
        assertEq(uint256(GameMath.weightClass(0)), uint256(WeightClass.Obese));
        assertEq(uint256(GameMath.weightClass(34)), uint256(WeightClass.Obese));
        assertEq(uint256(GameMath.weightClass(35)), uint256(WeightClass.Normal));
        assertEq(uint256(GameMath.weightClass(69)), uint256(WeightClass.Normal));
        assertEq(uint256(GameMath.weightClass(70)), uint256(WeightClass.Fit));
        assertEq(uint256(GameMath.weightClass(100)), uint256(WeightClass.Fit));
    }

    function testFuzz_betterScoreNeverGivesAWorseClass(uint8 seed) public pure {
        uint256 score = bound(seed, 0, 99);
        // The enum runs Fit=0, Normal=1, Obese=2: a healthier class has the lower value.
        assertLe(uint256(GameMath.weightClass(score + 1)), uint256(GameMath.weightClass(score)));
    }

    /// @dev Reaches each boundary through the real feed path, then reads the class the race would use. The
    ///      stored enum is what a round snapshots, and hamster() recomputes it, so only a lock shows it.
    function test_storedEnumFollowsTheScoreAcrossBoundariesInBothDirections() public {
        HamsterHarness harness = _harness();
        uint8[4] memory targets = [34, 35, 69, 70];
        WeightClass[4] memory expected =
            [WeightClass.Obese, WeightClass.Normal, WeightClass.Normal, WeightClass.Fit];
        for (uint256 viaLowFood; viaLowFood < 2; ++viaLowFood) {
            for (uint256 i; i < 4; ++i) {
                address player = makeAddr(string.concat("boundary", vm.toString(viaLowFood * 4 + i)));
                vm.deal(player, 1 ether);
                uint256 id = _mintFed(player, 0);
                if (viaLowFood == 1) {
                    harness.setBodyForTest(id, uint256(targets[i]) + 4);
                    _feed(player, id, 0); // -4
                } else {
                    harness.setBodyForTest(id, uint256(targets[i]) - 6);
                    _feed(player, id, 1); // +6
                }
                assertEq(_body(id), targets[i]);
                _enqueue(player, id);
            }
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        MatchQueue.Snapshot[] memory racers = queue.roundRacers(round);
        assertEq(racers.length, 8);
        for (uint256 i; i < 8; ++i) {
            assertEq(uint256(racers[i].weight), uint256(expected[i % 4]), "stored enum matches its score");
        }
    }

    function test_withoutTrainingEveryFoodRegimeDriftsDownInTierOrder() public {
        uint256 low = _mintFed(alice, 0);
        uint256 mid = _mintFed(bob, 1);
        uint256 high = _mintFed(carol, 2);
        for (uint256 cycle; cycle < 5; ++cycle) {
            vm.warp(nft.hamster(low).fedUntil);
            _feed(alice, low, 0);
            _feed(bob, mid, 1);
            _feed(carol, high, 2);
        }
        assertEq(_body(low), 0, "46 - 5 * 19 clamps");
        assertEq(_body(mid), 11, "56 - 5 * 9");
        assertEq(_body(high), 47, "62 - 5 * 3");
        assertEq(uint256(nft.hamster(low).weight), uint256(WeightClass.Obese));
        assertEq(uint256(nft.hamster(mid).weight), uint256(WeightClass.Obese));
        assertEq(uint256(nft.hamster(high).weight), uint256(WeightClass.Normal));
    }

    function test_trainedPetsRankByFoodTierAndBeatUntrainedOnes() public {
        uint256 low = _mintFed(alice, 0);
        uint256 high = _mintFed(bob, 2);
        uint256 untrained = _mintFed(carol, 2);
        vm.prank(alice);
        nft.startTraining(low);
        vm.prank(bob);
        nft.startTraining(high);
        _certifyTraining(nft, low, 5);
        nft.settleTraining(low);
        nft.settleTraining(high);
        // Low: 46 + 2 + 0 + min(10,10). High: 62 + 2 + 4 + min(20,10). Carol's only food: 62.
        assertEq(_body(low), 58);
        assertEq(_body(high), 78);
        assertEq(_body(untrained), 62);
        assertEq(uint256(nft.hamster(high).weight), uint256(WeightClass.Fit));
        assertEq(uint256(nft.hamster(untrained).weight), uint256(WeightClass.Normal));
    }

    function test_largerWorkEarnsMoreBodyCreditOnlyUpToTheDocumentedCap() public {
        uint64[3] memory works = [uint64(1), 2, 100];
        uint256[3] memory expected = [uint256(50), 52, 58];
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            uint256 id = _mintFed(players[i], 0);
            vm.prank(players[i]);
            nft.startTraining(id);
            _certifyTraining(nft, id, works[i]);
            nft.settleTraining(id);
            assertEq(_body(id), expected[i]);
        }
    }

    function test_lowFoodTrainingStopsAtTheCeilingOfSixty() public {
        HamsterHarness harness = _harness();
        assertEq(nft.LOW_FOOD_BODY_CEILING(), 60);
        uint256[4] memory starts = [uint256(50), 59, 60, 85];
        uint256[4] memory expected = [uint256(60), 60, 60, 85];
        for (uint256 i; i < 4; ++i) {
            address player = makeAddr(string.concat("ceiling", vm.toString(i)));
            vm.deal(player, 1 ether);
            uint256 id = _mintFed(player, 0);
            harness.setBodyForTest(id, starts[i]);
            _train(player, id);
            assertEq(_body(id), expected[i], "low food training lifts to 60 at most and never lowers");
        }
    }

    function testFuzz_lowFoodAloneNeverMakesAPetFit(uint8 rounds) public {
        uint256 id = _mintFed(alice, 0);
        uint256 n = bound(rounds, 1, 40);
        for (uint256 i; i < n; ++i) {
            if (nft.isHungry(id)) _feed(alice, id, 0);
            _train(alice, id);
            assertLe(_body(id), 60);
            assertTrue(nft.hamster(id).weight != WeightClass.Fit);
        }
    }

    function test_midFoodTrainingPassesSixtyAndReachesFit() public {
        HamsterHarness harness = _harness();
        uint256 id = _mintFed(alice, 1);
        harness.setBodyForTest(id, 60);
        _train(alice, id); // 60 + 2 + 2 + 10
        assertEq(_body(id), 74);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit));
    }

    function test_aFitPetOnACheapDietTrainingDailyDriftsToNormalNotBelow() public {
        HamsterHarness harness = _harness();
        uint256 id = _mintFed(alice, 0);
        harness.setBodyForTest(id, 90);
        // Back-to-back training takes no idle damage: only the -4 of each low feed (every ~72h) lowers it.
        for (uint256 i; i < 20; ++i) {
            if (nft.hamster(id).fedUntil < vm.getBlockTimestamp() + 6 hours) _feed(alice, id, 0);
            vm.warp(vm.getBlockTimestamp() + 5 hours);
            _train(alice, id);
        }
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit), "five days cost only two feeds");
        for (uint256 i; i < 60; ++i) {
            if (nft.hamster(id).fedUntil < vm.getBlockTimestamp() + 6 hours) _feed(alice, id, 0);
            vm.warp(vm.getBlockTimestamp() + 5 hours);
            _train(alice, id);
        }
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Normal));
        assertEq(_body(id), 66, "90 - 6 low feeds; training could not lift it while above 60");
    }

    // ---------------------------------------------------------------- feeding

    function testFuzz_feedAlwaysSetsDeadlineFromNowAndNeverShortensIt(
        uint8 firstTier,
        uint8 secondTier,
        uint32 gapSeed
    ) public {
        uint8 tier2 = uint8(bound(secondTier, 0, 2));
        uint256 id = _mintFed(alice, uint8(bound(firstTier, 0, 2)));
        uint256 previous = nft.hamster(id).fedUntil;
        uint256 at = vm.getBlockTimestamp() + bound(gapSeed, 0, 200 days);
        vm.warp(at);
        _feed(alice, id, tier2);
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        assertEq(ham.fedUntil, at + 72 hours);
        assertGe(ham.fedUntil, previous);
        assertEq(ham.foodTier, tier2);
        assertEq(ham.trainBps, nft.foodTrainBps(tier2));
        assertFalse(nft.isHungry(id));
    }

    function testFuzz_hungryExactlyAfterTheDeadline(uint32 elapsedSeed) public {
        uint256 id = _mintFed(alice, 0);
        uint256 elapsed = bound(elapsedSeed, 0, 10 days);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        assertEq(nft.isHungry(id), elapsed > 72 hours);
    }

    function test_cheaperRefeedDowngradesTheNextTrainingBonus() public {
        uint256 id = _mintFed(alice, 2);
        _feed(alice, id, 0);
        vm.prank(alice);
        nft.startTraining(id);
        (,, uint256 bps, uint8 tier) = nft.training(id);
        assertEq(bps, 10_000);
        assertEq(tier, 0);
        _certifyTraining(nft, id, 5);
        assertEq(nft.previewTrainingGain(id), 10);
    }

    function test_paymentRaisedOrLoweredInTheSameBlockNeverOverOrUndercharges() public {
        uint256 id = _mint(alice);
        vm.prank(owner);
        nft.setFoodConfig([uint256(1 ether), 2 ether, 3 ether], [uint256(10_000), 15_000, 20_000]);
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.IncorrectPayment.selector);
        nft.feed{ value: 0.0001 ether }(id, 0); // a stale, cheaper quote
        vm.stopPrank();
        vm.prank(owner);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 15_000, 20_000]);
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.IncorrectPayment.selector);
        nft.feed{ value: 1 ether }(id, 0); // a stale, dearer quote is refused, not kept
        vm.stopPrank();
        assertEq(address(nft).balance, 0);
        assertEq(alice.balance, 100 ether);
        assertTrue(nft.isHungry(id));
    }

    function test_rejectedFeedLeavesEveryFieldUntouched() public {
        uint256 id = _mintFed(alice, 1);
        HamsterRunNFT.Hamster memory before = nft.hamster(id);
        uint256 balanceBefore = address(nft).balance;
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.IncorrectPayment.selector);
        nft.feed{ value: 0.0003 ether - 1 }(id, 2);
        vm.expectRevert(HamsterRunNFT.IncorrectPayment.selector);
        nft.feed{ value: 0.0003 ether + 1 }(id, 2);
        vm.expectRevert(HamsterRunNFT.IncorrectPayment.selector);
        nft.feed(id, 2);
        vm.expectRevert(HamsterRunNFT.InvalidTier.selector);
        nft.feed{ value: 0.0003 ether }(id, 3);
        vm.expectRevert(HamsterRunNFT.InvalidTier.selector);
        nft.feed{ value: 0.0003 ether }(id, type(uint8).max);
        vm.stopPrank();
        assertEq(keccak256(abi.encode(nft.hamster(id))), keccak256(abi.encode(before)));
        assertEq(address(nft).balance, balanceBefore);
    }

    function test_operatorsMayMoveAPetButNeverPlayIt() public {
        uint256 id = _mintFed(alice, 0);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.startPrank(bob);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.feed{ value: 0.0001 ether }(id, 0);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.startTraining(id);
        vm.expectRevert(MatchQueue.NotTokenOwner.selector);
        queue.enqueue(id);
        vm.stopPrank();
        vm.prank(alice);
        nft.startTraining(id);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.cancelTraining(id);
    }

    // ---------------------------------------------------------------- training

    function test_trainingAtFullStaminaWidthKeepsGrowingUntilArithmeticStops() public {
        HamsterHarness harness = _harness();
        uint256 id = _mintFed(alice, 2);
        harness.setStaminaForTest(id, type(uint256).max - 20);
        // Five certified work units at high food add twenty stamina.
        _train(alice, id);
        assertEq(nft.hamster(id).stamina, type(uint256).max);
        vm.prank(alice);
        nft.startTraining(id);
        _certifyTraining(nft, id, 5);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        nft.settleTraining(id);
        assertEq(
            uint256(nft.hamster(id).activity), uint256(Activity.Training), "the failed settle rolled back"
        );
    }

    function test_startingOnTheLastFedSecondSettlesAfterExpiry() public {
        uint256 id = _mintFed(alice, 0);
        vm.warp(nft.hamster(id).fedUntil);
        vm.prank(alice);
        nft.startTraining(id);
        _certifyTraining(nft, id, 5);
        assertTrue(nft.isHungry(id));
        nft.settleTraining(id);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        nft.startTraining(id);
    }

    function test_settleAndCancelRejectEveryNonTrainingActivity() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(a);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.cancelTraining(a);

        _enqueue(alice, a);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(a);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.cancelTraining(a);

        _enqueue(bob, b);
        _waitQueueWindow();
        queue.requestRound(0);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(a);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.cancelTraining(a);
    }

    function test_cancelledTrainingCreditsNothingAndCannotBeReplayed() public {
        uint256 id = _mintFed(alice, 2);
        uint256 body = _body(id);
        vm.prank(alice);
        nft.startTraining(id);
        _certifyTraining(nft, id, 5);
        vm.prank(alice);
        nft.cancelTraining(id); // cancelling completed work still forfeits it
        (uint64 startRound, uint64 endRound, uint256 bps, uint8 tier) = nft.training(id);
        assertEq(startRound, 0);
        assertEq(endRound, 0);
        assertEq(bps, 0);
        assertEq(tier, 0);
        assertEq(nft.hamster(id).stamina, 10);
        assertEq(_body(id), body);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(id);
    }

    function test_cancelDoesNotResetTheIdleClockButSettlingDoes() public {
        uint256 cancelled = _mintFed(alice, 2);
        uint256 settled = _mintFed(bob, 2);
        uint256 start = block.timestamp;
        vm.prank(alice);
        nft.startTraining(cancelled);
        vm.prank(bob);
        nft.startTraining(settled);
        _certifyTraining(nft, settled, 5);
        vm.prank(alice);
        nft.cancelTraining(cancelled);
        nft.settleTraining(settled);
        uint256 cancelledBody = _body(cancelled);
        uint256 settledBody = _body(settled);
        assertEq(cancelledBody, 62);
        assertEq(settledBody, 78);
        // Both pets were locked for the one-hour window; that hour is paused, not idle, for the cancelled pet.
        uint256 locked = block.timestamp - start;
        assertEq(locked, 1 hours);
        vm.warp(start + 1 days);
        assertEq(
            _body(cancelled),
            cancelledBody,
            "the locked hour is excised, so the first idle day is not complete"
        );
        assertEq(_body(settled), settledBody, "less than a day since settlement");
        vm.warp(start + 1 days + locked);
        assertEq(
            _body(cancelled), cancelledBody - 5, "one full unlocked day since birth; cancel gave no reset"
        );
        assertEq(
            _body(settled), settledBody - 5, "exactly a day since settlement: the reset clock runs again"
        );
    }

    function test_transferKeepsAllCareStateAndGivesNoReset() public {
        uint256 id = _mintFed(alice, 2);
        _train(alice, id);
        vm.warp(block.timestamp + 1 days);
        HamsterRunNFT.Hamster memory before = nft.hamster(id);
        (uint256 week, uint256 used) = nft.matchQuota(id);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(keccak256(abi.encode(nft.hamster(id))), keccak256(abi.encode(before)));
        (uint256 weekAfter, uint256 usedAfter) = nft.matchQuota(id);
        assertEq(weekAfter, week);
        assertEq(usedAfter, used);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.startTraining(id);
        vm.prank(bob);
        nft.startTraining(id);
    }

    // ---------------------------------------------------------------- nonexistent pets

    function testFuzz_nonexistentPetsRevertEverywhere(uint256 idSeed) public {
        uint256 id = idSeed % 2 == 0 ? 0 : bound(idSeed, 1, type(uint256).max);
        if (id != 0 && id <= nft.totalSupply()) id = 0;
        bytes memory missing = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id);
        vm.startPrank(alice);
        vm.expectRevert(missing);
        nft.feed{ value: 0.0001 ether }(id, 0);
        vm.expectRevert(missing);
        nft.startTraining(id);
        vm.expectRevert(missing);
        nft.cancelTraining(id);
        vm.expectRevert(missing);
        nft.settleTraining(id);
        vm.expectRevert(missing);
        nft.hamster(id);
        vm.expectRevert(missing);
        nft.isHungry(id);
        vm.expectRevert(missing);
        nft.matchesThisWeek(id);
        vm.expectRevert(missing);
        nft.previewTrainingGain(id);
        vm.expectRevert(missing);
        queue.enqueue(id);
        vm.expectRevert(missing);
        queue.leaveQueue(id);
        vm.expectRevert(missing);
        queue.bandOf(id);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        queue.evictExpired(id);
        vm.stopPrank();
    }
}
