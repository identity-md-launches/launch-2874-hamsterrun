// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest } from "./helpers/GameTest.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { CoreReader } from "../src/CoreReader.sol";
import { Activity, WeightClass } from "../src/GameMath.sol";

/// @notice The SqueekCore frontier can trail the clock by days (about 6.8 days on Sepolia at review time).
///         A booked pet waits on that lag through no fault of its owner, so: the wait is never billed as
///         inactivity, the owner can keep feeding through it, and queue bands pair pets by stamina ratio so
///         one certified window cannot strand a pet in a band of its own.
contract CertificationWaitTest is GameTest {
    function _book(address player, uint8 tier) private returns (uint256 id, uint64 end) {
        id = _mintFed(player, tier);
        vm.prank(player);
        nft.startTraining(id);
        (, end,,) = nft.training(id);
    }

    function _endTime(uint64 end) private view returns (uint256) {
        return uint256(core.configuration().genesisTimestamp) + uint256(end) * 600;
    }

    function _booking(uint256 id) private view returns (bytes memory) {
        (uint64 start, uint64 end, uint256 bps, uint8 tier) = nft.training(id);
        return abi.encode(start, end, bps, tier);
    }

    // ---------------------------------------------------------------- the idle clock pauses while booked

    function test_certificationWaitIsNotBilledAsInactivity() public {
        (uint256 id, uint64 end) = _book(alice, 2);
        assertEq(nft.hamster(id).bodyScore, 62);
        vm.warp(_endTime(end) + 2 days);
        assertFalse(nft.isHungry(id), "still inside the 72h food window");
        assertEq(nft.hamster(id).bodyScore, 62, "a booked pet is waiting on Core, not idle");
        core.certify(end, 5);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 30);
        assertEq(nft.hamster(id).bodyScore, 78, "62 + 2 + 4 + min(20, 10): no idle days were charged");
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit));
    }

    function test_sevenDayLagWithThePinnedLiveWindowEndsFitWhenFedOnCadence() public {
        // Review-time Sepolia: frontier about 6.8 days behind; the pinned window 1868..1873 carried 1012 work.
        (uint256 id, uint64 end) = _book(alice, 2);
        for (uint256 day = 1; day <= 7; ++day) {
            vm.warp(block.timestamp + 1 days);
            if (day % 3 == 0) _feed(alice, id, 2); // the kept 72h cadence, now possible while locked
        }
        assertEq(nft.hamster(id).bodyScore, 86, "62 + 12 + 12: two feeds, no idle and no hunger damage");
        core.certify(end, 1012);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 4058);
        assertEq(nft.hamster(id).bodyScore, 100, "86 + 16 capped");
        assertEq(uint256(nft.hamster(id).weight), uint256(WeightClass.Fit));
    }

    function test_hungerDuringTheWaitStaysTheOwnersResponsibility() public {
        (uint256 id, uint64 end) = _book(alice, 2);
        vm.warp(block.timestamp + 5 days);
        assertTrue(nft.isHungry(id));
        // Two begun hungry days after the 72h window, and no idle days at all while locked.
        assertEq(nft.hamster(id).bodyScore, 52);
        core.certify(end, 5);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).bodyScore, 68, "52 + 16");
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        nft.startTraining(id);
    }

    function test_zeroWorkSettleAfterALagResumesTheIdleClockWithoutAReset() public {
        uint256 born = block.timestamp;
        (uint256 id, uint64 end) = _book(alice, 2);
        vm.warp(_endTime(end) + 20 hours);
        core.certify(end, 0);
        nft.settleTraining(id);
        uint256 locked = block.timestamp - born;
        assertEq(locked, 21 hours);
        assertEq(nft.hamster(id).bodyScore, 62, "no idle charge for the wait, no credit for zero work");
        vm.warp(born + locked + 23 hours);
        assertEq(nft.hamster(id).bodyScore, 62, "23 unlocked hours do not complete a day");
        vm.warp(born + locked + 24 hours);
        assertFalse(nft.isHungry(id));
        assertEq(nft.hamster(id).bodyScore, 57, "the first unlocked day completes: the lock gave no reset");
    }

    function test_cancelAfterALagResumesTheIdleClockWithoutAReset() public {
        uint256 born = block.timestamp;
        (uint256 id, uint64 end) = _book(alice, 2);
        vm.warp(_endTime(end) + 20 hours);
        vm.prank(alice);
        nft.cancelTraining(id);
        uint256 locked = block.timestamp - born;
        assertEq(nft.hamster(id).bodyScore, 62);
        vm.warp(born + locked + 23 hours);
        assertEq(nft.hamster(id).bodyScore, 62);
        vm.warp(born + locked + 24 hours);
        assertEq(nft.hamster(id).bodyScore, 57, "cancel pauses the clock during the lock but never resets it");
    }

    function test_idleDaysCompletedBeforeBookingAreChargedAndThePartialDayCarriesOver() public {
        uint256 born = block.timestamp;
        uint256 id = _mintFed(alice, 2);
        vm.warp(born + 1 days + 20 hours); // 1 complete idle day plus 20 hours of a second
        assertEq(nft.hamster(id).bodyScore, 57);
        vm.prank(alice);
        nft.startTraining(id);
        (, uint64 end,,) = nft.training(id);
        _feed(alice, id, 2); // keep the pet fed through the wait so only the idle clock is observed
        assertEq(nft.hamster(id).bodyScore, 69);
        vm.warp(_endTime(end) + 2 days);
        assertEq(nft.hamster(id).bodyScore, 69, "nothing accrues while locked");
        core.certify(end, 0);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).bodyScore, 69);
        vm.warp(block.timestamp + 4 hours);
        assertEq(nft.hamster(id).bodyScore, 64, "the 20-hour partial day resumes and completes 4 hours later");
    }

    function testFuzz_lockDurationNeverChangesIdleDamage(uint32 lagSeed, bool positiveWork) public {
        uint256 lag = bound(lagSeed, 0, 30 days);
        (uint256 id, uint64 end) = _book(alice, 2);
        vm.warp(_endTime(end) + lag);
        _feed(alice, id, 2); // keep hunger out of the picture whatever the lag
        uint256 beforeSettle = nft.hamster(id).bodyScore;
        core.certify(end, positiveWork ? 5 : 0);
        nft.settleTraining(id);
        uint256 expected = positiveWork ? (beforeSettle + 16 > 100 ? 100 : beforeSettle + 16) : beforeSettle;
        assertEq(nft.hamster(id).bodyScore, expected, "the lag itself costs nothing");
    }

    // ---------------------------------------------------------------- feeding through the wait

    function test_ownerCanFeedThroughTheWaitAndTheBookingIsUntouched() public {
        (uint256 id, uint64 end) = _book(alice, 2);
        bytes memory booking = _booking(id);
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.CoreCertificationLag.selector, uint64(0), end));
        nft.settleTraining(id);
        assertTrue(nft.isHungry(id));
        assertEq(nft.hamster(id).bodyScore, 57, "one begun hungry day");

        _feed(alice, id, 0); // a cheaper feed during the wait
        assertFalse(nft.isHungry(id));
        assertEq(nft.hamster(id).bodyScore, 53);
        assertEq(_booking(id), booking, "the booking snapshot ignores later feeds");
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Training));
        assertEq(nft.hamster(id).trainBps, 10_000, "the live food changed for the next booking only");

        core.certify(end, 5);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 30, "paid at the booked 20000 bps, not the later cheap feed");
        assertEq(nft.hamster(id).bodyScore, 69, "53 + 2 + 4 + 10: the booked tier's body credit");
        vm.prank(alice);
        nft.startTraining(id);
        (,, uint256 bps, uint8 tier) = nft.training(id);
        assertEq(bps, 10_000);
        assertEq(tier, 0);
    }

    function test_feedingWhileBookedIsStillOwnerOnlyAndOpensNoOtherAction() public {
        (uint256 id,) = _book(alice, 1);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        nft.feed{ value: 0.0002 ether }(id, 1);
        vm.startPrank(alice);
        nft.feed{ value: 0.0002 ether }(id, 1);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.transferFrom(alice, bob, id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        queue.enqueue(id);
        vm.stopPrank();
    }

    function test_feedingStaysLockedWhileQueuedOrMatched() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        _enqueue(alice, a);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.feed{ value: 0.0001 ether }(a, 0);
        _enqueue(bob, b);
        _waitQueueWindow();
        queue.requestRound(0);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.feed{ value: 0.0001 ether }(a, 0);
    }

    // ---------------------------------------------------------------- geometric bands

    function test_bandForStaminaTable() public view {
        uint256[12] memory stamina =
            [uint256(0), 10, 499, 500, 999, 1000, 1999, 2000, 8010, 8862, 15_999, 16_000];
        uint256[12] memory expected = [uint256(0), 0, 0, 1, 1, 2, 2, 3, 5, 5, 5, 6];
        for (uint256 i; i < stamina.length; ++i) {
            assertEq(queue.bandForStamina(stamina[i]), expected[i]);
        }
        assertEq(queue.bandForStamina(type(uint256).max), 248, "full-width stamina still has a band");
    }

    function testFuzz_petsInOneBandAreWithinAFactorOfTwoAndBandsAreMonotonic(uint256 a, uint256 b)
        public
        view
    {
        a = bound(a, queue.BAND_WIDTH(), type(uint256).max);
        b = bound(b, queue.BAND_WIDTH(), type(uint256).max);
        (uint256 lo, uint256 hi) = a <= b ? (a, b) : (b, a);
        assertLe(queue.bandForStamina(lo), queue.bandForStamina(hi));
        if (queue.bandForStamina(lo) == queue.bandForStamina(hi)) {
            assertLt(hi - lo, lo, "same band means less than double");
        }
    }

    function test_pinnedLiveWindowAcrossTiersLandsInNeighbouringBands() public {
        address[3] memory players = [alice, bob, carol];
        uint256[3] memory expectedStamina = [uint256(2034), 3046, 4058];
        uint256[3] memory expectedBand = [uint256(3), 3, 4];
        for (uint8 tier; tier < 3; ++tier) {
            (uint256 id, uint64 end) = _book(players[tier], tier);
            vm.warp(_endTime(end));
            core.certify(end, 1012);
            nft.settleTraining(id);
            assertEq(nft.hamster(id).stamina, expectedStamina[tier]);
            assertEq(queue.bandOf(id), expectedBand[tier]);
            vm.warp(block.timestamp + 600); // the next pet books a later, separately certified window
        }
    }

    function test_comparableLiveWorkPairsAndRacesAfterOneWindowEach() public {
        // Two live-sized windows (p90-ish 2213 and 2000 work) at high food: 8862 and 8010 stamina.
        (uint256 a, uint64 endA) = _book(alice, 2);
        vm.warp(_endTime(endA));
        core.certify(endA, 2213);
        nft.settleTraining(a);
        (uint256 b, uint64 endB) = _book(bob, 2);
        vm.warp(_endTime(endB));
        core.certify(endB, 2000);
        nft.settleTraining(b);
        assertEq(nft.hamster(a).stamina, 8862);
        assertEq(nft.hamster(b).stamina, 8010);
        assertEq(queue.bandOf(a), 5);
        assertEq(queue.bandOf(b), 5, "a 10% work difference keeps comparable pets matchable");

        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("comparable live windows"));
        assertEq(ids.length, 1);
        queue.settleMatch(ids[0]);
        assertTrue(queue.matchInfo(ids[0]).settled);
        assertEq(nft.hamster(a).stamina + nft.hamster(b).stamina, 8862 + 8010 + 4);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        assertEq(uint256(nft.hamster(b).activity), uint256(Activity.Idle));
    }

    function test_untrainedPetsAllShareBandZeroAndCannotMeetATrainedOne() public {
        (uint256 trained, uint64 end) = _book(alice, 2);
        vm.warp(_endTime(end));
        core.certify(end, 2213);
        nft.settleTraining(trained);
        uint256 fresh = _mintFed(bob, 0);
        uint256 raced = _mintFed(carol, 0);
        assertEq(queue.bandOf(fresh), 0);
        assertEq(queue.bandOf(raced), 0);
        _enqueue(alice, trained);
        _enqueue(bob, fresh);
        _waitQueueWindow();
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(0);
        vm.expectRevert(MatchQueue.NotEnoughPlayers.selector);
        queue.requestRound(5);
        _enqueue(carol, raced);
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        assertEq(queue.roundRacers(round).length, 2, "only the two untrained pets race");
        assertEq(queue.queueEntries(5)[0].tokenId, trained, "the trained pet keeps waiting in its own band");
    }
}
