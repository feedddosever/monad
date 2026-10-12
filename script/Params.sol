// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CreditPool} from "../src/CreditPool.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";

/// @notice Protocol parameters from docs/spec.md §2, shared by the deploy script and the tests.
library Params {
    /// @dev Demo clock: 1 real second = 12 protocol hours, so a 30-day loan lasts 60 s. Production: 1.
    uint256 internal constant DEMO_TIME_SCALE = 43_200;

    // Pyth on Monad Testnet (docs.monad.xyz/tooling-and-infra/oracles) and its MON/USD feed id.
    address internal constant PYTH_TESTNET = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 internal constant MON_USD_FEED = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    uint256 internal constant ORACLE_MAX_AGE = 60; // seconds
    uint256 internal constant ORACLE_MAX_CONF_BPS = 200; // 2% of price

    function registry() internal pure returns (CreditRegistry.Params memory) {
        return CreditRegistry.Params({
            a: 1e18,
            b: 0.25e18, // PD0 = b / (a + b) = 20%
            g: 1e18,
            failWeight: 0.5e18,
            cMin: 0.25e18,
            term: 30 days,
            refPrincipal: 100e6,
            baseLimit: 100e6,
            limitPerRepaid: 0.5e18,
            maxLimit: 5_000e6
        });
    }

    function rates() internal pure returns (CreditPool.RateParams memory) {
        return CreditPool.RateParams({
            baseRate: 0.02e18,
            slope: 0.1e18,
            maxUtilization: 0.9e18,
            reserveLeverage: 1e18, // k = 1: every unit of unsecured credit backed by first-loss capital
            monHaircut: 0.2e18,
            liqThreshold: 0.85e18,
            liqBonus: 0.05e18,
            grace: 3 days
        });
    }
}

/// @notice Explicit per-transaction gas limits. Monad charges the gas LIMIT, not gas used, so these are
///         tight: max execution gas from `forge test --gas-report` (Monad gas model) + 21,000 intrinsic,
///         plus ~20% headroom, rounded up. See docs/gas-report.md. Contract creations can't take an explicit
///         gas option in Solidity; scripts pass `--gas-estimate-multiplier 120` for those.
library GasLimits {
    uint256 internal constant APPROVE = 90_000; // 53,027 measured
    uint256 internal constant MINT = 125_000; // 80,700
    uint256 internal constant SET_POOL = 90_000; // 51,689
    uint256 internal constant FUND_RESERVE = 155_000; // 107,521
    uint256 internal constant DEPOSIT = 230_000; // 166,343
    uint256 internal constant WITHDRAW = 145_000; // 99,459
    uint256 internal constant BORROW_STABLE = 370_000; // 285,918
    uint256 internal constant REPAY = 265_000; // 196,762
    uint256 internal constant MARK_DEFAULT = 355_000; // 273,728 (stable loan)
    uint256 internal constant SUBMIT_ATTESTATION = 130_000; // 85,033
    uint256 internal constant SEND_MON = 21_000; // plain transfer to an EOA is exactly 21,000
}
