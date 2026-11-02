// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest } from "./helpers/GameTest.sol";
import { GameMath, WeightClass } from "../src/GameMath.sol";
import { MatchQueue } from "../src/MatchQueue.sol";

contract MathAndRandomnessTest is GameTest {
    function testFuzz_raceMathIsOrderedAndSafeAtFullWidth(uint256 stamina, uint16 noiseSeed) public pure {
        uint256 noise = uint256(noiseSeed) % 2001;
        uint256 fit = GameMath.raceScore(stamina, WeightClass.Fit, noise);
        uint256 normal = GameMath.raceScore(stamina, WeightClass.Normal, noise);
        uint256 obese = GameMath.raceScore(stamina, WeightClass.Obese, noise);
        assertGe(fit, normal);
        assertGe(normal, obese);
        assertLe(fit, stamina);
        if (noise < 2000) assertGe(GameMath.raceScore(stamina, WeightClass.Fit, noise + 1), fit);
        if (stamina < type(uint256).max) {
            assertGe(GameMath.raceScore(stamina + 1, WeightClass.Fit, noise), fit);
        }
    }

    function test_exactRaceFormulaAndNoiseRange() public {
        assertEq(queue.previewRaceScore(100, WeightClass.Fit, 1000), 57);
        assertEq(queue.previewRaceScore(100, WeightClass.Normal, 1000), 50);
        assertEq(queue.previewRaceScore(100, WeightClass.Obese, 1000), 42);
        assertEq(queue.previewRaceScore(100, WeightClass.Fit, 0), 52);
        assertEq(queue.previewRaceScore(100, WeightClass.Obese, 2000), 47);
        assertGt(queue.previewRaceScore(type(uint256).max, WeightClass.Fit, 2000), type(uint128).max);
        vm.expectRevert(GameMath.InvalidNoise.selector);
        queue.previewRaceScore(10, WeightClass.Normal, 2001);
    }

    function testFuzz_pairingIsPermutationAndRewardsConserve(uint8 countSeed, bytes32 entropy) public {
        vm.assume(entropy != bytes32(0));
        uint256 count = 2 + 2 * (uint256(countSeed) % 4);
        address[] memory players = new address[](count);
        for (uint256 i; i < count; ++i) {
            players[i] = makeAddr(string.concat("fuzz player", vm.toString(i)));
            vm.deal(players[i], 1 ether);
            uint256 id = _mintFed(players[i], 0);
            _enqueue(players[i], id);
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        uint256[] memory ids = _fulfill(round, entropy);
        assertEq(ids.length, count / 2);
        bool[] memory seen = new bool[](count + 1);
        uint256 staminaTotal;
        uint256 pointsTotal;
        for (uint256 i; i < ids.length; ++i) {
            MatchQueue.Race memory race = queue.matchInfo(ids[i]);
            assertFalse(seen[race.a.tokenId]);
            seen[race.a.tokenId] = true;
            assertFalse(seen[race.b.tokenId]);
            seen[race.b.tokenId] = true;
            assertTrue(race.a.player != race.b.player);
            assertEq(race.a.stamina, 10);
            assertEq(race.b.stamina, 10);
            assertTrue(race.winner == race.a.tokenId || race.winner == race.b.tokenId);
            if (race.scoreA > race.scoreB) assertEq(race.winner, race.a.tokenId);
            if (race.scoreB > race.scoreA) assertEq(race.winner, race.b.tokenId);
            queue.settleMatch(ids[i]);
        }
        for (uint256 i; i < count; ++i) {
            assertTrue(seen[i + 1]);
            staminaTotal += nft.hamster(i + 1).stamina;
            pointsTotal += queue.points(players[i]);
            assertEq(nft.matchesThisWeek(i + 1), 1);
        }
        assertEq(staminaTotal, 10 * count + 4 * (count / 2));
        assertEq(pointsTotal, 12 * (count / 2));
        assertEq(queue.totalPoints(), pointsTotal);
    }

    function test_fulfillmentCallerAndTimestampCannotChooseResult() public {
        uint256 a = _mintFed(alice, 0);
        uint256 b = _mintFed(bob, 0);
        uint256 round = _pair(alice, a, bob, b);
        _readyRound(round, keccak256("fixed future hash"));
        uint256 saved = vm.snapshotState();
        vm.prank(alice);
        queue.fulfillRound(round);
        bytes32 first = keccak256(abi.encode(queue.matchInfo(1)));
        assertTrue(vm.revertToState(saved));
        vm.warp(block.timestamp + 12 days);
        vm.prank(bob);
        queue.fulfillRound(round);
        assertEq(keccak256(abi.encode(queue.matchInfo(1))), first);
    }

    function test_futureEntropyActuallyChangesPairingForLargerRoster() public {
        for (uint256 i; i < 8; ++i) {
            address player = makeAddr(string.concat("random pair player", vm.toString(i)));
            vm.deal(player, 1 ether);
            _enqueue(player, _mintFed(player, 0));
        }
        _waitQueueWindow();
        uint256 round = queue.requestRound(0);
        (, uint256 target,,,,) = queue.roundInfo(round);
        vm.roll(target + 1);
        uint256 saved = vm.snapshotState();
        uint256 firstOpponent;
        bool different;
        for (uint256 attempt; attempt < 12; ++attempt) {
            assertTrue(vm.revertToState(saved));
            vm.setBlockhash(target, keccak256(abi.encode("future entropy", attempt)));
            queue.fulfillRound(round);
            uint256[] memory ids = queue.roundMatchIds(round);
            uint256 opponent;
            for (uint256 i; i < ids.length; ++i) {
                MatchQueue.Race memory race = queue.matchInfo(ids[i]);
                if (race.a.tokenId == 1) opponent = race.b.tokenId;
                if (race.b.tokenId == 1) opponent = race.a.tokenId;
            }
            assertGt(opponent, 1);
            if (attempt == 0) firstOpponent = opponent;
            else if (opponent != firstOpponent) different = true;
        }
        assertTrue(different, "entropy must change opponents, not just race noise");
    }
}
