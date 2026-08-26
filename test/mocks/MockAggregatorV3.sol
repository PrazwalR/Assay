// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test double for a Chainlink aggregator.
/// @dev Test infrastructure only. Never imported by anything under src/, and never referenced
///      by a deployment script. It exists so the adapter's staleness, malformed-answer and
///      reverting-feed paths can be exercised deterministically, which a live feed cannot do.
contract MockAggregatorV3 {
    int256 private _answer;
    uint256 private _updatedAt;
    bool private _shouldRevert;

    constructor(int256 answer, uint256 updatedAt) {
        _answer = answer;
        _updatedAt = updatedAt;
    }

    function setAnswer(int256 answer) external {
        _answer = answer;
    }

    function setUpdatedAt(uint256 updatedAt) external {
        _updatedAt = updatedAt;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!_shouldRevert, "MockAggregatorV3: forced revert");
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
