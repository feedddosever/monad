// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant, Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CreditPool} from "../../src/CreditPool.sol";
import {CreditRegistry} from "../../src/CreditRegistry.sol";
import {ICreditRegistry} from "../../src/interfaces/ICreditRegistry.sol";
import {MonPriceOracle} from "../../src/MonPriceOracle.sol";
import {MockUSDC} from "../../src/MockUSDC.sol";
import {IPyth} from "../../src/interfaces/IPyth.sol";
import {MockPyth} from "../mocks/MockPyth.sol";
import {Params} from "../../script/Params.sol";

/// @notice Drives the pool through random sequences of lender, borrower and keeper actions.
contract Handler is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant GRACE_REAL = 6;
    uint256 internal constant FEE = 1;

    CreditPool public pool;
    CreditRegistry public registry;
    MockUSDC public usdc;
    MockPyth public pyth;
    address public lender = makeAddr("lender");
    address public keeper = makeAddr("keeper");
    uint256 internal constant N = 6;
    address[N] public borrowers =
        [makeAddr("b0"), makeAddr("b1"), makeAddr("b2"), makeAddr("b3"), makeAddr("b4"), makeAddr("b5")];
    int64 public monPrice = 2_500_000; // $0.025

    // Ghosts
    int256 public lpCapital; // deposits − withdrawals + LP interest − LP losses, from observed lpCash deltas
    uint256 public lpLossEvents;
    bool public onTimeRepayLoweredScore;
    bool public reserveFellOutsideDefault;
    mapping(bytes32 => uint256) public calls;

    constructor(CreditPool pool_, CreditRegistry registry_, MockUSDC usdc_, MockPyth pyth_) {
        pool = pool_;
        registry = registry_;
        usdc = usdc_;
        pyth = pyth_;
        lpCapital = int256(pool.lpCash());
        vm.prank(lender);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(keeper);
        usdc.approve(address(pool), type(uint256).max);
        for (uint256 i; i < N; ++i) {
            vm.prank(borrowers[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------- lender

    function deposit(uint256 amount) external {
        amount = bound(amount, 1e6, 20_000e6);
        usdc.mint(lender, amount);
        uint256 reserveBefore = pool.reserve();
        vm.prank(lender);
        pool.deposit(amount, lender);
        lpCapital += int256(amount);
        _checkReserveNotReduced(reserveBefore);
        calls["deposit"]++;
    }

    function withdraw(uint256 amount) external {
        amount = bound(amount, 0, pool.maxWithdraw(lender));
        if (amount == 0) return;
        uint256 reserveBefore = pool.reserve();
        vm.prank(lender);
        pool.withdraw(amount, lender, lender);
        lpCapital -= int256(amount);
        _checkReserveNotReduced(reserveBefore);
        calls["withdraw"]++;
    }

    // ---------------------------------------------------------------- borrowers

    function borrowStable(uint256 seed, uint256 amount) external {
        address b = _pick(seed, Want.Free);
        if (b == address(0)) return;
        ICreditRegistry.Terms memory t = registry.terms(b);
        amount = bound(amount, 1e6, t.limit);
        usdc.mint(b, amount);
        _borrow(b, abi.encodeCall(CreditPool.borrowStable, (amount, type(uint256).max)), 0);
    }

    function borrowMon(uint256 seed, uint256 amount, uint256 extraBps) external {
        address b = _pick(seed, Want.Free);
        if (b == address(0)) return;
        ICreditRegistry.Terms memory t = registry.terms(b);
        amount = bound(amount, 1e6, Math.min(t.limit, 5e6));
        extraBps = bound(extraBps, 0, 5_000);
        uint256 required = Math.mulDiv(amount, t.collateralRatio, WAD, Math.Rounding.Ceil);
        uint256 price = uint256(uint64(monPrice)) * 1e10;
        uint256 mon = Math.mulDiv(required, 1e30 * WAD, price * (WAD - 0.2e18), Math.Rounding.Ceil);
        mon = mon + mon * extraBps / 10_000 + 1;
        vm.deal(b, mon + FEE);
        _borrow(b, abi.encodeCall(CreditPool.borrowMon, (amount, type(uint256).max, _update())), mon + FEE);
    }

    function repay(uint256 seed) external {
        address b = _pick(seed, Want.Open);
        if (b == address(0)) return;
        (uint128 principal,,,, uint64 due,,,) = pool.loans(b);
        (uint256 debt,,) = pool.debtOf(b);
        usdc.mint(b, debt);
        bool late = block.timestamp > due;
        uint256 scoreBefore = registry.score(b);
        uint256 lpCashBefore = pool.lpCash();
        uint256 reserveBefore = pool.reserve();

        vm.prank(b);
        pool.repay();

        lpCapital += int256(pool.lpCash()) - int256(lpCashBefore) - int256(uint256(principal));
        _checkReserveNotReduced(reserveBefore);
        if (!late && registry.score(b) < scoreBefore) onTimeRepayLoweredScore = true;
        calls[late ? bytes32("repayLate") : bytes32("repayOnTime")]++;
    }

    // ---------------------------------------------------------------- keepers and market

    function markDefault(uint256 seed) external {
        address b = _pick(seed, Want.Defaultable);
        if (b == address(0)) return;
        (uint128 principal,,,,,,, CreditPool.Kind kind) = pool.loans(b);
        usdc.mint(keeper, 1_000e6);
        vm.deal(keeper, FEE);
        uint256 lpCashBefore = pool.lpCash();
        uint256 assetsBefore = pool.totalAssets();

        vm.prank(keeper);
        if (kind == CreditPool.Kind.Mon) pool.markDefault{value: FEE}(b, _update());
        else pool.markDefault(b, new bytes[](0));

        lpCapital += int256(pool.lpCash()) - int256(lpCashBefore) - int256(uint256(principal));
        if (pool.totalAssets() + 2 < assetsBefore) lpLossEvents++;
        calls["markDefault"]++;
    }

    function liquidate(uint256 seed) external {
        address b = _pick(seed, Want.Mon);
        if (b == address(0)) return;
        usdc.mint(keeper, 1_000e6);
        vm.deal(keeper, FEE);
        uint256 reserveBefore = pool.reserve();
        bytes[] memory update = _update();
        vm.prank(keeper);
        try pool.liquidate{value: FEE}(b, update) {
            calls["liquidate"]++;
        } catch {}
        _checkReserveNotReduced(reserveBefore);
    }

    function movePrice(uint256 price) external {
        monPrice = int64(int256(bound(price, 500_000, 5_000_000))); // $0.005 to $0.05
        pyth.setPrice(monPrice, 1_000, -8);
        calls["movePrice"]++;
    }

    function fundReserve(uint256 amount) external {
        amount = bound(amount, 1, 100e6);
        usdc.mint(keeper, amount);
        vm.prank(keeper);
        pool.fundReserve(amount);
        calls["fundReserve"]++;
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1, 90));
        pyth.setPrice(monPrice, 1_000, -8); // keep the stored price fresh for MON actions
        calls["warp"]++;
    }

    // ---------------------------------------------------------------- views for invariants

    function borrowerCount() external pure returns (uint256) {
        return N;
    }

    // ---------------------------------------------------------------- helpers

    function _borrow(address b, bytes memory data, uint256 value) internal {
        uint256 lpBookBefore = pool.lpCash() + pool.totalPrincipal();
        uint256 reserveBefore = pool.reserve();
        vm.prank(b);
        (bool ok,) = address(pool).call{value: value}(data);
        if (!ok) return; // utilisation or reserve cap: allowed to revert
        // Lending moves LP cash into principal one for one; reserve and collateral are never lent.
        assertEq(pool.lpCash() + pool.totalPrincipal(), lpBookBefore, "borrow is funded by LP cash only");
        _checkReserveNotReduced(reserveBefore);
        calls["borrow"]++;
    }

    function _checkReserveNotReduced(uint256 reserveBefore) internal {
        if (pool.reserve() < reserveBefore) reserveFellOutsideDefault = true;
    }

    enum Want {
        Free, // no open loan and not barred
        Open,
        Defaultable,
        Mon
    }

    /// @dev First borrower, starting from `seed`, in the wanted state; address(0) if none.
    function _pick(uint256 seed, Want want) internal view returns (address) {
        for (uint256 i; i < N; ++i) {
            address b = borrowers[(seed % N + i) % N];
            (,,,, uint64 due,,, CreditPool.Kind kind) = pool.loans(b);
            bool open = kind != CreditPool.Kind.None;
            if (want == Want.Free && !open && !registry.isBarred(b)) return b;
            if (want == Want.Open && open) return b;
            if (want == Want.Defaultable && open && block.timestamp > due + GRACE_REAL) return b;
            if (want == Want.Mon && kind == CreditPool.Kind.Mon) return b;
        }
        return address(0);
    }

    function _update() internal view returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = abi.encode(monPrice, uint64(1_000), int32(-8));
    }
}

