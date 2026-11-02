// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { HamsterRunNFT } from "../../src/HamsterRunNFT.sol";
import { MatchQueue } from "../../src/MatchQueue.sol";
import { WeightClass } from "../../src/GameMath.sol";

/// @dev Stands in for the bound queue so the NFT's own guards can be reached in orders MatchQueue never
///      produces. It forwards and lets every revert bubble.
contract QueueProbe {
    HamsterRunNFT public immutable nft;

    constructor(HamsterRunNFT nft_) {
        nft = nft_;
    }

    function lockQueue(uint256 id, address player) external {
        nft.lockQueue(id, player);
    }

    function lockMatch(uint256 id) external returns (address, uint256, WeightClass) {
        return nft.lockMatch(id);
    }

    function unlockQueue(uint256 id) external {
        nft.unlockQueue(id);
    }

    function expireMatchLock(uint256 id) external {
        nft.expireMatchLock(id);
    }

    function rewardMatch(uint256 id, bool won) external {
        nft.rewardMatch(id, won);
    }
}

/// @dev Has code but no nft() getter.
contract NoNftGetter { }

/// @dev Has code and an nft() getter that names some other collection.
contract WrongNftGetter {
    function nft() external view returns (address) {
        return address(this);
    }
}

/// @dev The only way to push ETH into a contract with no payable entry point.
contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// @dev Every state-changing game entry tried from inside the safe-mint callback must hit the guard.
contract MintCallbackAttacker is IERC721Receiver {
    HamsterRunNFT public immutable nft;
    MatchQueue public immutable queue;
    address public immutable sink;
    uint256 public guardedCalls;
    uint256 public attempts;
    bool public moveAway;

    constructor(HamsterRunNFT nft_, MatchQueue queue_, address sink_) payable {
        nft = nft_;
        queue = queue_;
        sink = sink_;
    }

    function attack(bool moveAway_) external returns (uint256) {
        moveAway = moveAway_;
        return nft.mint();
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        _tryGuarded(address(nft), 0, abi.encodeCall(nft.mint, ()));
        _tryGuarded(address(nft), 0.0001 ether, abi.encodeCall(nft.feed, (id, 0)));
        _tryGuarded(address(nft), 0, abi.encodeCall(nft.startTraining, (id)));
        _tryGuarded(address(queue), 0, abi.encodeCall(queue.enqueue, (id)));
        if (moveAway) nft.transferFrom(address(this), sink, id);
        return IERC721Receiver.onERC721Received.selector;
    }

    function _tryGuarded(address target, uint256 value, bytes memory data) private {
        ++attempts;
        (bool ok, bytes memory reason) = target.call{ value: value }(data);
        if (!ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector) ++guardedCalls;
    }
}

/// @dev A safe transfer runs outside the guard, so the new owner may act at once. It still cannot use the
///      pet in a way that outruns the lock.
contract EagerReceiver is IERC721Receiver {
    HamsterRunNFT public immutable nft;
    MatchQueue public immutable queue;
    bool public moveBackWhileQueuedFailed;

    constructor(HamsterRunNFT nft_, MatchQueue queue_) payable {
        nft = nft_;
        queue = queue_;
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        nft.feed{ value: nft.foodPrices(0) }(id, 0);
        queue.enqueue(id);
        try nft.transferFrom(address(this), from, id) {
            moveBackWhileQueuedFailed = false;
        } catch (bytes memory reason) {
            moveBackWhileQueuedFailed = bytes4(reason) == HamsterRunNFT.Locked.selector;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
