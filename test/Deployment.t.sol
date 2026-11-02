// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { DeployHamsterRunNFT, DeployMatchQueue } from "../script/Deploy.s.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract LocalFactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract DeploymentTest is Test {
    address private constant LAUNCH_OWNER = address(bytes20(hex"6c14430adacc99e27f6180bc5a74d6768616bf4a"));

    function test_factoryDeploymentsHaveExplicitOwnerAndNoForbiddenRuntime() public {
        vm.chainId(11155111);
        LocalFactoryProbe factory = new LocalFactoryProbe();
        bytes memory nftCode = bytes.concat(
            type(HamsterRunNFT).creationCode,
            abi.encode(LAUNCH_OWNER, 0x74665dAecA35A2303e767E76a2FF1FB6F93e119f)
        );
        HamsterRunNFT nft = HamsterRunNFT(factory.deploy(nftCode, keccak256("NFT")));
        bytes memory queueCode = bytes.concat(type(MatchQueue).creationCode, abi.encode(address(nft)));
        MatchQueue queue = MatchQueue(factory.deploy(queueCode, keccak256("QUEUE")));
        assertEq(nft.owner(), LAUNCH_OWNER);
        assertTrue(nft.owner() != address(factory));
        assertTrue(nft.owner() != tx.origin);
        assertEq(address(queue.nft()), address(nft));
        assertEq(nft.matchQueue(), address(0));
        _checkRuntime(address(nft));
        _checkRuntime(address(queue));
        assertLe(nftCode.length, 49_152);
        assertLe(queueCode.length, 49_152);
        vm.startPrank(LAUNCH_OWNER);
        nft.setMatchQueue(address(queue));
        nft.setFoodConfig(
            [uint256(0.0001 ether), 0.0002 ether, 0.0003 ether], [uint256(10_000), 15_000, 20_000]
        );
        nft.setMintOpen(true);
        vm.stopPrank();
        address player = makeAddr("deployment smoke player");
        vm.deal(player, 1 ether);
        vm.startPrank(player);
        uint256 id = nft.mint();
        nft.feed{ value: 0.0001 ether }(id, 0);
        queue.enqueue(id);
        vm.stopPrank();
    }

    function test_constructorsDoNotNeedDependenciesToExist() public {
        address futureNFT = makeAddr("not yet deployed nft");
        assertEq(futureNFT.code.length, 0);
        MatchQueue queue = new MatchQueue(futureNFT);
        assertEq(address(queue.nft()), futureNFT);
        vm.expectRevert(MatchQueue.InvalidNFT.selector);
        new MatchQueue(address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new HamsterRunNFT(address(0), futureNFT);
    }

    function test_scriptsUseArgumentsAndRejectOtherChains() public {
        DeployHamsterRunNFT nftScript = new DeployHamsterRunNFT();
        DeployMatchQueue queueScript = new DeployMatchQueue();
        vm.chainId(1);
        vm.expectRevert(DeployHamsterRunNFT.WrongChain.selector);
        nftScript.run(LAUNCH_OWNER);
        vm.expectRevert(DeployMatchQueue.WrongChain.selector);
        queueScript.run(makeAddr("nft"));
        vm.chainId(11155111);
        vm.prank(makeAddr("arbitrary script caller"));
        HamsterRunNFT nft = nftScript.run(LAUNCH_OWNER);
        MatchQueue queue = queueScript.run(address(nft));
        assertEq(nft.owner(), LAUNCH_OWNER);
        assertEq(address(queue.nft()), address(nft));
        assertFalse(nft.mintOpen());
    }

    function _checkRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                reachable = false;
            }
        }
    }
}
