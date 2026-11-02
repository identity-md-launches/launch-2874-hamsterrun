// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { HamsterRunNFT } from "../src/HamsterRunNFT.sol";
import { MatchQueue } from "../src/MatchQueue.sol";
import { Script } from "forge-std/Script.sol";

/// @notice Local deployment rehearsal, not a broadcaster. The network launches the two applications.
/// @dev Pass the launch owner's explicit address. No key, environment, filesystem or broadcast cheatcodes.
contract DeployHamsterRunNFT is Script {
    error WrongChain();
    address public constant SEPOLIA_CORE = 0x74665dAecA35A2303e767E76a2FF1FB6F93e119f;

    function run(address initialOwner) external returns (HamsterRunNFT nft) {
        if (block.chainid != 11155111) revert WrongChain();
        nft = new HamsterRunNFT(initialOwner, SEPOLIA_CORE);
    }
}

contract DeployMatchQueue is Script {
    error WrongChain();

    function run(address nftAddress) external returns (MatchQueue queue) {
        if (block.chainid != 11155111) revert WrongChain();
        queue = new MatchQueue(nftAddress);
        // After launch the owner binds this queue to the NFT, then sets prices/mintOpen.
    }
}
