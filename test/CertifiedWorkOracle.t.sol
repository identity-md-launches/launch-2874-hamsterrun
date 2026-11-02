// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { GameTest } from "./helpers/GameTest.sol";
import { MockSqueekCore } from "./helpers/MockSqueekCore.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { CoreReader } from "../src/CoreReader.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, GameMath } from "../src/GameMath.sol";

/// @notice Training settlement checked against an oracle that never asks the NFT or Core's page reader:
///         the test keeps its own per-round work ledger and sums the booked six rounds itself.
contract CertifiedWorkOracleTest is GameTest {
    mapping(uint64 => uint64) internal ledger;

    function _roundEnd(uint64 round) internal view returns (uint256) {
        return uint256(core.configuration().genesisTimestamp) + uint256(round) * 600;
    }

    /// @dev Certify rounds (frontier, through] with seeded sparse work, mirroring it in `ledger`.
    function _certifySparse(uint64 through, uint256 seed) internal {
        if (vm.getBlockTimestamp() < _roundEnd(through)) vm.warp(_roundEnd(through));
        uint64 from = core.state().settledThroughRound + 1;
        uint256 n;
        uint64[] memory rounds = new uint64[](16);
        uint64[] memory works = new uint64[](16);
        for (uint64 r = from; r <= through && n < 16; ++r) {
            uint256 h = uint256(keccak256(abi.encode(seed, r)));
            if (h % 3 == 0) continue; // a certified zero-work round: no record at all
            uint64 w = uint64(1 + (h >> 8) % 1000);
            rounds[n] = r;
            works[n] = w;
            ledger[r] = w;
            ++n;
        }
        assembly {
            mstore(rounds, n)
            mstore(works, n)
        }
        core.certifyBatch(through, rounds, works);
    }

    function _oracleWork(uint64 start, uint64 end) internal view returns (uint256 sum) {
        for (uint64 r = start; r <= end; ++r) {
            sum += ledger[r];
        }
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_settledGainEqualsIndependentLedgerSum(
        uint256 workSeed,
        uint16 roundsAheadSeed,
        uint16 phaseSeed,
        uint8 tierSeed,
        uint8 backlogSeed
    ) public {
        uint8 tier = tierSeed % 3;
        // Certify some backlog before booking: none of it may leak into the window.
        uint64 backlog = uint64(bound(backlogSeed, 0, 10));
        if (backlog != 0) _certifySparse(backlog, workSeed ^ 1);
        vm.warp(vm.getBlockTimestamp() + bound(roundsAheadSeed, 0, 50) * 600 + bound(phaseSeed, 0, 599));
        uint256 id = _mintFed(alice, tier);
        vm.prank(alice);
        nft.startTraining(id);
        (uint64 start, uint64 end, uint256 bps,) = nft.training(id);
        assertEq(end - start, 5);
        assertEq(start, uint64((vm.getBlockTimestamp() - core.configuration().genesisTimestamp) / 600 + 1));
        // Certify through the window and a few rounds after it, in at most 16-record batches.
        uint64 frontier = core.state().settledThroughRound;
        while (frontier < end + 4) {
            uint64 next = frontier + 12 > end + 4 ? end + 4 : frontier + 12;
            _certifySparse(next, workSeed);
            frontier = next;
        }
        uint256 expected = _oracleWork(start, end) * 2 * bps / 10_000;
        assertEq(nft.certifiedWork(start, end), _oracleWork(start, end));
        assertEq(nft.previewTrainingGain(id), expected);
        vm.prank(keeper);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 10 + expected);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Idle));
    }

    function test_frontierExactlyAtEndSettlesAndOneShortDoesNot() public {
        uint256 id = _mintFed(alice, 1);
        vm.prank(alice);
        nft.startTraining(id);
        (, uint64 end,,) = nft.training(id);
        _certifySparse(end - 1, 7);
        vm.expectRevert(abi.encodeWithSelector(CoreReader.CoreCertificationLag.selector, end - 1, end));
        nft.settleTraining(id);
        HamsterRunNFT.TrainingStatus memory status = nft.trainingStatus(id);
        assertTrue(status.waitingForCertification);
        assertEq(status.frontier, end - 1);
        _certifySparse(end, 7);
        status = nft.trainingStatus(id);
        assertTrue(status.ready);
        assertFalse(status.waitingForCertification);
        nft.settleTraining(id);
    }

    function test_settleIsOnceOnlyAndCancelledBookingsCannotBeSettled() public {
        uint256 id = _mintFed(alice, 2);
        vm.prank(alice);
        nft.startTraining(id);
        (, uint64 end,,) = nft.training(id);
        _certifySparse(end, 3);
        nft.settleTraining(id);
        uint256 stamina = nft.hamster(id).stamina;
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(id);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.cancelTraining(id);
        assertEq(nft.hamster(id).stamina, stamina);

        // A cancelled window over already-certified, nonzero work stays unpaid.
        uint256 id2 = _mintFed(bob, 2);
        vm.prank(bob);
        nft.startTraining(id2);
        (, uint64 end2,,) = nft.training(id2);
        vm.warp(_roundEnd(end2));
        core.certify(end2, 500);
        vm.prank(bob);
        nft.cancelTraining(id2);
        (uint64 s, uint64 e, uint256 b, uint8 t) = nft.training(id2);
        assertEq(s + e + b + t, 0);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(id2);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.previewTrainingGain(id2);
        assertEq(nft.hamster(id2).stamina, 10);
    }

    function test_onlyTheHolderStartsOrCancelsNotOperatorsOrStrangers() public {
        uint256 id = _mintFed(alice, 0);
        vm.startPrank(alice);
        nft.setApprovalForAll(bob, true);
        nft.approve(carol, id);
        vm.stopPrank();
        address[3] memory others = [bob, carol, keeper];
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
            nft.startTraining(id);
        }
        vm.prank(alice);
        nft.startTraining(id);
        for (uint256 i; i < 3; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
            nft.cancelTraining(id);
        }
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Training));
    }

    function test_nonexistentTokenCannotBeBookedSettledOrPreviewed() public {
        vm.expectRevert();
        nft.startTraining(77);
        vm.expectRevert();
        nft.settleTraining(77);
        vm.expectRevert();
        nft.cancelTraining(77);
        vm.expectRevert();
        nft.previewTrainingGain(77);
        vm.expectRevert();
        nft.trainingStatus(77);
    }

    function test_hungryBoundaryForBooking() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        nft.startTraining(id); // a never-fed newborn is hungry
        _feed(alice, id, 1);
        uint256 fedUntil = nft.hamster(id).fedUntil;
        vm.warp(fedUntil + 1);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        nft.startTraining(id);
        assertEq(nft.ownerOf(id), alice, "hunger never burns");
        vm.warp(fedUntil); // exact expiry is still fed
        vm.prank(alice);
        nft.startTraining(id);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Training));
    }

    function test_trainingAndQueueLocksExcludeEachOther() public {
        uint256 id = _mintFed(alice, 2);
        vm.prank(alice);
        nft.startTraining(id);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(id);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        queue.enqueue(id);
        assertEq(queue.activeToken(alice), 0);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.feed{ value: 0.0003 ether }(id, 2);

        uint256 other = _mintFed(bob, 2);
        _enqueue(bob, other);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.startTraining(other);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.settleTraining(other);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.NoTraining.selector);
        nft.cancelTraining(other);
    }

    function test_mintFeedTrainSettleThenRaceEndToEnd() public {
        uint256 a = _mintFed(alice, 2);
        uint256 b = _mintFed(bob, 0);
        vm.prank(alice);
        nft.startTraining(a);
        vm.prank(bob);
        nft.startTraining(b);
        (, uint64 end,,) = nft.training(a);
        vm.warp(_roundEnd(end));
        core.certify(end, 3); // small enough that both pets stay in band 0 and can race each other
        nft.settleTraining(a);
        nft.settleTraining(b);
        assertEq(nft.hamster(a).stamina, 22);
        assertEq(nft.hamster(b).stamina, 16);
        assertEq(queue.bandOf(a), queue.bandOf(b));
        _feed(alice, a, 2);
        _feed(bob, b, 0);
        uint256 round = _pair(alice, a, bob, b);
        uint256[] memory ids = _fulfill(round, keccak256("e2e"));
        assertEq(ids.length, 1);
        queue.settleMatch(ids[0]);
        MatchQueue.Race memory race = queue.matchInfo(ids[0]);
        assertEq(race.a.stamina + race.b.stamina, 38, "race used the certified-work stamina");
        assertEq(nft.hamster(a).stamina + nft.hamster(b).stamina, 42);
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Idle));
        assertEq(uint256(nft.hamster(b).activity), uint256(Activity.Idle));
        assertEq(queue.totalPoints(), 12);
    }

    function testFuzz_settleTimingAndCallerNeverChangeStamina(uint32 delaySeed, address caller) public {
        uint256 id = _mintFed(alice, 1);
        vm.prank(alice);
        nft.startTraining(id);
        (uint64 start, uint64 end,,) = nft.training(id);
        _certifySparse(end, 99);
        vm.warp(vm.getBlockTimestamp() + bound(delaySeed, 0, 400 days));
        vm.prank(caller);
        nft.settleTraining(id);
        assertEq(nft.hamster(id).stamina, 10 + 3 * _oracleWork(start, end));
        assertEq(nft.ownerOf(id), alice);
    }
}

