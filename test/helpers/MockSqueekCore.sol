// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ISqueekCore } from "../../src/interfaces/ISqueekCore.sol";

/// @notice Sparse certified ledger with the real ABI and paging rules, not a wall-clock reward mock.
contract MockSqueekCore is ISqueekCore {
    CoreConfiguration private _configuration;
    CoreState private _state;
    RoundCheckpoint[] private _records;

    error InvalidRoundPageBounds();

    constructor(uint64 genesis) {
        _configuration.genesisTimestamp = genesis;
        _configuration.roundDuration = 600;
        _configuration.maxRoundsPerBatch = 16;
        _configuration.maxWorkPerRound = type(uint64).max;
    }

    function configuration() external view returns (CoreConfiguration memory) {
        return _configuration;
    }

    function state() external view returns (CoreState memory) {
        return _state;
    }

    function setConfiguration(uint64 genesis, uint64 duration) external {
        _configuration.genesisTimestamp = genesis;
        _configuration.roundDuration = duration;
    }

    function setPaused(bool paused) external {
        _state.paused = paused;
    }

    /// @notice Certify a span; all gaps are zero and any work is attached to its final round.
    function certify(uint64 throughRound, uint64 work) external {
        _requireElapsed(throughRound);
        if (work != 0) _record(throughRound, work);
        _state.settledThroughRound = throughRound;
        ++_state.authorizationNonce;
    }

    function certifyBatch(uint64 throughRound, uint64[] memory rounds, uint64[] memory works) external {
        _requireElapsed(throughRound);
        require(rounds.length == works.length && rounds.length <= 16, "bad batch");
        uint64 previous = _state.settledThroughRound;
        for (uint256 i; i < rounds.length; ++i) {
            require(rounds[i] > previous && rounds[i] <= throughRound && works[i] != 0, "bad round");
            _record(rounds[i], works[i]);
            previous = rounds[i];
        }
        _state.settledThroughRound = throughRound;
        ++_state.authorizationNonce;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory page)
    {
        if (afterRound > throughRound || throughRound > _state.settledThroughRound || maxRecords > 16) {
            revert InvalidRoundPageBounds();
        }
        uint256 first = _upperBound(afterRound);
        uint256 last = _upperBound(throughRound);
        uint256 count = last - first;
        page.certifiedThroughRound = throughRound;
        if (count > maxRecords) {
            count = maxRecords;
            page.certifiedThroughRound = _records[first + count].roundId - 1;
        }
        page.start = _position(first);
        page.end = _position(first + count);
        page.rounds = new RoundCheckpoint[](count);
        for (uint256 i; i < count; ++i) {
            page.rounds[i] = _records[first + i];
        }
    }

    function _requireElapsed(uint64 throughRound) private view {
        require(!_state.paused, "paused");
        require(throughRound > _state.settledThroughRound, "frontier must advance");
        require(
            block.timestamp >= uint256(_configuration.genesisTimestamp) + uint256(throughRound) * 600,
            "round not ended"
        );
    }

    function _record(uint64 round, uint64 work) private {
        _state.cumulativeWork += work;
        _records.push(RoundCheckpoint(round, _state.cumulativeWork, 0, 0, keccak256(abi.encode(round, work))));
    }

    function _upperBound(uint64 round) private view returns (uint256 low) {
        uint256 high = _records.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (_records[mid].roundId <= round) low = mid + 1;
            else high = mid;
        }
    }

    function _position(uint256 count) private view returns (LedgerPosition memory pos) {
        if (count != 0) pos.cumulativeWork = _records[count - 1].cumulativeWork;
    }
}
