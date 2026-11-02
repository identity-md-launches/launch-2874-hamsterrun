// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest } from "./helpers/GameTest.sol";
import {
    EagerReceiver,
    ForceSend,
    MintCallbackAttacker,
    NoNftGetter,
    QueueProbe,
    WrongNftGetter
} from "./helpers/Probes.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Activity, WeightClass } from "../src/GameMath.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice The NFT's own guards, driven through a queue double, plus custody, ETH and callback attacks.
contract NFTGuardsTest is GameTest {
    HamsterRunNFT private bound_;
    QueueProbe private probe;

    function setUp() public override {
        super.setUp();
        bound_ = new HamsterRunNFT(owner, address(core));
        probe = new QueueProbe(bound_);
        vm.startPrank(owner);
        bound_.setMatchQueue(address(probe));
        bound_.setMintOpen(true);
        vm.stopPrank();
    }

    function _boundPet(address player) private returns (uint256 id) {
        vm.prank(player);
        id = bound_.mint();
        uint256 price = bound_.foodPrices(0);
        vm.prank(player);
        bound_.feed{ value: price }(id, 0);
    }

    function _activity(uint256 id) private view returns (Activity) {
        return bound_.hamster(id).activity;
    }

    // ---------------------------------------------------------------- queue-only state machine

    function test_everyQueueMethodFailsBeforeBinding() public {
        HamsterRunNFT fresh = new HamsterRunNFT(owner, address(core));
        vm.prank(owner);
        uint256 id = fresh.ownerMint(alice);
        vm.startPrank(owner);
        vm.expectRevert(HamsterRunNFT.QueueNotConfigured.selector);
        fresh.lockQueue(id, alice);
        vm.expectRevert(HamsterRunNFT.QueueNotConfigured.selector);
        fresh.lockMatch(id);
        vm.expectRevert(HamsterRunNFT.QueueNotConfigured.selector);
        fresh.unlockQueue(id);
        vm.expectRevert(HamsterRunNFT.QueueNotConfigured.selector);
        fresh.expireMatchLock(id);
        vm.expectRevert(HamsterRunNFT.QueueNotConfigured.selector);
        fresh.rewardMatch(id, true);
        vm.stopPrank();
    }

    function test_lockQueueGuards() public {
        uint256 id = _boundPet(alice);
        vm.expectRevert(HamsterRunNFT.NotTokenOwner.selector);
        probe.lockQueue(id, bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        probe.lockQueue(99, alice);

        vm.warp(bound_.hamster(id).fedUntil + 1);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        probe.lockQueue(id, alice);

        vm.prank(alice);
        bound_.feed{ value: 0.0001 ether }(id, 0);
        probe.lockQueue(id, alice);
        assertEq(uint256(_activity(id)), uint256(Activity.Queued));
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        probe.lockQueue(id, alice);
    }

    function test_lockQueueRefusesATrainingPet() public {
        uint256 id = _boundPet(alice);
        vm.prank(alice);
        bound_.startTraining(id);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        probe.lockQueue(id, alice);
    }

    function test_lockMatchGuardsAndReturnsTheLiveSnapshot() public {
        uint256 id = _boundPet(alice);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.lockMatch(id);
        probe.lockQueue(id, alice);
        (address player, uint256 stamina, WeightClass weight) = probe.lockMatch(id);
        assertEq(player, alice);
        assertEq(stamina, 10);
        assertEq(uint256(weight), uint256(WeightClass.Normal));

        uint256 hungry = _boundPet(bob);
        probe.lockQueue(hungry, bob);
        vm.warp(bound_.hamster(hungry).fedUntil + 1);
        vm.expectRevert(HamsterRunNFT.Hungry.selector);
        probe.lockMatch(hungry);
        assertEq(uint256(_activity(hungry)), uint256(Activity.Queued));
    }

    function test_lockMatchAppliesNeglectBeforeTheSnapshot() public {
        uint256 id = _boundPet(alice);
        // A body of 46 Normal at enqueue, three idle days later is 31: Obese at the lock instant.
        probe.lockQueue(id, alice);
        assertEq(uint256(bound_.hamster(id).weight), uint256(WeightClass.Normal));
        vm.warp(bound_.hamster(id).fedUntil);
        assertEq(bound_.hamster(id).bodyScore, 31);
        (,, WeightClass weight) = probe.lockMatch(id);
        assertEq(uint256(weight), uint256(WeightClass.Obese));
    }

    function test_unlockExpireAndRewardOnlyAcceptTheirOwnActivity() public {
        uint256 id = _boundPet(alice);
        // Idle
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.unlockQueue(id);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.expireMatchLock(id);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.rewardMatch(id, true);
        // Queued
        probe.lockQueue(id, alice);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.expireMatchLock(id);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.rewardMatch(id, true);
        // Matched
        probe.lockMatch(id);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.unlockQueue(id);
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.lockMatch(id);
        // Nonexistent
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        probe.unlockQueue(99);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        probe.expireMatchLock(99);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        probe.rewardMatch(99, false);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 99));
        probe.lockMatch(99);
    }

    function test_rewardCreditsOnceAndOnlyTheDocumentedAmount() public {
        uint256 winner = _boundPet(alice);
        uint256 loser = _boundPet(bob);
        probe.lockQueue(winner, alice);
        probe.lockMatch(winner);
        probe.lockQueue(loser, bob);
        probe.lockMatch(loser);
        probe.rewardMatch(winner, true);
        probe.rewardMatch(loser, false);
        assertEq(bound_.hamster(winner).stamina, 13);
        assertEq(bound_.hamster(loser).stamina, 11);
        assertEq(uint256(_activity(winner)), uint256(Activity.Idle));
        vm.expectRevert(HamsterRunNFT.WrongActivity.selector);
        probe.rewardMatch(winner, true);
    }

    function test_quotaCountsLocksNotEntriesAndResetsOnlyOnANewWeek() public {
        uint256 id = _boundPet(alice);
        uint256 week = block.timestamp / 1 weeks;
        for (uint256 i; i < 5; ++i) {
            probe.lockQueue(id, alice);
            probe.unlockQueue(id); // waiting and leaving spends nothing
            assertEq(bound_.matchesThisWeek(id), i);
            probe.lockQueue(id, alice);
            probe.lockMatch(id);
            assertEq(bound_.matchesThisWeek(id), i + 1);
            probe.expireMatchLock(id); // an expired attempt keeps its charge
            assertEq(bound_.matchesThisWeek(id), i + 1);
        }
        vm.expectRevert(HamsterRunNFT.WeeklyQuotaExceeded.selector);
        probe.lockQueue(id, alice);

        // One second before the week turns the limit still holds; at the turn it is gone.
        vm.warp((week + 1) * 1 weeks - 1);
        vm.prank(alice);
        bound_.feed{ value: 0.0001 ether }(id, 0);
        vm.expectRevert(HamsterRunNFT.WeeklyQuotaExceeded.selector);
        probe.lockQueue(id, alice);
        vm.warp((week + 1) * 1 weeks);
        assertEq(bound_.matchesThisWeek(id), 0);
        (uint256 storedWeek, uint256 storedUsed) = bound_.matchQuota(id);
        assertEq(storedWeek, week, "the stored counter is stale until the next lock");
        assertEq(storedUsed, 5);
        probe.lockQueue(id, alice);
        probe.lockMatch(id);
        (storedWeek, storedUsed) = bound_.matchQuota(id);
        assertEq(storedWeek, week + 1);
        assertEq(storedUsed, 1);
    }

    function test_petEnteredOnItsLastAttemptCanStillLockAfterTheWeekTurns() public {
        uint256 id = _boundPet(alice);
        uint256 week = block.timestamp / 1 weeks;
        for (uint256 i; i < 4; ++i) {
            probe.lockQueue(id, alice);
            probe.lockMatch(id);
            probe.expireMatchLock(id);
        }
        vm.warp((week + 1) * 1 weeks - 1);
        vm.prank(alice);
        bound_.feed{ value: 0.0001 ether }(id, 0);
        probe.lockQueue(id, alice);
        assertEq(bound_.matchesThisWeek(id), 4);
        vm.warp((week + 1) * 1 weeks);
        probe.lockMatch(id);
        assertEq(bound_.matchesThisWeek(id), 1, "the attempt is charged to the week it locks in");
    }

    // ---------------------------------------------------------------- binding

    function test_bindingRejectsEveryQueueThatDoesNotNameThisCollection() public {
        HamsterRunNFT fresh = new HamsterRunNFT(owner, address(core));
        address noGetter = address(new NoNftGetter());
        address wrongGetter = address(new WrongNftGetter());
        vm.startPrank(owner);
        vm.expectRevert(HamsterRunNFT.InvalidQueue.selector);
        fresh.setMatchQueue(address(0));
        vm.expectRevert(HamsterRunNFT.InvalidQueue.selector);
        fresh.setMatchQueue(owner);
        vm.expectRevert(HamsterRunNFT.InvalidQueue.selector);
        fresh.setMatchQueue(wrongGetter);
        vm.expectRevert();
        fresh.setMatchQueue(noGetter);
        vm.expectRevert();
        fresh.setMatchQueue(address(fresh));
        vm.stopPrank();
        assertEq(fresh.matchQueue(), address(0));
    }

    function test_boundQueueCanNeverBeReplacedEvenByOwnerOrNextOwner() public {
        QueueProbe other = new QueueProbe(bound_);
        vm.prank(owner);
        vm.expectRevert(HamsterRunNFT.QueueAlreadyConfigured.selector);
        bound_.setMatchQueue(address(other));
        vm.prank(owner);
        bound_.transferOwnership(alice);
        vm.prank(alice);
        bound_.acceptOwnership();
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.QueueAlreadyConfigured.selector);
        bound_.setMatchQueue(address(other));
        assertEq(bound_.matchQueue(), address(probe));
    }

    function test_aSecondQueueAimedAtABoundCollectionGetsNowhere() public {
        uint256 id = _mintFed(alice, 0);
        MatchQueue rogue = new MatchQueue(address(nft));
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        rogue.enqueue(id);
        assertEq(rogue.activeToken(alice), 0);
        assertEq(rogue.queueEntries(0).length, 0);
        (, uint256 index) = rogue.position(id);
        assertEq(index, 0);
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Idle));
        // The genuine queue still works for the same pet.
        _enqueue(alice, id);
        vm.prank(alice);
        vm.expectRevert(MatchQueue.NotQueued.selector);
        rogue.leaveQueue(id);
    }

    function test_directCallsFromNeitherOwnerNorPlayerCanMoveALockedPet() public {
        uint256 a = _mintFed(alice, 0);
        _enqueue(alice, a);
        address[3] memory callers = [owner, alice, keeper];
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
            nft.unlockQueue(a);
            vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
            nft.lockMatch(a);
            vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
            nft.rewardMatch(a, true);
            vm.stopPrank();
        }
        assertEq(uint256(nft.hamster(a).activity), uint256(Activity.Queued));
    }

    // ---------------------------------------------------------------- ETH

    function test_noContractAcceptsPlainEthAndNonpayableEntriesRefuseValue() public {
        uint256 id = _mintFed(alice, 0);
        uint256 nftBalance = address(nft).balance;
        vm.startPrank(alice);
        (bool ok,) = address(nft).call{ value: 1 }("");
        assertFalse(ok, "nft receive");
        (ok,) = address(nft).call{ value: 1 }(hex"deadbeef");
        assertFalse(ok, "nft fallback");
        (ok,) = address(queue).call{ value: 1 }("");
        assertFalse(ok, "queue receive");
        (ok,) = address(nft).call{ value: 1 }(abi.encodeCall(nft.startTraining, (id)));
        assertFalse(ok, "startTraining is not payable");
        (ok,) = address(queue).call{ value: 1 }(abi.encodeCall(queue.enqueue, (id)));
        assertFalse(ok, "enqueue is not payable");
        vm.stopPrank();
        vm.prank(bob);
        (ok,) = address(nft).call{ value: 1 }(abi.encodeCall(nft.mint, ()));
        assertFalse(ok, "mint is not payable");
        assertEq(address(nft).balance, nftBalance);
        assertEq(address(queue).balance, 0);
    }

    function test_forcedEthIsWithdrawableAndCreatesNoEntitlement() public {
        vm.deal(address(this), 1 ether);
        new ForceSend{ value: 1 ether }(payable(address(nft)));
        assertEq(address(nft).balance, 1 ether);
        vm.prank(owner);
        nft.withdraw(1 ether);
        assertEq(address(nft).balance, 0);
        assertEq(owner.balance, 1 ether);
    }

    function testFuzz_withdrawPaysExactlyTheRequestedAmountOrFails(uint256 requestSeed) public {
        _mintFed(alice, 2);
        _mintFed(bob, 0);
        uint256 fees = 0.0004 ether;
        uint256 request = bound(requestSeed, 0, fees * 2);
        vm.prank(owner);
        if (request == 0 || request > fees) {
            vm.expectRevert(HamsterRunNFT.InvalidWithdrawal.selector);
            nft.withdraw(request);
            assertEq(address(nft).balance, fees);
            assertEq(owner.balance, 0);
        } else {
            nft.withdraw(request);
            assertEq(address(nft).balance, fees - request);
            assertEq(owner.balance, request);
        }
    }

    function test_withdrawOnAnEmptyContractFails() public {
        vm.prank(owner);
        vm.expectRevert(HamsterRunNFT.InvalidWithdrawal.selector);
        nft.withdraw(1);
    }

    function test_feesFollowOwnershipOnlyAfterAcceptance() public {
        _mintFed(alice, 2);
        vm.prank(owner);
        nft.transferOwnership(carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        nft.withdraw(1);
        vm.prank(owner);
        nft.withdraw(1); // still the owner while the handover is pending
        assertEq(owner.balance, 1);
        vm.prank(carol);
        nft.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        nft.withdraw(1);
        vm.prank(carol);
        nft.withdraw(0.0003 ether - 1);
        assertEq(carol.balance, 100 ether + 0.0003 ether - 1);
    }

    function test_pendingHandoverCanBeCancelledWithTheZeroAddress() public {
        vm.prank(owner);
        nft.transferOwnership(carol);
        vm.prank(owner);
        nft.transferOwnership(address(0));
        assertEq(nft.pendingOwner(), address(0));
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        nft.acceptOwnership();
        assertEq(nft.owner(), owner, "a zero pending owner never becomes the owner");
    }

    function test_renounceFailsForEveryCallerAndChangesNothing() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.renounceOwnership();
        vm.prank(owner);
        vm.expectRevert(HamsterRunNFT.OwnershipRequired.selector);
        nft.renounceOwnership();
        assertEq(nft.owner(), owner);
    }

    function testFuzz_foodConfigAcceptedExactlyWhenStrictlyOrderedAndInBounds(
        uint256[3] memory prices,
        uint256[3] memory bps
    ) public {
        for (uint256 i; i < 3; ++i) {
            prices[i] = bound(prices[i], 0, 4);
        }
        // Small ranges, so every limit is straddled often: bps[0] around its floor, the middle one around
        // bps[0], the last one either around the middle one or around the ceiling.
        bps[0] = bound(bps[0], 9_999, 10_001);
        bps[1] = bound(bps[1], 14_999, 15_002);
        uint256 top = bps[2] % 4;
        bps[2] = top == 0 ? bps[1] : top == 1 ? bps[1] + 5000 : top == 2 ? 50_000 : 50_001;
        bool valid = prices[0] != 0 && prices[0] < prices[1] && prices[1] < prices[2] && bps[0] >= 10_000
            && bps[0] < bps[1] && bps[1] < bps[2] && bps[2] <= 50_000 && bps[1] - bps[0] >= 5000
            && bps[2] - bps[1] >= 5000;
        vm.prank(owner);
        if (valid) {
            nft.setFoodConfig(prices, bps);
            for (uint256 i; i < 3; ++i) {
                assertEq(nft.foodPrices(i), prices[i]);
                assertEq(nft.foodTrainBps(i), bps[i]);
            }
        } else {
            vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
            nft.setFoodConfig(prices, bps);
            assertEq(nft.foodPrices(0), 0.0001 ether);
            assertEq(nft.foodTrainBps(2), 20_000);
        }
    }

    // ---------------------------------------------------------------- callbacks

    function test_mintCallbackHitsTheGuardOnEveryGameEntry() public {
        MintCallbackAttacker attacker =
            new MintCallbackAttacker{ value: 1 ether }(nft, queue, makeAddr("attack sink"));
        attacker.attack(false);
        assertEq(attacker.attempts(), 4);
        assertEq(attacker.guardedCalls(), 4, "mint, feed, startTraining and enqueue");
        assertEq(nft.totalSupply(), 1);
        assertEq(address(nft).balance, 0, "the guarded feed took no ETH");
        assertEq(queue.queueEntries(0).length, 0);
        assertEq(queue.activeToken(address(attacker)), 0);
        assertEq(uint256(nft.hamster(1).activity), uint256(Activity.Idle));
    }

    function test_mintingContractThatMovesThePetAwayStillUsedItsAllocation() public {
        address sink = makeAddr("attack sink");
        MintCallbackAttacker attacker = new MintCallbackAttacker{ value: 1 ether }(nft, queue, sink);
        attacker.attack(true);
        assertEq(nft.ownerOf(1), sink);
        assertEq(nft.balanceOf(address(attacker)), 0);
        assertTrue(nft.freeMinted(address(attacker)));
        assertEq(nft.hamster(1).stamina, 10);
        vm.expectRevert(HamsterRunNFT.AlreadyMinted.selector);
        attacker.attack(true);
        assertEq(nft.totalSupply(), 1);
    }

    function test_receiverActingInsideASafeTransferStaysBoundByTheLock() public {
        uint256 id = _mint(alice);
        EagerReceiver receiver = new EagerReceiver{ value: 1 ether }(nft, queue);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(receiver), id);
        assertEq(nft.ownerOf(id), address(receiver));
        assertTrue(receiver.moveBackWhileQueuedFailed(), "a pet queued inside the callback is already locked");
        assertEq(uint256(nft.hamster(id).activity), uint256(Activity.Queued));
        assertEq(queue.activeToken(address(receiver)), id);
        assertEq(queue.activeToken(alice), 0);
        MatchQueue.Entry[] memory entries = queue.queueEntries(0);
        assertEq(entries.length, 1);
        assertEq(entries[0].player, address(receiver));
    }

    // ---------------------------------------------------------------- ERC-721 custody and metadata

    function test_approvalsSetDuringALockCannotMoveThePetUntilItUnlocks() public {
        uint256 a = _mintFed(alice, 0);
        _enqueue(alice, a);
        vm.prank(alice);
        nft.approve(carol, a);
        assertEq(nft.getApproved(a), carol);
        vm.startPrank(carol);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.transferFrom(alice, carol, a);
        vm.expectRevert(HamsterRunNFT.Locked.selector);
        nft.safeTransferFrom(alice, carol, a, "");
        vm.stopPrank();
        vm.prank(alice);
        queue.leaveQueue(a);
        vm.prank(carol);
        nft.transferFrom(alice, carol, a);
        assertEq(nft.ownerOf(a), carol);
        assertEq(nft.getApproved(a), address(0), "a completed transfer clears the approval");
    }

    function test_transferFailuresDoNotMoveThePet() public {
        uint256 id = _mint(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, bob, id));
        nft.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        nft.transferFrom(alice, address(0), id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721IncorrectOwner.selector, bob, id, alice));
        nft.transferFrom(bob, carol, id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(queue)));
        nft.safeTransferFrom(alice, address(queue), id);
        assertEq(nft.ownerOf(id), alice);
    }

    function test_tokenUriIsTheExactDocumentAndProjectsNeglect() public {
        uint256 id = _mintFed(alice, 2);
        uint256 fedUntil = nft.hamster(id).fedUntil;
        assertEq(nft.tokenURI(id), _uri(id, "Normal", 62, fedUntil));
        _feed(alice, id, 2);
        assertEq(nft.tokenURI(id), _uri(id, "Fit", 74, fedUntil));
        vm.warp(block.timestamp + 10 days);
        // Without a state touch: 74 - 50 idle - 35 hungry days reaches zero.
        assertEq(nft.tokenURI(id), _uri(id, "Obese", 0, fedUntil));
    }

    function _uri(uint256 id, string memory weight, uint256 score, uint256 fedUntil)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"hamsterrun #',
                        vm.toString(id),
                        '","description":"Independent Sepolia testnet game. No promised rewards or yield.",',
                        '"attributes":[{"trait_type":"Stamina","value":10},{"trait_type":"Weight","value":"',
                        weight,
                        '"},{"trait_type":"Body score","value":',
                        vm.toString(score),
                        '},{"trait_type":"Fed until","value":',
                        vm.toString(fedUntil),
                        "}]}"
                    )
                )
            )
        );
    }

    function test_mintWindowReopensButNeverRefundsTheAllocation() public {
        _mint(alice);
        vm.prank(owner);
        nft.setMintOpen(false);
        vm.prank(bob);
        vm.expectRevert(HamsterRunNFT.MintClosed.selector);
        nft.mint();
        vm.prank(owner);
        nft.setMintOpen(true);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.AlreadyMinted.selector);
        nft.mint();
        _mint(bob);
        assertEq(nft.totalSupply(), 2);
    }

    function test_ownerMintedPetsLeaveTheRecipientsFreeMintAvailable() public {
        vm.prank(owner);
        uint256 given = nft.ownerMint(alice);
        uint256 own = _mint(alice);
        assertEq(nft.balanceOf(alice), 2);
        assertEq(own, given + 1);
        assertEq(nft.hamster(given).stamina, nft.hamster(own).stamina);
    }
}
