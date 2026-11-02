// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest } from "./helpers/GameTest.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { CoreReader } from "../src/CoreReader.sol";
import { ISqueekCore } from "../src/interfaces/ISqueekCore.sol";
import { Activity, GameMath } from "../src/GameMath.sol";

contract CoreTrainingTest is GameTest {
    function test_previewCannotInventWorkForAnIdleToken() public {
        uint256 id = _mintFed(alice, 2);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.previewTrainingGain(id);
        assertFalse(nft.trainingStatus(id).active);
    }

    function test_overlappingPetsUseTheirOwnExactWindow() public {
        uint256 a = _mintFed(alice, 2);
        vm.prank(alice);
        nft.startTraining(a); // 11..16
        vm.warp(vm.getBlockTimestamp() + 3 * 600);
        uint256 b = _mintFed(bob, 2);
        vm.prank(bob);
        nft.startTraining(b); // 14..19
        vm.warp(_endTime(19));
        uint64[] memory rounds = new uint64[](4);
        uint64[] memory works = new uint64[](4);
        rounds[0] = 11;
        works[0] = 1;
        rounds[1] = 14;
        works[1] = 2;
        rounds[2] = 16;
        works[2] = 3;
        rounds[3] = 19;
        works[3] = 4;
        core.certifyBatch(19, rounds, works);
        nft.settleTraining(b);
        nft.settleTraining(a);
        assertEq(nft.hamster(a).stamina, 34); // (1+2+3)*4 + 10
        assertEq(nft.hamster(b).stamina, 46); // (2+3+4)*4 + 10
    }

    function _start(uint8 tier) private returns (uint256 id, uint64 start, uint64 end) {
        id = _mintFed(alice, tier);
        vm.prank(alice);
        nft.startTraining(id);
        (start, end,,) = nft.training(id);
    }

    function _endTime(uint64 end) private view returns (uint256) {
        return uint256(core.configuration().genesisTimestamp) + uint256(end) * 600;
    }

    function test_currentRoundUsesCoreGenesisAndOneBasedRounds() public {
        uint64 genesis = core.configuration().genesisTimestamp;
        vm.warp(genesis - 1);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.CoreNotStarted.selector, genesis));
        nft.currentRound();
        vm.warp(genesis);
        assertEq(nft.currentRound(), 1);
        vm.warp(uint256(genesis) + 599);
        assertEq(nft.currentRound(), 1);
        vm.warp(uint256(genesis) + 600);
        assertEq(nft.currentRound(), 2);
    }

    function testFuzz_startBooksSixInclusiveRoundsAndCapturesFood(uint16 phaseSeed, uint8 tierSeed) public {
        uint256 phase = uint256(phaseSeed) % 600;
        uint8 tier = tierSeed % 3;
        vm.warp(vm.getBlockTimestamp() + phase);
        (uint256 id, uint64 start, uint64 end) = _start(tier);
        (,, uint256 bps, uint8 storedTier) = nft.training(id);
        assertEq(start, 11);
        assertEq(end, 16);
        assertEq(bps, 10_000 + uint256(tier) * 5000);
        assertEq(storedTier, tier);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Training));
        assertEq(nft.hamster(id).stamina, 10);
    }

    function test_roundOneReadsLaunchPositionWithoutUnderflow() public {
        core.setConfiguration(uint64(vm.getBlockTimestamp()), 600);
        (uint256 id, uint64 start, uint64 end) = _start(0);
        assertEq(start, 1);
        assertEq(end, 6);
        _certifyTraining(nft, id, 3);
        assertEq(nft.certifiedWork(1, 6), 3);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 16);
    }

    function test_elapsedTimeAloneNeverSettlesOrCreatesAGain() public {
        (uint256 id,, uint64 end) = _start(2);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        bytes memory expected =
            abi.encodeWithSelector(CoreReader.CoreCertificationLag.selector, uint64(0), end);
        vm.expectRevert(expected);
        nft.settleTraining(id);
        vm.expectRevert(expected);
        nft.previewTrainingGain(id);
        assertEq(nft.hamster(id).stamina, 10);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Training));
        HamsterRunNFT.TrainingStatus memory status = nft.trainingStatus(id);
        assertTrue(status.active);
        assertFalse(status.ready);
        assertTrue(status.waitingForCertification);
        assertEq(status.frontier, 0);
        assertEq(status.trainEndRound, end);
        assertEq(status.gain, 0); // unknown, qualified by ready == false
        vm.prank(alice);
        nft.cancelTraining(id);
        assertEq(nft.ownerOf(id), alice); // hunger never burns the NFT
        assertFalse(nft.trainingStatus(id).active);
    }

    function test_partialCertificationCannotCashOutEvenNonzeroWork() public {
        (uint256 id,, uint64 end) = _start(1);
        vm.warp(_endTime(end));
        core.certify(end - 1, 1000);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.CoreCertificationLag.selector, end - 1, end));
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 10);
        core.certify(end, 0); // certified zero closes the window; no missing-record ambiguity
        assertEq(nft.previewTrainingGain(id), 3000);
        vm.prank(keeper);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 3010);
    }

    function test_onlyBookedWorkCountsEvenWithBacklogAndLaterCertification() public {
        core.certify(10, 9000);
        (uint256 id, uint64 start, uint64 end) = _start(2);
        vm.warp(_endTime(end + 10));
        uint64[] memory rounds = new uint64[](4);
        uint64[] memory works = new uint64[](4);
        rounds[0] = start;
        works[0] = 2;
        rounds[1] = start + 2;
        works[1] = 3;
        rounds[2] = end;
        works[2] = 5;
        rounds[3] = end + 1;
        works[3] = 7000;
        core.certifyBatch(end + 10, rounds, works);
        vm.expectCall(address(core), abi.encodeCall(ISqueekCore.roundPage, (start - 1, end, 6)));
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 50); // only (2+3+5)*4; excludes 9000 and 7000
        assertEq(core.state().cumulativeWork, 16_010);
        assertEq(core.state().settledThroughRound, end + 10);
    }

    function test_sixActiveRoundsFitOneCompletePage() public {
        (uint256 id, uint64 start, uint64 end) = _start(1);
        vm.warp(_endTime(end));
        uint64[] memory rounds = new uint64[](6);
        uint64[] memory works = new uint64[](6);
        for (uint64 i; i < 6; ++i) {
            rounds[i] = start + i;
            works[i] = i + 1;
        }
        core.certifyBatch(end, rounds, works);
        HamsterRunNFT.TrainingStatus memory status = nft.trainingStatus(id);
        assertTrue(status.ready);
        assertFalse(status.waitingForCertification);
        assertEq(status.work, 21);
        assertEq(status.gain, 63);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 73);
    }

    function test_certifiedZeroWorkUnlocksWithoutHealthOrClockReward() public {
        uint256 born = vm.getBlockTimestamp();
        (uint256 id,,) = _start(2);
        _certifyTraining(nft, id, 0);
        HamsterRunNFT.TrainingStatus memory status = nft.trainingStatus(id);
        assertTrue(status.ready);
        assertEq(status.work, 0);
        assertEq(status.gain, 0);
        assertEq(nft.previewTrainingGain(id), 0);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 10);
        assertEq(nft.hamster(id).bodyScore, 62);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Idle));
        vm.warp(born + 1 days);
        assertEq(nft.hamster(id).bodyScore, 57, "zero work does not reset inactivity");
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
    }

    function test_oneUnitStrictlyOrdersAllDefaultFoodTiers() public {
        address[3] memory players = [alice, bob, carol];
        for (uint8 tier; tier < 3; ++tier) {
            uint256 id = _mintFed(players[tier], tier);
            vm.prank(players[tier]);
            nft.startTraining(id);
        }
        _certifyTraining(nft, 1, 1);
        for (uint256 id = 1; id <= 3; ++id) {
            nft.settleTraining(id);
            assertEq(nft.hamster(id).stamina, 11 + id); // 12, 13, 14
        }
    }

    function testFuzz_gainIsExactlyCertifiedWorkTimesCapturedTier(uint64 work, uint8 tierSeed) public {
        uint8 tier = tierSeed % 3;
        (uint256 id,,) = _start(tier);
        _certifyTraining(nft, id, work);
        uint256 expectedGain = uint256(work) * (2 + uint256(tier));
        assertEq(nft.previewTrainingGain(id), expectedGain);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 10 + expectedGain);
    }

    function testFuzz_everyAcceptedBpsConfigStrictlyOrdersPositiveWork(
        uint64 workSeed,
        uint16 lowSeed,
        uint16 midSeed,
        uint16 highSeed
    ) public {
        uint64 work = workSeed == 0 ? 1 : workSeed;
        uint256 low = bound(lowSeed, 10_000, 40_000);
        uint256 mid = bound(midSeed, low + 5000, 45_000);
        uint256 high = bound(highSeed, mid + 5000, 50_000);
        vm.prank(owner);
        nft.setFoodConfig([uint256(1), 2, 3], [low, mid, high]);
        assertLt(GameMath.trainingGain(work, low), GameMath.trainingGain(work, mid));
        assertLt(GameMath.trainingGain(work, mid), GameMath.trainingGain(work, high));
        assertEq(GameMath.trainingGain(0, high), 0);
    }

    function testFuzz_gainIsMonotonicAndRoundingIsDown(uint64 work, uint16 bpsSeed) public pure {
        uint256 bps = 10_000 + uint256(bpsSeed) % 40_001;
        uint256 numerator = uint256(work) * 2 * bps;
        uint256 gain = GameMath.trainingGain(work, bps);
        assertLe(gain * 10_000, numerator);
        assertLt(numerator - gain * 10_000, 10_000);
        if (work < type(uint64).max) assertGt(GameMath.trainingGain(work + 1, bps), gain);
    }

    function test_configWithCollapsingTierRoundingIsRejected() public {
        vm.startPrank(owner);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 10_001, 20_000]);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 15_000, 19_999]);
        vm.stopPrank();
    }

    function test_nextWindowCannotReplayAlreadyCreditedRounds() public {
        (uint256 id,, uint64 end) = _start(0);
        _certifyTraining(nft, id, 5);
        nft.settleTraining(id);
        vm.prank(alice);
        nft.startTraining(id);
        (uint64 nextStart, uint64 nextEnd,,) = nft.training(id);
        assertEq(nextStart, end + 1);
        assertEq(nextEnd, end + 6);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.CoreCertificationLag.selector, end, nextEnd));
        nft.settleTraining(id);
        _certifyTraining(nft, id, 0);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 20);
    }

    function test_corePauseDoesNotInvalidatePreviouslyCertifiedWork() public {
        (uint256 id,,) = _start(2);
        _certifyTraining(nft, id, 5);
        core.setPaused(true);
        assertTrue(nft.trainingStatus(id).corePaused);
        assertTrue(nft.trainingStatus(id).ready);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 30);
    }

    function test_cancelRemainsAvailableWhenCoreDisappears() public {
        (uint256 id,,) = _start(2);
        vm.etch(address(core), hex"");
        vm.expectRevert(CoreReader.CoreUnavailable.selector);
        nft.settleTraining(id);
        vm.prank(alice);
        nft.cancelTraining(id);
        assertEq(nft.hamster(id).stamina, 10);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
    }

    function test_emptyChainConstructorThenClearFirstUseError() public {
        address absent = makeAddr("core not deployed on this test chain");
        HamsterRunNFT fresh = new HamsterRunNFT(owner, absent);
        assertEq(address(fresh.core()), absent);
        vm.prank(owner);
        uint256 id = fresh.ownerMint(alice);
        vm.startPrank(alice);
        fresh.feed{ value: 0.0001 ether }(id, 0);
        vm.expectRevert(CoreReader.CoreUnavailable.selector);
        fresh.startTraining(id);
        vm.stopPrank();
        assertEq(uint256(fresh.hamster(id).activity), uint256(Activity.Idle));
        vm.expectRevert(CoreReader.InvalidCore.selector);
        new HamsterRunNFT(owner, address(0));
    }

    function test_badConfigStopsNewBookingsButCannotTrapOldWork() public {
        (uint256 id,,) = _start(0);
        _certifyTraining(nft, id, 5);
        core.setConfiguration(0, 600);
        vm.expectRevert(CoreReader.UnsupportedCoreConfiguration.selector);
        nft.currentRound();
        nft.settleTraining(id); // settlement does not re-read mutable clock configuration
        core.setConfiguration(uint64(vm.getBlockTimestamp()), 601);
        vm.prank(alice);
        vm.expectRevert(CoreReader.UnsupportedCoreConfiguration.selector);
        nft.startTraining(id);
        assertEq(nft.hamster(id).stamina, 20);
    }

    function test_roundAndWindowOverflowAreExplicit() public {
        uint64 genesis = core.configuration().genesisTimestamp;
        vm.warp(uint256(genesis) + uint256(type(uint64).max) * 600);
        vm.expectRevert(CoreReader.RoundOverflow.selector);
        nft.currentRound();
        vm.warp(uint256(genesis) + (uint256(type(uint64).max) - 1) * 600);
        uint256 id = _mintFed(alice, 0);
        vm.prank(alice);
        vm.expectRevert(CoreReader.RoundOverflow.selector);
        nft.startTraining(id);
    }

    function test_invalidReadWindowsRevert() public {
        vm.expectRevert(CoreReader.InvalidTrainingWindow.selector);
        nft.certifiedWork(0, 6);
        vm.expectRevert(CoreReader.InvalidTrainingWindow.selector);
        nft.certifiedWork(9, 8);
        vm.expectRevert(CoreReader.InvalidTrainingWindow.selector);
        nft.certifiedWork(1, 17);
    }

    function test_unavailableStateOrPageNeverFallsBackToTime() public {
        (uint256 id,,) = _start(2);
        _certifyTraining(nft, id, 5);
        bytes memory reason = abi.encodeWithSignature("Error(string)", "upstream unavailable");
        vm.mockCallRevert(address(core), abi.encodeCall(ISqueekCore.state, ()), reason);
        vm.expectRevert(reason);
        nft.settleTraining(id);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(core), abi.encodeWithSelector(ISqueekCore.roundPage.selector), reason);
        vm.expectRevert(reason);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 10);
        vm.clearMockedCalls();
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 30);
    }

    function testFuzz_malformedPageCannotPartiallyCreditOrUnlock(uint8 modeSeed) public {
        (uint256 id, uint64 start, uint64 end) = _start(2);
        _certifyTraining(nft, id, 5);
        ISqueekCore.RoundPage memory page = core.roundPage(start - 1, end, 6);
        uint8 mode = modeSeed % 8;
        if (mode == 0) page.certifiedThroughRound = end - 1;
        if (mode == 1) page.certifiedThroughRound = end + 1;
        if (mode == 2) page.start.cumulativeWork = page.end.cumulativeWork + 1;
        if (mode == 3) page.rounds = new ISqueekCore.RoundCheckpoint[](0);
        if (mode == 4) page.rounds[0].roundId = start - 1;
        if (mode == 5) page.rounds[0].roundId = end + 1;
        if (mode == 6) page.rounds[0].cumulativeWork = 0;
        if (mode == 7) page.rounds = new ISqueekCore.RoundCheckpoint[](7);
        bytes memory before = abi.encode(nft.hamster(id));
        vm.mockCall(
            address(core), abi.encodeCall(ISqueekCore.roundPage, (start - 1, end, 6)), abi.encode(page)
        );
        vm.expectRevert(CoreReader.InvalidCorePage.selector);
        nft.settleTraining(id);
        assertEq(abi.encode(nft.hamster(id)), before);
        (, uint64 storedEnd,,) = nft.training(id);
        assertEq(storedEnd, end);
    }

    function test_approvedSafeTransfersCannotBypassTrainingLock() public {
        (uint256 id,,) = _start(0);
        vm.prank(alice);
        nft.approve(bob, id);
        vm.startPrank(bob);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.safeTransferFrom(alice, bob, id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.safeTransferFrom(alice, bob, id, hex"1234");
        vm.stopPrank();
    }
}