/// @notice Drives several pets through booking, sparse certification, settlement and cancellation
///         against a ghost per-round ledger the handler keeps for itself.
contract TrainingOracleHandler is Test {
    HamsterRunNFT public immutable nft;
    MockSqueekCore public immutable core;
    address public immutable gameOwner;
    address[6] public players;

    mapping(uint64 => uint64) public ledger;
    mapping(uint256 => uint256) public expectedStamina;
    mapping(uint256 => uint64) public lastCreditedEnd;
    uint256 public paid;
    uint256 public withdrawn;
    uint256 public settlements;
    uint256 public positiveSettlements;
    uint256 public cancels;
    uint256 public lagReverts;
    bool public doubleCredit;

    constructor(HamsterRunNFT nft_, MockSqueekCore core_, address owner_, address[6] memory players_) {
        nft = nft_;
        core = core_;
        gameOwner = owner_;
        players = players_;
        for (uint256 id = 1; id <= 6; ++id) {
            expectedStamina[id] = 10;
        }
    }

    function feed(uint256 petSeed, uint8 tierSeed) external {
        uint256 id = 1 + petSeed % 6;
        if (nft.hamster(id).activity != Activity.Idle) return;
        uint8 tier = tierSeed % 3;
        uint256 price = nft.foodPrices(tier);
        vm.deal(players[id - 1], price);
        vm.prank(players[id - 1]);
        nft.feed{ value: price }(id, tier);
        paid += price;
    }

    function start(uint256 petSeed) external {
        uint256 id = 1 + petSeed % 6;
        if (nft.hamster(id).activity != Activity.Idle || nft.isHungry(id)) return;
        vm.prank(players[id - 1]);
        nft.startTraining(id);
        (uint64 s, uint64 e,,) = nft.training(id);
        // A new booking always lies wholly after anything already credited to this pet.
        if (s <= lastCreditedEnd[id] || e != s + 5) doubleCredit = true;
    }

    function certify(uint256 seed, uint8 spanSeed) external {
        uint64 genesis = core.configuration().genesisTimestamp;
        uint64 ended = uint64((vm.getBlockTimestamp() - genesis) / 600);
        uint64 frontier = core.state().settledThroughRound;
        if (ended <= frontier) return;
        uint64 through = frontier + 1 + uint64(spanSeed % 16);
        if (through > ended) through = ended;
        uint64[] memory rounds = new uint64[](16);
        uint64[] memory works = new uint64[](16);
        uint256 n;
        for (uint64 r = frontier + 1; r <= through; ++r) {
            uint256 h = uint256(keccak256(abi.encode(seed, r)));
            if (h % 2 == 0) continue;
            rounds[n] = r;
            works[n] = uint64(1 + (h >> 8) % 500);
            ledger[r] = works[n];
            ++n;
        }
        assembly {
            mstore(rounds, n)
            mstore(works, n)
        }
        core.certifyBatch(through, rounds, works);
    }

    function settle(uint256 petSeed, address caller) external {
        uint256 id = 1 + petSeed % 6;
        if (nft.hamster(id).activity != Activity.Training) return;
        (uint64 s, uint64 e, uint256 bps,) = nft.training(id);
        if (core.state().settledThroughRound < e) {
            vm.prank(caller);
            try nft.settleTraining(id) {
                doubleCredit = true; // settling before certification must never succeed
            } catch {
                ++lagReverts;
            }
            return;
        }
        uint256 work;
        for (uint64 r = s; r <= e; ++r) {
            work += ledger[r];
        }
        vm.prank(caller);
        nft.settleTraining(id);
        expectedStamina[id] += work * 2 * bps / 10_000;
        lastCreditedEnd[id] = e;
        ++settlements;
        if (work != 0) ++positiveSettlements;
    }

    function cancel(uint256 petSeed) external {
        uint256 id = 1 + petSeed % 6;
        if (nft.hamster(id).activity != Activity.Training) return;
        vm.prank(players[id - 1]);
        nft.cancelTraining(id);
        ++cancels;
    }

    function advance(uint32 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + uint256(secondsSeed) % 2 days);
    }

    function withdraw(uint256 seed) external {
        uint256 balance = address(nft).balance;
        if (balance == 0) return;
        uint256 amount = 1 + seed % balance;
        vm.prank(gameOwner);
        nft.withdraw(amount);
        withdrawn += amount;
    }
}

