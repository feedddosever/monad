// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {MonPriceOracle} from "../src/MonPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {Params} from "../script/Params.sol";

contract CreditPoolTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TIME_SCALE = Params.DEMO_TIME_SCALE; // 1 s = 12 h: a 30-day term lasts 60 s
    uint256 internal constant TERM_REAL = 60;
    uint256 internal constant GRACE_REAL = 6;
    uint256 internal constant MAX_APR = 10e18;
    int64 internal constant MON_PRICE = 2_500_000; // $0.025 with expo -8
    uint256 internal constant PYTH_FEE = 1;

    MockUSDC internal usdc;
    MockPyth internal pyth;
    CreditRegistry internal registry;
    CreditPool internal pool;

    address internal lender = makeAddr("lender");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploy(1_000e6, 1e18);
    }

    function _deploy(uint256 reserveAmount, uint256 leverage) internal {
        usdc = new MockUSDC();
        pyth = new MockPyth();
        pyth.setPrice(MON_PRICE, 1_000, -8);
        pyth.setFee(PYTH_FEE);
        MonPriceOracle oracle = new MonPriceOracle(IPyth(address(pyth)), bytes32("MON/USD"), 60, 200);

        registry = new CreditRegistry(address(this), makeAddr("attestor"), Params.registry());
        CreditPool.RateParams memory rates = defaultRates();
        rates.reserveLeverage = leverage;
        pool = new CreditPool(usdc, registry, oracle, TIME_SCALE, rates, address(this));
        registry.setPool(address(pool));

        address[4] memory users = [lender, alice, bob, keeper];
        for (uint256 i; i < users.length; ++i) {
            usdc.mint(users[i], 100_000e6);
            vm.prank(users[i]);
            usdc.approve(address(pool), type(uint256).max);
            vm.deal(users[i], 1_000e18);
        }
        vm.prank(lender);
        pool.deposit(50_000e6, lender);

        usdc.mint(address(this), reserveAmount);
        usdc.approve(address(pool), type(uint256).max);
        pool.fundReserve(reserveAmount);
    }

    function defaultRates() internal pure returns (CreditPool.RateParams memory) {
        return Params.rates();
    }

    // ---------------------------------------------------------------- stablecoin path

    function test_FirstLoanIsFullySecured() public {
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.borrowStable(100e6, MAX_APR);

        (uint128 principal, uint128 collateral, uint128 unsecured,, uint64 due,, uint64 premium,) = pool.loans(alice);
        assertEq(principal, 100e6);
        assertEq(collateral, 100e6);
        assertEq(unsecured, 0);
        assertEq(premium, 0);
        assertEq(due, block.timestamp + TERM_REAL);
        assertEq(usdc.balanceOf(alice), before, "posted 100, received 100");
        _assertBooks();
    }

    function test_RepayAtTermPaysLPsAndBuildsHistory() public {
        uint256 assetsBefore = pool.totalAssets();
        _borrowAndRepayAtTerm(alice, 100e6);

        // base = 2% + 10% × utilisation after borrowing (100 / 50,000); 30 days of simple interest
        uint256 interest = _ceilDiv(100e6 * 0.0202e18 * 30, 365 * WAD);
        assertApproxEqAbs(pool.totalAssets(), assetsBefore + interest, 2, "LPs earn the base interest");
        assertEq(pool.reserve(), 1_000e6, "secured loan pays no premium");

        (uint128 earned, uint128 repaid,,,,,,) = registry.records(alice);
        assertEq(earned, WAD, "one reference loan");
        assertEq(repaid, 100e6);
        assertApproxEqRel(registry.terms(alice).collateralRatio, 0.666667e18, 1e13, "c drops to 66.7%");
        _assertBooks();
    }

    function test_SecondLoanIsUndercollateralisedAndFundsReserve() public {
        _borrowAndRepayAtTerm(alice, 100e6);

        vm.prank(alice);
        pool.borrowStable(150e6, MAX_APR);
        (, uint128 collateral, uint128 unsecured,,,, uint64 premium,) = pool.loans(alice);
        assertApproxEqAbs(collateral, 100e6, 1, "c = 66.7% of 150");
        assertApproxEqAbs(unsecured, 50e6, 1);
        assertEq(pool.totalUnsecured(), unsecured);
        assertGt(premium, 0);

        skip(TERM_REAL);
        vm.prank(alice);
        pool.repay();
        assertGt(pool.reserve(), 1_000e6, "premium flows to the reserve");
        assertEq(pool.totalUnsecured(), 0);
        _assertBooks();
    }

    function test_RevertWhen_ReserveCapacityExceeded() public {
        _borrowAndRepayAtTerm(alice, 100e6);
        CreditPool.RateParams memory p = defaultRates();
        p.reserveLeverage = 0.01e18; // capacity 10 mUSDC
        pool.setRateParams(p);

        vm.prank(alice);
        vm.expectRevert(CreditPool.ReserveCapacityExceeded.selector);
        pool.borrowStable(150e6, MAX_APR);
    }

    function test_RevertWhen_AboveLimit() public {
        vm.prank(alice);
        vm.expectRevert(CreditPool.ExceedsLimit.selector);
        pool.borrowStable(101e6, MAX_APR);
    }

    function test_RevertWhen_AprAboveMax() public {
        _borrowAndRepayAtTerm(alice, 100e6);
        CreditPool.Quote memory q = pool.quote(alice, 150e6);
        vm.prank(alice);
        vm.expectRevert(CreditPool.AprAboveMax.selector);
        pool.borrowStable(150e6, q.apr - 1);
    }

    function test_RevertWhen_LoanAlreadyOpen() public {
        vm.startPrank(alice);
        pool.borrowStable(50e6, MAX_APR);
        vm.expectRevert(CreditPool.LoanOpen.selector);
        pool.borrowStable(50e6, MAX_APR);
        vm.stopPrank();
    }

    function test_RevertWhen_BorrowingPaused() public {
        pool.setBorrowingPaused(true);
        vm.prank(alice);
        vm.expectRevert(CreditPool.BorrowingIsPaused.selector);
        pool.borrowStable(50e6, MAX_APR);
    }

    function test_RevertWhen_UtilizationTooHigh() public {
        vm.prank(lender);
        pool.withdraw(49_950e6, lender, lender); // leaves 50 of LP cash
        vm.prank(alice);
        vm.expectRevert(CreditPool.UtilizationTooHigh.selector);
        pool.borrowStable(50e6, MAX_APR);
    }

    function test_LateRepaymentEarnsNoHistory() public {
        vm.prank(alice);
        pool.borrowStable(100e6, MAX_APR);
        skip(TERM_REAL + 3); // past due, inside grace
        vm.prank(alice);
        pool.repay();
        (uint128 earned,, uint32 late,,,,,) = registry.records(alice);
        assertEq(earned, 0);
        assertEq(late, 1);
        _assertBooks();
    }

    function test_WithdrawCappedAtIdleCash() public {
        vm.prank(alice);
        pool.borrowStable(100e6, MAX_APR);
        assertEq(pool.maxWithdraw(lender), pool.lpCash());
        vm.prank(lender);
        vm.expectRevert();
        pool.withdraw(50_000e6, lender, lender);
    }

    // ---------------------------------------------------------------- default

    function test_DefaultReserveCoversLossAndBarsBorrower() public {
        _borrowAndRepayAtTerm(bob, 100e6);
        vm.prank(bob);
        pool.borrowStable(150e6, MAX_APR);
        (, uint128 collateral,,,,,,) = pool.loans(bob);

        skip(TERM_REAL + GRACE_REAL + 1);
        uint256 sharePrice = pool.convertToAssets(1e12);
        uint256 lpOwed = 150e6 + _bookedBaseInterest(bob);

        vm.prank(keeper);
        pool.markDefault(bob, new bytes[](0));

        assertEq(pool.reserve(), 1_000e6 - (lpOwed - collateral), "reserve covers the unsecured part");
        assertGe(pool.convertToAssets(1e12) + 1, sharePrice, "LP share price does not fall");
        assertTrue(registry.isBarred(bob));
        assertEq(pool.totalUnsecured(), 0);

        vm.prank(bob);
        vm.expectRevert(CreditPool.Barred.selector);
        pool.borrowStable(1e6, MAX_APR);
        _assertBooks();
    }

    function test_RevertWhen_DefaultBeforeGraceEnds() public {
        vm.prank(bob);
        pool.borrowStable(100e6, MAX_APR);
        skip(TERM_REAL + GRACE_REAL);
        vm.expectRevert(CreditPool.NotDefaultable.selector);
        pool.markDefault(bob, new bytes[](0));
    }

    function test_DefaultLossBeyondReserveHitsLPs() public {
        _deploy(30e6, 3e18); // thin reserve, levered 3x: up to 90 unsecured against 30 of first-loss capital
        _borrowAndRepayAtTerm(bob, 100e6);
        vm.prank(bob);
        pool.borrowStable(150e6, MAX_APR);
        (, uint128 collateral,,,,,,) = pool.loans(bob);

        skip(TERM_REAL + GRACE_REAL + 1);
        uint256 lpOwed = 150e6 + _bookedBaseInterest(bob);
        uint256 lpLoss = lpOwed - collateral - 30e6;
        uint256 assetsBefore = pool.totalAssets();

        vm.expectEmit(true, true, false, true, address(pool));
        emit CreditPool.Defaulted(bob, keeper, 150e6, collateral, 30e6, lpLoss);
        vm.prank(keeper);
        pool.markDefault(bob, new bytes[](0));

        assertEq(pool.reserve(), 0, "reserve wiped first");
        assertApproxEqAbs(pool.totalAssets(), assetsBefore - lpLoss, 2, "LPs absorb the rest");
        _assertBooks();
    }

    // ---------------------------------------------------------------- MON path

    function test_MonLoanRepayReturnsMon() public {
        uint256 monBefore = alice.balance;
        _borrowMon(alice, 1e6, 50e18); // 50 MON × $0.025 × 80% = 1.00 mUSDC of haircut value
        (,,,,,,, CreditPool.Kind kind) = pool.loans(alice);
        assertEq(uint8(kind), uint8(CreditPool.Kind.Mon));
        assertEq(address(pool).balance, 50e18);

        skip(TERM_REAL);
        vm.prank(alice);
        pool.repay();
        assertEq(alice.balance, monBefore - PYTH_FEE, "MON back, only the oracle fee spent");
        assertEq(address(pool).balance, 0);
        _assertBooks();
    }

    function test_RevertWhen_MonCollateralShort() public {
        bytes[] memory update = _priceUpdate(MON_PRICE);
        vm.prank(alice);
        vm.expectRevert(CreditPool.InsufficientCollateral.selector);
        pool.borrowMon{value: 49e18 + PYTH_FEE}(1e6, MAX_APR, update);
    }

    function test_RevertWhen_PriceStale() public {
        skip(61); // stored price older than maxAge, and no update supplied
        vm.prank(alice);
        vm.expectRevert(MockPyth.StalePrice.selector);
        pool.borrowMon{value: 50e18}(1e6, MAX_APR, new bytes[](0));
    }

    function test_LiquidationConvertsMonToStable() public {
        _borrowMon(alice, 1e6, 50e18);
        int64 crashed = 2_000_000; // $0.020: 50 MON × 0.02 × 0.8 = 0.80 < 0.85 × 1.00
        bytes[] memory update = _priceUpdate(crashed);

        uint256 keeperUsdc = usdc.balanceOf(keeper);
        vm.prank(keeper);
        pool.liquidate{value: PYTH_FEE}(alice, update);

        uint256 stableIn = 0.95e6; // 50 × 0.02 × (1 − 5%)
        (, uint128 collateral, uint128 unsecured,,,,, CreditPool.Kind kind) = pool.loans(alice);
        assertEq(uint8(kind), uint8(CreditPool.Kind.Stable));
        assertEq(collateral, stableIn);
        assertEq(unsecured, 1e6 - stableIn);
        assertEq(usdc.balanceOf(keeper), keeperUsdc - stableIn);
        assertEq(keeper.balance, 1_000e18 - PYTH_FEE + 50e18, "keeper received the MON");
        (,,, uint32 liquidations,,,,) = registry.records(alice);
        assertEq(liquidations, 1);

        skip(TERM_REAL);
        vm.prank(alice);
        pool.repay(); // loan continues and settles on stable collateral
        _assertBooks();
    }

    function test_RevertWhen_LiquidatingHealthyLoan() public {
        _borrowMon(alice, 1e6, 50e18);
        bytes[] memory update = _priceUpdate(2_200_000); // 0.88 ≥ 0.85
        vm.prank(keeper);
        vm.expectRevert(CreditPool.Healthy.selector);
        pool.liquidate{value: PYTH_FEE}(alice, update);
    }

    function test_MonDefaultSellsCollateralToKeeper() public {
        _borrowMon(bob, 1e6, 60e18);
        skip(TERM_REAL + GRACE_REAL + 1);
        bytes[] memory update = _priceUpdate(MON_PRICE);
        vm.prank(keeper);
        pool.markDefault{value: PYTH_FEE}(bob, update);

        // 60 MON × 0.025 × 95% = 1.425 mUSDC recovered; the debt is ~1.0017, the rest goes back to bob
        assertEq(keeper.balance, 1_000e18 - PYTH_FEE + 60e18);
        assertTrue(registry.isBarred(bob));
        assertEq(pool.reserve(), 1_000e6, "fully recovered, reserve untouched");
        _assertBooks();
    }

    // ---------------------------------------------------------------- properties

    function testFuzz_BooksBalanceAcrossLoanCycles(uint96 amount, uint16 waitSeconds, uint8 cycles) public {
        amount = uint96(bound(amount, 1e6, 100e6));
        waitSeconds = uint16(bound(waitSeconds, 0, 120));
        cycles = uint8(bound(cycles, 1, 4));
        uint256 deposited = pool.totalAssets();
        for (uint256 i; i < cycles; ++i) {
            uint256 limit = registry.terms(alice).limit;
            vm.prank(alice);
            pool.borrowStable(Math.min(amount, limit), MAX_APR);
            skip(waitSeconds);
            if (block.timestamp > _due(alice) + GRACE_REAL) {
                pool.markDefault(alice, new bytes[](0));
                break;
            }
            vm.prank(alice);
            pool.repay();
            _assertBooks();
        }
        _assertBooks();
        assertGe(pool.totalAssets() + 1, deposited, "LP value never falls while the reserve is solvent");
    }

    // ---------------------------------------------------------------- helpers

    /// @dev Every stablecoin the pool holds belongs to exactly one bucket.
    function _assertBooks() internal view {
        assertEq(usdc.balanceOf(address(pool)), pool.lpCash() + pool.reserve() + pool.stableCollateral(), "books");
    }

    function _borrowAndRepayAtTerm(address who, uint256 amount) internal {
        vm.prank(who);
        pool.borrowStable(amount, MAX_APR);
        skip(TERM_REAL);
        vm.prank(who);
        pool.repay();
    }

    function _borrowMon(address who, uint256 amount, uint256 mon) internal {
        bytes[] memory update = _priceUpdate(MON_PRICE);
        vm.prank(who);
        pool.borrowMon{value: mon + PYTH_FEE}(amount, MAX_APR, update);
    }

    function _priceUpdate(int64 price) internal pure returns (bytes[] memory update) {
        update = new bytes[](1);
        update[0] = abi.encode(price, uint64(1_000), int32(-8));
    }

    function _bookedBaseInterest(address who) internal view returns (uint256) {
        (uint128 principal,,, uint64 start,, uint64 baseRate,,) = pool.loans(who);
        return uint256(principal) * baseRate * ((block.timestamp - start) * TIME_SCALE) / (365 days * WAD);
    }

    function _due(address who) internal view returns (uint256 due) {
        (,,,, due,,,) = pool.loans(who);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
