// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice MON/USD price source used by `CreditPool` for MON collateral.
interface IMonPriceOracle {
    /// @notice Fee (in MON) that `updateAndRead` needs for `update`.
    function updateFee(bytes[] calldata update) external view returns (uint256);

    /// @notice Applies a fresh price update, then returns USD per MON in WAD. Reverts if stale or too uncertain.
    function updateAndRead(bytes[] calldata update) external payable returns (uint256 priceWad);
}
