// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice What `CreditPool` needs from the credit registry.
interface ICreditRegistry {
    /// @dev All ratios and rates are WAD (1e18 = 100%); `limit` is in asset units.
    struct Terms {
        uint256 pd; // estimated default probability per loan
        uint256 collateralRatio; // c: required collateral value / principal
        uint256 premium; // risk premium APR, paid into the reserve
        uint256 limit; // maximum principal
    }

    function terms(address borrower) external view returns (Terms memory);

    function isBarred(address borrower) external view returns (bool);

    /// @notice Loan term in protocol seconds; also the reference term of the score.
    function term() external view returns (uint256);

    function onRepaid(address borrower, uint256 principal, uint256 elapsed, bool late) external;

    function onLiquidated(address borrower) external;

    function onDefaulted(address borrower) external;
}
