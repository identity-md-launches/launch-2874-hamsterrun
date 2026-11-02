// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest, HamsterHarness } from "./helpers/GameTest.sol";
import { CoreReader } from "../src/CoreReader.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { Activity, WeightClass } from "../src/GameMath.sol";

contract CareTest is GameTest {
    function test_startingStatsAndFeedDefaults() public {
        uint256 id = _mint(alice);
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        assertEq(ham.stamina, 10);
        assertEq(ham.bodyScore, 50);
        assertEq(uint256(ham.weight), uint256(WeightClass.Normal));
        assertEq(ham.fedUntil, 0);
        assertTrue(nft.isHungry(id));
        assertEq(nft.foodPrices(0), 0.0001 ether);
        assertEq(nft.foodPrices(1), 0.0002 ether);
        assertEq(nft.foodPrices(2), 0.0003 ether);
        assertEq(nft.foodTrainBps(0), 10_000);
        assertEq(nft.foodTrainBps(1), 15_000);
        assertEq(nft.foodTrainBps(2), 20_000);
    }

    function testFuzz_feedRequiresExactTierPrice(uint8 tierInput, uint96 paymentInput) public {
        uint8 tier = uint8(bound(tierInput, 0, 2));
        uint256 payment = bound(paymentInput, 0, 1 ether);
        uint256 id = _mint(alice);
        uint256 price = nft.foodPrices(tier);
        vm.prank(alice);
        if (payment != price) {
            vm.expectRevert(HamsterRunNFT.IncorrectPayment.selector);
            nft.feed{ value: payment }(id, tier);
            assertEq(address(nft).balance, 0);
            assertTrue(nft.isHungry(id));
        } else {
            nft.feed{ value: payment }(id, tier);
            assertEq(address(nft).balance, price);
        }
    }

    function test_allTiersFeedAndGiveDistinctTrainingBonus() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 1);
        uint256 c = _mintFed(carol, 2);
        assertEq(nft.hamster(a).bodyScore, 46);
        assertEq(nft.hamster(b).bodyScore, 56);
        assertEq(nft.hamster(c).bodyScore, 62);
        assertEq(address(nft).balance, 0.0006 ether);
        _train(alice, a);
        _train(bob, b);
        _train(carol, c);
        assertEq(nft.hamster(a).stamina, 20);
        assertEq(nft.hamster(b).stamina, 25);
        assertEq(nft.hamster(c).stamina, 30);
    }

    function test_feedResetsRatherThanStacksAndExactExpiryIsFed() public {
        uint256 id = _mintFed(alice, 1);
        uint256 firstExpiry = nft.hamster(id).fedUntil;
        vm.warp(block.timestamp + 1 hours);
        _feed(alice, id, 2);
        assertEq(nft.hamster(id).fedUntil, firstExpiry + 1 hours);
        vm.warp(nft.hamster(id).fedUntil);
        assertFalse(nft.isHungry(id));
        vm.warp(block.timestamp + 1);
        assertTrue(nft.isHungry(id));
    }

    function test_invalidTierAndNonOwnerFeedFail() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.InvalidTier.selector);
        nft.feed(id, 3);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.feed{ value: 0.0001 ether }(id, 0);
        vm.prank(alice);
        nft.approve(bob, id);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.feed{ value: 0.0001 ether }(id, 0);
    }

    function test_hungryGatesTrainingAndQueue() public {
        uint256 id = _mint(alice);
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        nft.startTraining(id);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        queue.enqueue(id);
        vm.stopPrank();
        _feed(alice, id, 0);
        vm.warp(nft.hamster(id).fedUntil + 1);
        vm.startPrank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        nft.startTraining(id);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        queue.enqueue(id);
        vm.stopPrank();
        _feed(alice, id, 2);
        _enqueue(alice, id);
    }

    function test_trainingCanStartAtFeedExpiryAndSettleAfterCertification() public {
        uint256 id = _mintFed(alice, 0);
        vm.warp(nft.hamster(id).fedUntil);
        _train(alice, id);
        assertEq(nft.hamster(id).stamina, 20);
        assertTrue(nft.isHungry(id));
    }

    function test_trainingLocksAllActionsAndSettlesExactlyOnce() public {
        uint256 id = _mintFed(alice, 2);
        vm.startPrank(alice);
        nft.startTraining(id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.transferFrom(alice, bob, id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        queue.enqueue(id);
        // Feeding stays open through the lock so the certification wait cannot starve the pet.
        (uint64 bookedStart, uint64 bookedEnd, uint256 bookedBps, uint8 bookedTier) = nft.training(id);
        nft.feed{ value: 0.0003 ether }(id, 2);
        {
            (uint64 start2, uint64 end2, uint256 bps2, uint8 tier2) = nft.training(id);
            assertEq(
                abi.encode(start2, end2, bps2, tier2),
                abi.encode(bookedStart, bookedEnd, bookedBps, bookedTier),
                "the booking snapshot ignores later feeds"
            );
        }
        vm.stopPrank();
        (, uint64 end,,) = nft.training(id);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.CoreCertificationLag.selector, uint64(0), end));
        nft.settleTraining(id);
        _certifyTraining(nft, id, 5);
        vm.prank(keeper);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 30);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Idle));
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit));
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(id);
    }

    function test_trainingConfigIsSnapshottedAtFeedAndStart() public {
        uint256 id = _mintFed(alice, 1);
        vm.prank(owner);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(20_000), 30_000, 40_000]);
        vm.prank(alice);
        nft.startTraining(id);
        (,, uint256 bps,) = nft.training(id);
        assertEq(bps, 15_000);
        vm.prank(owner);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(30_000), 40_000, 50_000]);
        _certifyTraining(nft, id, 5);
        assertEq(nft.previewTrainingGain(id), 15);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 25);
        assertEq(nft.hamster(id).trainBps, 15_000);
        _feed(alice, id, 1);
        assertEq(nft.hamster(id).trainBps, 40_000);
    }

    function test_lateTrainingSettlementStillUnlocksAndAccountsNeglect() public {
        uint256 id = _mintFed(alice, 2);
        vm.prank(alice);
        nft.startTraining(id);
        vm.warp(block.timestamp + 30 days);
        _certifyTraining(nft, id, 5);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 30);
        assertEq(nft.hamster(id).bodyScore, 16);
        assertTrue(nft.isHungry(id));
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
    }

    function test_trainingCancellationGivesNoRewardAndCannotBeForced() public {
        uint256 id = _mintFed(alice, 0);
        vm.prank(alice);
        nft.startTraining(id);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.cancelTraining(id);
        vm.prank(alice);
        nft.cancelTraining(id);
        assertEq(nft.hamster(id).stamina, 10);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Idle));
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(id);
        _train(alice, id);
        assertEq(nft.hamster(id).stamina, 20);
    }

    function test_weightTransitionsThroughObeseNormalFitAndNeglect() public {
        uint256 id = _mintFed(alice, 0);
        for (uint256 i; i < 3; ++i) {
            _feed(alice, id, 0);
        }
        assertEq(nft.hamster(id).bodyScore, 34);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Obese));
        _feed(alice, id, 1);
        assertEq(nft.hamster(id).bodyScore, 40);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Normal));
        _feed(alice, id, 2);
        _train(alice, id);
        assertEq(nft.hamster(id).bodyScore, 68);
        _feed(alice, id, 2);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit));
        vm.warp(block.timestamp + 20 days);
        assertEq(nft.hamster(id).bodyScore, 0);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Obese));
        _feed(alice, id, 2);
        _train(alice, id);
        _feed(alice, id, 2);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Normal));
    }

    function test_inactivityAndHungerPenaltiesAreNotResetByFrequentTouches() public {
        uint256 id = _mintFed(alice, 1); // 56
        uint256 start = block.timestamp;
        for (uint256 hour = 1; hour <= 24; ++hour) {
            vm.warp(start + hour * 1 hours);
            vm.prank(alice);
            nft.transferFrom(alice, alice, id);
        }
        assertEq(nft.hamster(id).bodyScore, 51);
        vm.warp(start + 72 hours);
        assertEq(nft.hamster(id).bodyScore, 41);
        vm.warp(start + 72 hours + 1);
        assertEq(nft.hamster(id).bodyScore, 36);
        vm.prank(alice);
        nft.transferFrom(alice, alice, id);
        assertEq(nft.hamster(id).bodyScore, 36);
        vm.warp(start + 96 hours);
        assertEq(nft.hamster(id).bodyScore, 31);
        vm.warp(start + 96 hours + 1);
        assertEq(nft.hamster(id).bodyScore, 26);
        _feed(alice, id, 1);
        assertEq(nft.hamster(id).bodyScore, 32);
    }

    function test_sustainedHighFoodWithoutTrainingStillDriftsTowardObese() public {
        uint256 id = _mintFed(alice, 2);
        for (uint256 cycle; cycle < 10; ++cycle) {
            vm.warp(nft.hamster(id).fedUntil);
            _feed(alice, id, 2);
        }
        assertFalse(nft.isHungry(id));
        assertEq(nft.hamster(id).bodyScore, 32); // 62 - 10 * (15 inactivity - 12 food)
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Obese));
    }

    function test_newbornTakesNoHungerDamageDuringItsFirstFeedWindow() public {
        uint256 id = _mint(alice);
        uint256 bornAt = block.timestamp;
        vm.warp(bornAt + 12);
        assertEq(nft.hamster(id).bodyScore, 50);
        assertTrue(nft.isHungry(id)); // still gated until the first feed
        vm.warp(bornAt + nft.FEED_SECONDS());
        assertEq(nft.hamster(id).bodyScore, 35); // three idle days only
        vm.warp(bornAt + nft.FEED_SECONDS() + 1);
        assertEq(nft.hamster(id).bodyScore, 30); // first begun hungry day after the window
        _feed(alice, id, 2);
        assertEq(nft.hamster(id).bodyScore, 42);
        // A wallet that mints and feeds in separate blocks gets the documented start.
        uint256 later = _mint(bob);
        vm.warp(block.timestamp + 12);
        _feed(bob, later, 2);
        assertEq(nft.hamster(later).bodyScore, 62);
        uint256 cheap = _mint(carol);
        vm.warp(block.timestamp + 12);
        for (uint256 i; i < 3; ++i) {
            _feed(carol, cheap, 0);
        }
        assertEq(nft.hamster(cheap).bodyScore, 38);
        assertEq(uint256(nft.hamster(cheap).weight), uint256(WeightClass.Normal));
    }

    function test_lowFoodOnlyTrainingNeverMakesAPetFit() public {
        uint256 id = _mintFed(alice, 0); // 46
        _train(alice, id);
        assertEq(nft.hamster(id).bodyScore, 58);
        _train(alice, id);
        assertEq(nft.hamster(id).bodyScore, nft.LOW_FOOD_BODY_CEILING());
        uint256 end = vm.getBlockTimestamp() + 60 days;
        uint256 peak;
        while (vm.getBlockTimestamp() < end) {
            if (nft.isHungry(id)) {
                _feed(alice, id, 0);
            }
            _train(alice, id);
            uint256 score = nft.hamster(id).bodyScore;
            if (score > peak) peak = score;
        }
        assertEq(peak, nft.LOW_FOOD_BODY_CEILING());
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Normal));
        assertGt(nft.hamster(id).stamina, 500); // the stamina side of training is not capped by food
        // Mid food from the same position lifts the ceiling immediately.
        _feed(alice, id, 1);
        _train(alice, id);
        assertGt(nft.hamster(id).bodyScore, nft.LOW_FOOD_BODY_CEILING());
    }

    function test_fitPetSwitchedToCheapFoodDriftsDownToNormal() public {
        uint256 id = _mintFed(alice, 2);
        _feed(alice, id, 2);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit)); // 74
        uint256 ceiling = nft.LOW_FOOD_BODY_CEILING();
        for (uint256 feedCount; feedCount < 6; ++feedCount) {
            _feed(alice, id, 0);
            for (uint256 session; session < 4; ++session) {
                uint256 scoreBefore = nft.hamster(id).bodyScore;
                _train(alice, id);
                uint256 scoreAfter = nft.hamster(id).bodyScore;
                // Cheap-food training never lifts the score above the ceiling.
                assertLe(scoreAfter, scoreBefore > ceiling ? scoreBefore : ceiling);
            }
            if (feedCount > 0) assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Normal));
            vm.warp(nft.hamster(id).fedUntil);
        }
        assertLe(nft.hamster(id).bodyScore, ceiling);
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Normal));
    }

    function test_tierBonusStaysStrictlyOrderedAtHighStamina() public {
        HamsterHarness high = new HamsterHarness(owner, address(core));
        nft = high;
        address[3] memory players = [alice, bob, carol];
        vm.prank(owner);
        nft.setMintOpen(true);
        for (uint8 tier; tier < 3; ++tier) {
            uint256 id = _mintFed(players[tier], tier);
            high.setStaminaForTest(id, uint256(type(uint128).max));
            _train(players[tier], id);
            assertEq(high.hamster(id).stamina, uint256(type(uint128).max) + 10 + 5 * tier);
        }
    }

    function test_staminaGrowsFarBeyondSmallIntegerLimits() public {
        HamsterHarness high = new HamsterHarness(owner, address(core));
        vm.prank(owner);
        uint256 id = high.ownerMint(alice);
        high.setStaminaForTest(id, uint256(type(uint128).max) + 10);
        vm.startPrank(alice);
        high.feed{ value: 0.0003 ether }(id, 2);
        high.startTraining(id);
        vm.stopPrank();
        _certifyTraining(high, id, 5);
        high.settleTraining(id);
        assertEq(high.hamster(id).stamina, uint256(type(uint128).max) + 30);
    }

    function test_uint256OverflowRevertsWithoutWrappingAndTrainingCanCancel() public {
        HamsterHarness high = new HamsterHarness(owner, address(core));
        vm.prank(owner);
        uint256 id = high.ownerMint(alice);
        high.setStaminaForTest(id, type(uint256).max);
        vm.startPrank(alice);
        high.feed{ value: 0.0003 ether }(id, 2);
        high.startTraining(id);
        vm.stopPrank();
        _certifyTraining(high, id, 5);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        high.settleTraining(id);
        assertEq(high.hamster(id).stamina, type(uint256).max);
        vm.prank(alice);
        high.cancelTraining(id);
        assertEq(uint256(high.hamster(id).activity), uint256(Activity.Idle));
    }
}
