// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GameTest } from "./helpers/GameTest.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC721Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MintReceiver is IERC721Receiver {
    HamsterRunNFT public immutable nft;
    bool public reject;
    bool public reentryFailed;

    constructor(HamsterRunNFT nft_) {
        nft = nft_;
    }

    function mint(bool reject_) external {
        reject = reject_;
        nft.mint();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!reject, "reject nft");
        try nft.mint() {
            revert("reentered mint");
        } catch (bytes memory reason) {
            reentryFailed = bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract FeeOwner {
    HamsterRunNFT public immutable nft;
    bool public reject;
    bool public reentryFailed;

    constructor(address coreAddress) {
        nft = new HamsterRunNFT(address(this), coreAddress);
    }

    function mintFor(address player) external returns (uint256) {
        return nft.ownerMint(player);
    }

    function withdraw(uint256 amount, bool reject_) external {
        reject = reject_;
        nft.withdraw(amount);
    }

    receive() external payable {
        require(!reject, "reject fee");
        try nft.withdraw(1) {
            revert("reentered withdrawal");
        } catch (bytes memory reason) {
            reentryFailed = bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
    }
}

/// @dev Batch only in the test fixture, to avoid 9998 top-level transaction snapshots in Forge 1.8.
contract SupplyFixture {
    function fill(HamsterRunNFT collection, address recipient, uint256 count) external {
        for (uint256 i; i < count; ++i) {
            collection.ownerMint(recipient);
        }
    }
}

contract NFTAdminTest is GameTest {
    function test_mintClosedByDefaultAndOnlyOwnerCanOpen() public {
        HamsterRunNFT fresh = new HamsterRunNFT(owner, address(core));
        assertFalse(fresh.mintOpen());
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.MintClosed.selector);
        fresh.mint();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setMintOpen(true);
        vm.prank(owner);
        fresh.setMintOpen(true);
        vm.prank(alice);
        fresh.mint();
    }

    function test_oneFreeMintPerWalletSurvivesTransfers() public {
        uint256 id = _mint(alice);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.AlreadyMinted.selector);
        nft.mint();
        _mint(bob);
        assertEq(nft.balanceOf(bob), 2);
        assertTrue(nft.freeMinted(alice));
        assertTrue(nft.freeMinted(bob));
    }

    function test_supplyExactly9999AcrossOwnerAndFreeMints() public {
        SupplyFixture fixture = new SupplyFixture();
        nft = new HamsterRunNFT(address(fixture), address(core));
        vm.prank(address(fixture));
        nft.setMintOpen(true);
        _mint(alice);
        // Bulk fixture represents thousands of separate mint transactions, not one on-chain batch.
        vm.pauseGasMetering();
        fixture.fill(nft, bob, 9998);
        vm.resumeGasMetering();
        assertEq(nft.totalSupply(), 9999);
        assertEq(nft.MAX_SUPPLY(), 9999);
        assertEq(nft.ownerOf(9999), bob);
        assertEq(nft.hamster(9999).stamina, 10);
        vm.prank(address(fixture));
        vm.expectRevert(HamsterRunNFT.SoldOut.selector);
        nft.ownerMint(bob);
        vm.prank(carol);
        vm.expectRevert(HamsterRunNFT.SoldOut.selector);
        nft.mint();
        assertFalse(nft.freeMinted(carol));
    }

    function test_ownerMintWorksWhileClosedButCannotMintToZero() public {
        vm.startPrank(owner);
        nft.setMintOpen(false);
        nft.ownerMint(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        nft.ownerMint(address(0));
        vm.stopPrank();
        assertEq(nft.totalSupply(), 1);
        assertFalse(nft.freeMinted(alice));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.ownerMint(alice);
    }

    function test_safeMintReceiverCannotReenterAndRejectionRollsBack() public {
        MintReceiver receiver = new MintReceiver(nft);
        vm.expectRevert(bytes("reject nft"));
        receiver.mint(true);
        assertEq(nft.totalSupply(), 0);
        assertFalse(nft.freeMinted(address(receiver)));
        receiver.mint(false);
        assertEq(nft.totalSupply(), 1);
        assertTrue(receiver.reentryFailed());
        assertEq(nft.ownerOf(1), address(receiver));
    }

    function test_erc721InterfacesMetadataAndApprovedTransfer() public {
        uint256 id = _mint(alice);
        assertEq(nft.name(), "hamsterrun");
        assertEq(nft.symbol(), "HMR");
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertTrue(nft.supportsInterface(0x5b5e139f));
        assertTrue(nft.supportsInterface(0x01ffc9a7));
        assertFalse(nft.supportsInterface(0xffffffff));
        string memory prefix = "data:application/json;base64,";
        bytes memory uri = bytes(nft.tokenURI(id));
        for (uint256 i; i < bytes(prefix).length; ++i) {
            assertEq(uri[i], bytes(prefix)[i]);
        }
        vm.prank(alice);
        nft.approve(bob, id);
        vm.prank(bob);
        nft.safeTransferFrom(alice, carol, id);
        assertEq(nft.ownerOf(id), carol);
        assertEq(nft.getApproved(id), address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        nft.tokenURI(999);
    }

    function test_adminConfigurationAccessAndBounds() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 20_000, 30_000]);
        vm.startPrank(owner);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(0), 2, 3], [uint256(10_000), 20_000, 30_000]);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(2), 2, 3], [uint256(10_000), 20_000, 30_000]);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(1), 3, 2], [uint256(10_000), 20_000, 30_000]);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(9999), 20_000, 30_000]);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 10_000, 30_000]);
        vm.expectRevert(HamsterRunNFT.InvalidFoodConfig.selector);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 20_000, 50_001]);
        nft.setFoodConfig([uint256(1), 2, 3], [uint256(10_000), 20_000, 50_000]);
        vm.stopPrank();
        uint256 id = _mintFed(alice, 2);
        assertEq(nft.hamster(id).trainBps, 50_000);
        assertEq(address(nft).balance, 3);
    }

    function test_ownershipUsesTwoStepAndCannotRenounce() public {
        assertEq(nft.owner(), owner);
        vm.prank(owner);
        nft.transferOwnership(alice);
        assertEq(nft.owner(), owner);
        assertEq(nft.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        nft.acceptOwnership();
        vm.prank(alice);
        nft.acceptOwnership();
        assertEq(nft.owner(), alice);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        nft.setMintOpen(false);
        vm.prank(alice);
        vm.expectRevert(HamsterRunNFT.OwnershipRequired.selector);
        nft.renounceOwnership();
    }

    function test_queueMustBeConfiguredOnceAndBoundToThisNFT() public {
        HamsterRunNFT fresh = new HamsterRunNFT(owner, address(core));
        MatchQueue next = new MatchQueue(address(fresh));
        vm.startPrank(owner);
        uint256 id = fresh.ownerMint(alice);
        vm.expectRevert(HamsterRunNFT.InvalidQueue.selector);
        fresh.setMatchQueue(alice);
        vm.expectRevert(HamsterRunNFT.InvalidQueue.selector);
        fresh.setMatchQueue(address(queue));
        vm.stopPrank();
        vm.startPrank(alice);
        fresh.feed{ value: 0.0001 ether }(id, 0);
        vm.expectRevert(HamsterRunNFT.QueueNotConfigured.selector);
        next.enqueue(id);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.setMatchQueue(address(next));
        vm.stopPrank();
        vm.prank(owner);
        fresh.setMatchQueue(address(next));
        vm.prank(alice);
        next.enqueue(id);
        vm.prank(owner);
        vm.expectRevert(HamsterRunNFT.QueueAlreadyConfigured.selector);
        fresh.setMatchQueue(address(next));
    }

    function test_queueOnlyMethodsRejectDirectUsersAndOwner() public {
        uint256 id = _mintFed(alice, 0);
        vm.startPrank(owner);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        nft.lockQueue(id, alice);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        nft.lockMatch(id);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        nft.unlockQueue(id);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        nft.expireMatchLock(id);
        vm.expectRevert(HamsterRunNFT.OnlyMatchQueue.selector);
        nft.rewardMatch(id, true);
        vm.stopPrank();
    }

    function test_withdrawConservesProceedsAndOnlyPaysOwner() public {
        _mintFed(alice, 2);
        _mintFed(bob, 1);
        uint256 fees = 0.0005 ether;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        nft.withdraw(fees);
        vm.startPrank(owner);
        vm.expectRevert(HamsterRunNFT.InvalidWithdrawal.selector);
        nft.withdraw(0);
        vm.expectRevert(HamsterRunNFT.InvalidWithdrawal.selector);
        nft.withdraw(fees + 1);
        uint256 before = owner.balance;
        nft.withdraw(fees / 2);
        assertEq(address(nft).balance, fees / 2);
        assertEq(owner.balance, before + fees / 2);
        nft.withdraw(fees / 2);
        assertEq(address(nft).balance, 0);
        assertEq(owner.balance, before + fees);
        vm.stopPrank();
    }

    function test_withdrawRejectingOwnerRollsBackAndReentryFails() public {
        FeeOwner receiver = new FeeOwner(address(core));
        HamsterRunNFT held = receiver.nft();
        uint256 id = receiver.mintFor(alice);
        vm.prank(alice);
        held.feed{ value: 0.0003 ether }(id, 2);
        vm.expectRevert(HamsterRunNFT.WithdrawalFailed.selector);
        receiver.withdraw(0.0003 ether, true);
        assertEq(address(held).balance, 0.0003 ether);
        receiver.withdraw(0.0003 ether, false);
        assertEq(address(held).balance, 0);
        assertEq(address(receiver).balance, 0.0003 ether);
        assertTrue(receiver.reentryFailed());
    }
}
