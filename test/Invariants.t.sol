// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest } from "./helpers/GameTest.sol";
import { MockSqueekCore } from "./helpers/MockSqueekCore.sol";
import { ISqueekCore } from "../src/interfaces/ISqueekCore.sol";
import { Test } from "forge-std/Test.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, GameMath } from "../src/GameMath.sol";

contract GameHandler is Test {
    HamsterRunNFT public immutable nft;
    MatchQueue public immutable queue;
    address public immutable gameOwner;
    address[8] public players;
    uint256 public paid;
    uint256 public withdrawn;
    uint256 public totalTrainingGain;
    uint256 public settledRaces;
    uint256 public byes;
    mapping(address => uint256) public expectedPoints;
    mapping(uint256 => uint256) public expectedStamina;

    constructor(HamsterRunNFT nft_, MatchQueue queue_, address owner_, address[8] memory players_) {
        nft = nft_;
        queue = queue_;
        gameOwner = owner_;
        players = players_;
        for (uint256 i; i < 8; ++i) {
            expectedStamina[i + 1] = 10;
        }
        paid = 8 * 0.0001 ether;
    }

    function feed(uint256 seed, uint8 tierSeed) external {
        uint256 id = 1 + seed % 8;
        Activity activity = nft.hamster(id).activity;
        if (activity != Activity.Idle && activity != Activity.Training) return;
        uint8 tier = tierSeed % 3;
        uint256 price = nft.foodPrices(tier);
        vm.prank(players[id - 1]);
        nft.feed{ value: price }(id, tier);
        paid += price;
    }

    function trainOrClaim(uint256 seed) external {
        uint256 id = 1 + seed % 8;
        HamsterRunNFT.Hamster memory ham = nft.hamster(id);
        if (ham.activity == Activity.Idle && !nft.isHungry(id)) {
            vm.prank(players[id - 1]);
            nft.startTraining(id);
        } else if (ham.activity == Activity.Training) {
            (uint64 start, uint64 end, uint256 bps,) = nft.training(id);
            if (nft.core().state().settledThroughRound < end) return;
            ISqueekCore.RoundPage memory page = nft.core().roundPage(start - 1, end, 6);
            uint256 gain = uint256(page.end.cumulativeWork - page.start.cumulativeWork) * 2 * bps / 10_000;
            nft.settleTraining(id);
            totalTrainingGain += gain;
            expectedStamina[id] += gain;
        }
    }

    function cancelTraining(uint256 seed) external {
        uint256 id = 1 + seed % 8;
        if (nft.hamster(id).activity != Activity.Training) return;
        vm.prank(players[id - 1]);
        nft.cancelTraining(id);
    }

    function enqueueOrLeave(uint256 seed) external {
        uint256 id = 1 + seed % 8;
        Activity activity = nft.hamster(id).activity;
        if (activity == Activity.Queued) {
            vm.prank(players[id - 1]);
            queue.leaveQueue(id);
        } else if (activity == Activity.Idle && !nft.isHungry(id) && nft.matchesThisWeek(id) < 5) {
            vm.prank(players[id - 1]);
            queue.enqueue(id);
        }
    }

    function advance(uint32 secondsSeed, uint16 blocksSeed) external {
        vm.warp(vm.getBlockTimestamp() + uint256(secondsSeed) % 4 days);
        vm.roll(vm.getBlockNumber() + uint256(blocksSeed) % 400);
        uint64 ended = uint64((vm.getBlockTimestamp() - nft.core().configuration().genesisTimestamp) / 600);
        if (ended > nft.core().state().settledThroughRound && secondsSeed % 2 == 0) {
            MockSqueekCore(address(nft.core())).certify(ended, uint64(secondsSeed % 31));
        }
    }

    function request(uint256 seed) external {
        uint256 band = queue.bandOf(1 + seed % 8);
        MatchQueue.Entry[] memory entries = queue.queueEntries(band);
        uint256 live;
        for (uint256 i; i < entries.length; ++i) {
            if (
                !nft.isHungry(entries[i].tokenId)
                    && vm.getBlockTimestamp() <= entries[i].joinedAt + queue.QUEUE_TTL()
                    && vm.getBlockNumber() >= entries[i].joinedBlock + queue.QUEUE_WAIT_BLOCKS()
            ) ++live;
        }
        assertEq(live, queue.eligibleCount(band));
        if (live >= 2) queue.requestRound(band);
    }

    function resolve(uint256 seed) external {
        if (queue.roundCount() == 0) return;
        uint256 round = 1 + seed % queue.roundCount();
        (, uint256 target,, MatchQueue.RoundStatus status,,) = queue.roundInfo(round);
        if (status == MatchQueue.RoundStatus.Pending) {
            if (vm.getBlockNumber() <= target) return;
            if (vm.getBlockNumber() > target + 256) {
                queue.expireRound(round);
            } else {
                vm.setBlockhash(target, keccak256(abi.encode("mock future block", target)));
                queue.fulfillRound(round);
                uint256 bye = queue.roundBye(round);
                if (bye != 0) {
                    ++byes;
                    assertEq(uint256(nft.hamster(bye).activity), uint256(Activity.Idle));
                    assertEq(queue.roundRacers(round).length % 2, 1);
                }
            }
        } else if (status == MatchQueue.RoundStatus.Fulfilled) {
            uint256[] memory ids = queue.roundMatchIds(round);
            uint256 matchId = ids[seed % ids.length];
            MatchQueue.Race memory race = queue.matchInfo(matchId);
            if (race.settled) return;
            queue.settleMatch(matchId);
            bool aWon = race.winner == race.a.tokenId;
            expectedPoints[race.a.player] += aWon ? 10 : 2;
            expectedPoints[race.b.player] += aWon ? 2 : 10;
            expectedStamina[race.a.tokenId] += aWon ? 3 : 1;
            expectedStamina[race.b.tokenId] += aWon ? 1 : 3;
            ++settledRaces;
        }
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

contract GameInvariantTest is GameTest {
    GameHandler private handler;

    function setUp() public override {
        super.setUp();
        address[8] memory players;
        for (uint256 i; i < 8; ++i) {
            players[i] = makeAddr(string.concat("invariant player", vm.toString(i)));
            vm.deal(players[i], 100 ether);
            _mintFed(players[i], 0);
        }
        handler = new GameHandler(nft, queue, owner, players);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.feed.selector;
        selectors[1] = handler.trainOrClaim.selector;
        selectors[2] = handler.cancelTraining.selector;
        selectors[3] = handler.enqueueOrLeave.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.request.selector;
        selectors[6] = handler.resolve.selector;
        selectors[7] = handler.withdraw.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_ethConservation() public view {
        assertEq(address(nft).balance + handler.withdrawn(), handler.paid());
        assertEq(address(queue).balance, 0);
    }

    function invariant_pointsAndStaminaHaveOnlyEarnedSources() public view {
        uint256 pointsTotal;
        uint256 staminaTotal;
        for (uint256 i; i < 8; ++i) {
            address player = handler.players(i);
            uint256 id = i + 1;
            assertEq(queue.points(player), handler.expectedPoints(player));
            assertEq(nft.hamster(id).stamina, handler.expectedStamina(id));
            pointsTotal += queue.points(player);
            staminaTotal += nft.hamster(id).stamina;
        }
        assertEq(queue.totalPoints(), pointsTotal);
        assertEq(pointsTotal, handler.settledRaces() * 12);
        assertEq(queue.totalPoints() % 12, 0); // a bye never earns points
        assertEq(staminaTotal, 80 + handler.totalTrainingGain() + handler.settledRaces() * 4);
    }

    function invariant_bodySupplyQuotaAndLocksStayConsistent() public view {
        assertEq(nft.totalSupply(), 8);
        for (uint256 id = 1; id <= 8; ++id) {
            HamsterRunNFT.Hamster memory ham = nft.hamster(id);
            assertLe(ham.bodyScore, 100);
            assertEq(uint256(ham.weight), uint256(GameMath.weightClass(ham.bodyScore)));
            assertGe(ham.stamina, 10);
            assertLe(nft.matchesThisWeek(id), 5);
            bool active = ham.activity == Activity.Queued || ham.activity == Activity.Matched;
            assertEq(queue.activeToken(nft.ownerOf(id)), active ? id : 0);
            (uint256 band, uint256 index) = queue.position(id);
            if (ham.activity == Activity.Queued) {
                assertGt(index, 0);
                MatchQueue.Entry[] memory entries = queue.queueEntries(band);
                assertLe(index, entries.length);
                assertEq(entries[index - 1].tokenId, id);
                assertEq(entries[index - 1].player, nft.ownerOf(id));
                assertEq(band, queue.bandForStamina(ham.stamina));
            } else {
                assertEq(index, 0);
            }
        }
    }
}
