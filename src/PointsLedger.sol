// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Non-transferable address counters. There is no token, redemption or external award role.
abstract contract PointsLedger {
    mapping(address => uint256) public points;
    mapping(uint256 => mapping(address => uint256)) public weeklyPoints;
    uint256 public totalPoints;

    event PointsAwarded(address indexed player, uint256 indexed week, uint256 amount, uint256 total);

    function _awardPoints(address player, uint256 week, uint256 amount) internal {
        points[player] += amount;
        weeklyPoints[week][player] += amount;
        totalPoints += amount;
        emit PointsAwarded(player, week, amount, points[player]);
    }
}