contract CreditPoolInvariantTest is StdInvariant, Test {
    CreditPool internal pool;
    CreditRegistry internal registry;
    MockUSDC internal usdc;
    Handler internal handler;
    uint256 internal initialSharePrice;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        MockPyth pyth = new MockPyth();
        pyth.setPrice(2_500_000, 1_000, -8);
        pyth.setFee(1);
        MonPriceOracle oracle = new MonPriceOracle(IPyth(address(pyth)), bytes32("MON/USD"), 60, 200);
        registry = new CreditRegistry(address(this), makeAddr("attestor"), Params.registry());
        pool = new CreditPool(usdc, registry, oracle, Params.DEMO_TIME_SCALE, Params.rates(), address(this));
        registry.setPool(address(pool));

        usdc.mint(address(this), 51_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.fundReserve(1_000e6);
        pool.deposit(50_000e6, address(this));
        initialSharePrice = pool.convertToAssets(1e12);

        handler = new Handler(pool, registry, usdc, pyth);
        targetContract(address(handler));
    }

    /// @dev Every stablecoin in the pool sits in exactly one bucket: LP cash, reserve or borrower collateral.
    function invariant_booksBalance() public view {
        assertEq(usdc.balanceOf(address(pool)), pool.lpCash() + pool.reserve() + pool.stableCollateral());
    }

    /// @dev Total debt ≤ total supplied minus reserves: loans are funded only from LP capital, and the LP book
    ///      equals deposits − withdrawals + LP interest − LP losses.
    function invariant_debtFundedByLpCapitalOnly() public view {
        assertEq(int256(pool.lpCash() + pool.totalPrincipal()), handler.lpCapital(), "LP book reconciles");
        assertLe(int256(pool.totalPrincipal()), handler.lpCapital(), "debt <= LP capital");
        assertFalse(handler.reserveFellOutsideDefault(), "reserve only ever pays for defaults");
    }

    /// @dev Aggregates equal the sum over open loans.
    function invariant_aggregatesMatchLoans() public view {
        uint256 principal;
        uint256 unsecured;
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            (uint128 p,, uint128 u,,,,,) = pool.loans(handler.borrowers(i));
            principal += p;
            unsecured += u;
        }
        assertEq(pool.totalPrincipal(), principal);
        assertEq(pool.totalUnsecured(), unsecured);
    }

    /// @dev No open loan exceeds its borrower's credit limit.
    function invariant_noBorrowerAboveLimit() public view {
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            address b = handler.borrowers(i);
            (uint128 p,,,,,,,) = pool.loans(b);
            if (p != 0) assertLe(p, registry.terms(b).limit);
        }
    }

    /// @dev On-time repayments never lower a score. (Late repayments are failures in the spec and do lower it.)
    function invariant_onTimeRepaymentNeverLowersScore() public view {
        assertFalse(handler.onTimeRepayLoweredScore());
    }

    /// @dev While the reserve absorbs every default in full, LP share price never falls.
    function invariant_sharePriceHoldsWithoutLpLoss() public view {
        if (handler.lpLossEvents() == 0) assertGe(pool.convertToAssets(1e12) + 1, initialSharePrice);
    }

    /// @dev Proves the campaign reached the interesting paths: run with -vv to see per-run counts.
    function afterInvariant() external view {
        string[6] memory keys = ["borrow", "repayOnTime", "repayLate", "markDefault", "liquidate", "withdraw"];
        for (uint256 i; i < keys.length; ++i) {
            console.log(keys[i], handler.calls(bytes32(bytes(keys[i]))));
        }
    }
}

