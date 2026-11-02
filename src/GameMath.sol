// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

enum WeightClass {
    Fit,
    Normal,
    Obese
}

enum Activity {
    Idle,
    Training,
    Queued,
    Matched
}

/// @notice All game formulas are deterministic; see DESIGN.md for rounding and boundaries.
library GameMath {
    uint256 internal constant STAMINA_PER_WORK = 2;
    error InvalidNoise();

    function weightClass(uint256 bodyScore) internal pure returns (WeightClass) {
        if (bodyScore >= 70) return WeightClass.Fit;
        if (bodyScore >= 35) return WeightClass.Normal;
        return WeightClass.Obese;
    }

    /// @notice Two base stamina per certified physical work unit, scaled by the last feed's bps.
    /// @dev uint64 work and bps <= 50_000 make the product safe; zero work earns exactly zero.
    function trainingGain(uint64 work, uint256 trainBps) internal pure returns (uint256) {
        return uint256(work) * STAMINA_PER_WORK * trainBps / 10_000;
    }

    /// @param noise An integer in [0, 2000], representing a [-1000, +1000] bps perturbation.
    /// @dev The common 20_000 divisor keeps every score representable for full-width stamina.
    ///      Math.mulDiv handles the intermediate product without imposing a stamina cap.
    function raceScore(uint256 stamina, WeightClass weight, uint256 noise) internal pure returns (uint256) {
        if (noise > 2000) revert InvalidNoise();
        uint256 weightBps = weight == WeightClass.Fit ? 11_500 : weight == WeightClass.Normal ? 10_000 : 8500;
        return Math.mulDiv(stamina, weightBps - 1000 + noise, 20_000);
    }
}
