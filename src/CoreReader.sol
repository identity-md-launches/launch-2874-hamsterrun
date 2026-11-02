// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ISqueekCore } from "./interfaces/ISqueekCore.sol";

/// @notice Immutable, read-only Core binding, inherited by the NFT; not a separate deployment.
/// @dev Constructors deliberately make no calls to the upstream contract.
abstract contract CoreReader {
    uint64 public constant ROUND_SECONDS = 600;
    uint256 public constant MAX_PAGE_ROUNDS = 16;
    ISqueekCore public immutable core;

    error InvalidCore();
    error CoreUnavailable();
    error UnsupportedCoreConfiguration();
    error CoreNotStarted(uint64 genesisTimestamp);
    error RoundOverflow();
    error InvalidTrainingWindow();
    error CoreCertificationLag(uint64 settledThroughRound, uint64 requiredEndRound);
    error InvalidCorePage();

    constructor(address coreAddress) {
        if (coreAddress == address(0)) revert InvalidCore();
        core = ISqueekCore(coreAddress);
    }

    /// @notice Round 1 starts at Core genesis; this getter belongs to HamsterRun, not SqueekCore.
    function currentRound() public view returns (uint64) {
        _requireCore();
        ISqueekCore.CoreConfiguration memory config = core.configuration();
        if (config.genesisTimestamp == 0 || config.roundDuration != ROUND_SECONDS) {
            revert UnsupportedCoreConfiguration();
        }
        if (block.timestamp < config.genesisTimestamp) revert CoreNotStarted(config.genesisTimestamp);
        uint256 round = (block.timestamp - config.genesisTimestamp) / ROUND_SECONDS + 1;
        if (round > type(uint64).max) revert RoundOverflow();
        return uint64(round);
    }

    /// @notice Every round up to and including this frontier is certified, including omitted zero rounds.
    function settledThroughRound() public view returns (uint64) {
        return _coreState().settledThroughRound;
    }

    /// @notice Physical work in [startRound, endRound], inclusive, over at most 16 consecutive rounds.
    /// @dev Uses endpoint cumulative work, never all-time work or difficulty-derived block counts.
    function certifiedWork(uint64 startRound, uint64 endRound) public view returns (uint64) {
        return _certifiedWork(startRound, endRound, settledThroughRound());
    }

    function _coreState() internal view returns (ISqueekCore.CoreState memory) {
        _requireCore();
        return core.state();
    }

    function _certifiedWork(uint64 startRound, uint64 endRound, uint64 frontier)
        internal
        view
        returns (uint64)
    {
        if (startRound == 0 || endRound < startRound) revert InvalidTrainingWindow();
        uint256 count = uint256(endRound) - startRound + 1;
        if (count > MAX_PAGE_ROUNDS) revert InvalidTrainingWindow();
        if (frontier < endRound) revert CoreCertificationLag(frontier, endRound);
        ISqueekCore.RoundPage memory page = core.roundPage(startRound - 1, endRound, count);
        // There can be at most `count` active records in `count` rounds: a short page is never complete.
        if (
            page.certifiedThroughRound != endRound || page.rounds.length > count
                || page.end.cumulativeWork < page.start.cumulativeWork
        ) revert InvalidCorePage();
        uint64 cursor = startRound - 1;
        uint64 cumulative = page.start.cumulativeWork;
        for (uint256 i; i < page.rounds.length; ++i) {
            ISqueekCore.RoundCheckpoint memory record = page.rounds[i];
            if (record.roundId <= cursor || record.roundId > endRound || record.cumulativeWork <= cumulative) revert InvalidCorePage();
            cursor = record.roundId;
            cumulative = record.cumulativeWork;
        }
        if (cumulative != page.end.cumulativeWork) revert InvalidCorePage();
        return page.end.cumulativeWork - page.start.cumulativeWork;
    }

    function _requireCore() private view {
        if (address(core).code.length == 0) revert CoreUnavailable();
    }
}