contract HandlerSmokeTest is Test {
    function test_HandlerReachesEveryPath() public {
        vm.warp(1_800_000_000);
        MockUSDC usdc = new MockUSDC();
        MockPyth pyth = new MockPyth();
        pyth.setPrice(2_500_000, 1_000, -8);
        pyth.setFee(1);
        MonPriceOracle oracle = new MonPriceOracle(IPyth(address(pyth)), bytes32("MON/USD"), 60, 200);
        CreditRegistry registry = new CreditRegistry(address(this), makeAddr("attestor"), Params.registry());
        CreditPool pool = new CreditPool(usdc, registry, oracle, Params.DEMO_TIME_SCALE, Params.rates(), address(this));
        registry.setPool(address(pool));
        usdc.mint(address(this), 51_000e6);
        usdc.approve(address(pool), type(uint256).max);
        pool.fundReserve(1_000e6);
        pool.deposit(50_000e6, address(this));
        Handler h = new Handler(pool, registry, usdc, pyth);

        h.borrowStable(0, 100e6);
        h.borrowMon(1, 1e6, 0);
        h.borrowStable(2, 100e6);
        h.warp(61);
        h.repay(0);
        h.movePrice(1_000_000);
        h.liquidate(1);
        h.warp(90);
        h.markDefault(2);
        h.markDefault(1);
        assertEq(h.calls("borrow"), 3, "borrow");
        assertEq(h.calls("repayLate"), 1, "repay");
        assertEq(h.calls("liquidate"), 1, "liquidate");
        assertEq(h.calls("markDefault"), 2, "default");
    }
}