contract TrainingOracleInvariantTest is GameTest {
    TrainingOracleHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[6] memory players;
        for (uint256 i; i < 6; ++i) {
            players[i] = makeAddr(string.concat("oracle player", vm.toString(i)));
            _mint(players[i]);
        }
        handler = new TrainingOracleHandler(nft, core, owner, players);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.feed.selector;
        selectors[1] = handler.start.selector;
        selectors[2] = handler.certify.selector;
        selectors[3] = handler.settle.selector;
        selectors[4] = handler.cancel.selector;
        selectors[5] = handler.advance.selector;
        selectors[6] = handler.withdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    /// @dev The invariants above are only meaningful if the handler's branches are reached at all.
    function test_seededWalkReachesLagSettleAndCancel() public {
        for (uint256 step; step < 400; ++step) {
            uint256 h = uint256(keccak256(abi.encode("walk", step)));
            uint256 action = h % 7;
            if (action == 0) handler.feed(h >> 8, uint8(h >> 16));
            else if (action == 1) handler.start(h >> 8);
            else if (action == 2) handler.certify(h >> 8, uint8(h >> 24));
            else if (action == 3) handler.settle(h >> 8, address(uint160(h >> 32)));
            else if (action == 4 && h % 5 == 0) handler.cancel(h >> 8);
            else if (action == 5) handler.advance(uint32(h >> 40) % 3 hours);
            else if (action == 6) handler.withdraw(h >> 8);
            invariant_staminaIsExactlyCertifiedLedgerWorkTimesFood();
            invariant_feeRevenueIsConserved();
            invariant_bookingRecordMatchesTrainingLockAndStatus();
        }
        assertGt(handler.settlements(), 0, "no settlement reached");
        assertGt(handler.positiveSettlements(), 0, "no positive-work settlement reached");
        assertGt(handler.lagReverts(), 0, "no certification-lag revert reached");
        assertGt(handler.cancels(), 0, "no cancellation reached");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_staminaIsExactlyCertifiedLedgerWorkTimesFood() public view {
        for (uint256 id = 1; id <= 6; ++id) {
            assertEq(nft.hamster(id).stamina, handler.expectedStamina(id));
        }
        assertFalse(handler.doubleCredit());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feeRevenueIsConserved() public view {
        assertEq(address(nft).balance + handler.withdrawn(), handler.paid());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_bookingRecordMatchesTrainingLockAndStatus() public view {
        uint64 frontier = core.state().settledThroughRound;
        for (uint256 id = 1; id <= 6; ++id) {
            HamsterRunNFT.Hamster memory ham = nft.hamster(id);
            (uint64 s, uint64 e, uint256 bps, uint8 tier) = nft.training(id);
            HamsterRunNFT.TrainingStatus memory status = nft.trainingStatus(id);
            assertLe(ham.bodyScore, 100);
            assertEq(uint256(ham.weight), uint256(GameMath.weightClass(ham.bodyScore)));
            if (ham.activity == Activity.Training) {
                assertTrue(status.active);
                assertEq(e, s + 5);
                assertGt(s, 0);
                assertEq(bps, 10_000 + uint256(tier) * 5000);
                assertEq(status.ready, frontier >= e);
                assertEq(status.waitingForCertification, !status.ready);
                assertEq(status.frontier, frontier);
            } else {
                assertEq(uint256(ham.activity), uint256(Activity.Idle));
                assertFalse(status.active);
                assertEq(uint256(s) + e + bps + tier, 0);
            }
            assertEq(nft.ownerOf(id), handler.players(id - 1));
        }
    }
}
