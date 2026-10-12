// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";
import {IMonPriceOracle} from "./interfaces/IMonPriceOracle.sol";

/// @notice Lender pool (ERC-4626 over the stablecoin) and fixed-term loans priced by `CreditRegistry`.
///
/// Interest is simple and accrues per second of protocol time (`timeScale` protocol seconds per real
/// second; 1 in production, larger for demos). The base rate goes to LPs; the risk premium goes to a
/// first-loss reserve. Total unsecured exposure at origination is capped at `reserveLeverage × reserve`.
/// Defaults absorb losses in order: collateral, reserve, LPs. MON collateral is valued by the oracle at a
/// haircut and, when it falls too far, is sold to a liquidator for stablecoin and the loan continues.
contract CreditPool is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    enum Kind {
        None,
        Stable,
        Mon
    }

    struct Loan {
        uint128 principal;
        uint128 collateral; // asset units (Stable) or MON wei (Mon)
        uint128 unsecured; // asset units not covered by collateral (at origination or after liquidation)
        uint64 start;
        uint64 due;
        uint64 baseRate; // APR (WAD) paid to LPs
        uint64 premium; // APR (WAD) paid to the reserve
        Kind kind;
    }

    /// @dev Rates and ratios are WAD; `grace` is in protocol seconds.
    struct RateParams {
        uint256 baseRate; // r0
        uint256 slope; // r1: base rate added at 100% utilisation
        uint256 maxUtilization;
        uint256 reserveLeverage; // k: total unsecured ≤ k × reserve
        uint256 monHaircut; // h
        uint256 liqThreshold; // θ
        uint256 liqBonus; // discount a liquidator buys MON at
        uint256 grace;
    }

    struct Quote {
        uint256 pd;
        uint256 collateralRatio;
        uint256 baseRate;
        uint256 premium;
        uint256 apr;
        uint256 limit;
        uint256 collateralValue; // required collateral value, asset units (MON: before haircut)
    }

    ICreditRegistry public immutable registry;
    IMonPriceOracle public immutable oracle;
    uint256 public immutable timeScale;
    uint256 internal immutable monToAsset; // MON wei × price WAD / monToAsset = asset units

    RateParams public rateParams;
    bool public borrowingPaused;

    mapping(address => Loan) public loans;

    uint256 public lpCash; // stablecoin owned by LPs and not lent out
    uint256 public totalPrincipal;
    uint256 public sumBaseRate; // Σ principal × baseRate
    uint256 public accruedBase; // LP interest accrued up to `lastAccrual`, not yet paid
    uint256 public lastAccrual;
    uint256 public reserve; // first-loss capital
    uint256 public stableCollateral;
    uint256 public totalUnsecured;

    event Borrowed(
        address indexed borrower,
        Kind kind,
        uint256 principal,
        uint256 collateral,
        uint256 baseRate,
        uint256 premium,
        uint256 due,
        uint256 pd
    );
    event Repaid(address indexed borrower, uint256 principal, uint256 toLPs, uint256 toReserve, bool late);
    event Defaulted(
        address indexed borrower,
        address indexed caller,
        uint256 principal,
        uint256 recovered,
        uint256 reserveCover,
        uint256 lpLoss
    );
    event Liquidated(
        address indexed borrower, address indexed liquidator, uint256 monOut, uint256 stableIn, uint256 price
    );
    event ReserveFunded(address indexed from, uint256 amount);
    event BorrowingPaused(bool paused);
    event RateParamsSet(RateParams params);

    error BorrowingIsPaused();
    error LoanOpen();
    error NoLoan();
    error Barred();
    error ExceedsLimit();
    error UtilizationTooHigh();
    error AprAboveMax();
    error ReserveCapacityExceeded();
    error InsufficientCollateral();
    error NotDefaultable();
    error NotMonLoan();
    error Healthy();
    error WrongFee();
    error MonTransferFailed();
    error InvalidParams();

    constructor(
        IERC20Metadata asset_,
        ICreditRegistry registry_,
        IMonPriceOracle oracle_,
        uint256 timeScale_,
        RateParams memory params_,
        address owner_
    ) ERC4626(asset_) ERC20("Credit Pool mUSDC", "cpUSDC") Ownable(owner_) {
        if (timeScale_ == 0) revert InvalidParams();
        registry = registry_;
        oracle = oracle_;
        timeScale = timeScale_;
        monToAsset = 10 ** (36 - uint256(asset_.decimals()));
        lastAccrual = block.timestamp;
        _setRateParams(params_);
    }

    // ---------------------------------------------------------------- borrower

    function borrowStable(uint256 amount, uint256 maxApr) external nonReentrant {
        (Loan memory loan, ICreditRegistry.Terms memory t) = _originate(amount, maxApr);
        uint256 collateral = Math.mulDiv(amount, t.collateralRatio, WAD, Math.Rounding.Ceil);
        loan.kind = Kind.Stable;
        loan.collateral = collateral.toUint128();
        loan.unsecured = (amount - collateral).toUint128();
        _book(loan, t.pd);
        stableCollateral += collateral;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), collateral);
        IERC20(asset()).safeTransfer(msg.sender, amount);
    }

    /// @notice `msg.value` = MON collateral + the oracle update fee.
    function borrowMon(uint256 amount, uint256 maxApr, bytes[] calldata priceUpdate) external payable nonReentrant {
        uint256 fee = oracle.updateFee(priceUpdate);
        if (msg.value <= fee) revert InsufficientCollateral();
        uint256 price = oracle.updateAndRead{value: fee}(priceUpdate);
        uint256 monIn = msg.value - fee;

        (Loan memory loan, ICreditRegistry.Terms memory t) = _originate(amount, maxApr);
        uint256 required = Math.mulDiv(amount, t.collateralRatio, WAD, Math.Rounding.Ceil);
        uint256 haircutValue = Math.mulDiv(_monValue(monIn, price), WAD - rateParams.monHaircut, WAD);
        if (haircutValue < required) revert InsufficientCollateral();
        loan.kind = Kind.Mon;
        loan.collateral = monIn.toUint128();
        loan.unsecured = (amount - Math.min(amount, haircutValue)).toUint128();
        _book(loan, t.pd);

        IERC20(asset()).safeTransfer(msg.sender, amount);
    }

    /// @notice Repays principal plus interest to date and returns the collateral. Allowed until defaulted.
    function repay() external nonReentrant {
        Loan memory loan = loans[msg.sender];
        if (loan.kind == Kind.None) revert NoLoan();
        _accrue();
        uint256 elapsed = (block.timestamp - loan.start) * timeScale;
        (uint256 baseInterest, uint256 riskInterest) = _interest(loan, elapsed, Math.Rounding.Ceil);
        bool late = block.timestamp > loan.due;

        _unbook(msg.sender, loan, baseInterest);
        lpCash += loan.principal + baseInterest;
        reserve += riskInterest;
        if (loan.kind == Kind.Stable) stableCollateral -= loan.collateral;
        emit Repaid(msg.sender, loan.principal, baseInterest, riskInterest, late);
        registry.onRepaid(msg.sender, loan.principal, elapsed, late);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), loan.principal + baseInterest + riskInterest);
        _returnCollateral(msg.sender, loan);
    }

    // ---------------------------------------------------------------- keepers

    /// @notice After due + grace, anyone can close a loan. MON collateral is sold to the caller at the
    ///         oracle price minus `liqBonus`; `msg.value` must equal the oracle fee (0 for stable loans).
    function markDefault(address borrower, bytes[] calldata priceUpdate) external payable nonReentrant {
        Loan memory loan = loans[borrower];
        if (loan.kind == Kind.None) revert NoLoan();
        if (block.timestamp <= loan.due + Math.ceilDiv(rateParams.grace, timeScale)) revert NotDefaultable();
        _accrue();
        (uint256 baseInterest, uint256 riskInterest) =
            _interest(loan, (block.timestamp - loan.start) * timeScale, Math.Rounding.Floor);

        uint256 recovered;
        if (loan.kind == Kind.Stable) {
            if (msg.value != 0) revert WrongFee();
            recovered = loan.collateral;
            stableCollateral -= loan.collateral;
        } else {
            uint256 price = _readPrice(priceUpdate);
            recovered = Math.mulDiv(_monValue(loan.collateral, price), WAD - rateParams.liqBonus, WAD);
        }

        // Waterfall: LPs' booked value first, then the premium owed to the reserve, then the borrower.
        uint256 lpOwed = loan.principal + baseInterest;
        uint256 toLPs = Math.min(recovered, lpOwed);
        uint256 toReserve = Math.min(recovered - toLPs, riskInterest);
        uint256 surplus = recovered - toLPs - toReserve;
        uint256 cover = Math.min(lpOwed - toLPs, reserve);
        uint256 lpLoss = lpOwed - toLPs - cover;

        _unbook(borrower, loan, baseInterest);
        reserve = reserve - cover + toReserve;
        lpCash += toLPs + cover;
        emit Defaulted(borrower, msg.sender, loan.principal, recovered, cover, lpLoss);
        registry.onDefaulted(borrower);

        if (loan.kind == Kind.Mon) {
            IERC20(asset()).safeTransferFrom(msg.sender, address(this), recovered);
            _sendMon(msg.sender, loan.collateral);
        }
        if (surplus != 0) IERC20(asset()).safeTransfer(borrower, surplus);
    }

    /// @notice When C·p·(1−h) < θ·c·D, anyone buys the MON at the oracle price minus `liqBonus`.
    ///         The stablecoin paid becomes the loan's collateral and the loan continues.
    function liquidate(address borrower, bytes[] calldata priceUpdate) external payable nonReentrant {
        Loan memory loan = loans[borrower];
        if (loan.kind != Kind.Mon) revert NotMonLoan();
        uint256 price = _readPrice(priceUpdate);
        RateParams memory p = rateParams;

        uint256 value = _monValue(loan.collateral, price);
        (uint256 baseInterest, uint256 riskInterest) =
            _interest(loan, (block.timestamp - loan.start) * timeScale, Math.Rounding.Floor);
        uint256 securedDebt = Math.mulDiv( // c·D, with c·P recorded at origination
            loan.principal - loan.unsecured,
            loan.principal + baseInterest + riskInterest,
            loan.principal
        );
        if (Math.mulDiv(value, WAD - p.monHaircut, WAD) >= Math.mulDiv(securedDebt, p.liqThreshold, WAD)) {
            revert Healthy();
        }

        uint256 stableIn = Math.mulDiv(value, WAD - p.liqBonus, WAD);
        uint256 unsecured = loan.principal - Math.min(loan.principal, stableIn);
        totalUnsecured = totalUnsecured - loan.unsecured + unsecured;
        stableCollateral += stableIn;
        Loan storage stored = loans[borrower];
        stored.kind = Kind.Stable;
        stored.collateral = stableIn.toUint128();
        stored.unsecured = unsecured.toUint128();
        emit Liquidated(borrower, msg.sender, loan.collateral, stableIn, price);
        registry.onLiquidated(borrower);

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), stableIn);
        _sendMon(msg.sender, loan.collateral);
    }

    // ---------------------------------------------------------------- reserve and admin

    /// @notice Adds first-loss capital. It is not withdrawable.
    function fundReserve(uint256 amount) external nonReentrant {
        reserve += amount;
        emit ReserveFunded(msg.sender, amount);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Pauses new loans only; repay, withdraw, default and liquidate always work.
    function setBorrowingPaused(bool paused) external onlyOwner {
        borrowingPaused = paused;
        emit BorrowingPaused(paused);
    }

    function setRateParams(RateParams calldata params_) external onlyOwner {
        _setRateParams(params_);
    }

    function _setRateParams(RateParams memory p) internal {
        bool ok = p.baseRate <= WAD && p.slope <= WAD && p.maxUtilization <= WAD && p.reserveLeverage <= 3 * WAD
            && p.monHaircut < WAD && p.liqThreshold <= WAD && p.liqBonus <= WAD / 5 && p.grace <= 30 days;
        if (!ok) revert InvalidParams();
        rateParams = p;
        emit RateParamsSet(p);
    }

    // ---------------------------------------------------------------- views

    function quote(address borrower, uint256 amount) external view returns (Quote memory q) {
        ICreditRegistry.Terms memory t = registry.terms(borrower);
        q.pd = t.pd;
        q.collateralRatio = t.collateralRatio;
        q.baseRate = _baseRateAfter(amount);
        q.premium = t.premium;
        q.apr = q.baseRate + q.premium;
        q.limit = t.limit;
        q.collateralValue = Math.mulDiv(amount, t.collateralRatio, WAD, Math.Rounding.Ceil);
    }

    /// @return total amount `repay()` would pull now (principal + interest)
    function debtOf(address borrower)
        external
        view
        returns (uint256 total, uint256 baseInterest, uint256 riskInterest)
    {
        Loan memory loan = loans[borrower];
        if (loan.kind == Kind.None) return (0, 0, 0);
        (baseInterest, riskInterest) = _interest(loan, (block.timestamp - loan.start) * timeScale, Math.Rounding.Ceil);
        total = loan.principal + baseInterest + riskInterest;
    }

    function utilization() public view returns (uint256) {
        uint256 book = lpCash + totalPrincipal;
        return book == 0 ? 0 : Math.mulDiv(totalPrincipal, WAD, book);
    }

    // ---------------------------------------------------------------- ERC-4626

    function totalAssets() public view override returns (uint256) {
        return lpCash + totalPrincipal + _accruedNow();
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), lpCash);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(lpCash, Math.Rounding.Floor));
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        lpCash += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        lpCash -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    // ---------------------------------------------------------------- internals

    function _originate(uint256 amount, uint256 maxApr)
        internal
        returns (Loan memory loan, ICreditRegistry.Terms memory t)
    {
        if (borrowingPaused) revert BorrowingIsPaused();
        if (loans[msg.sender].kind != Kind.None) revert LoanOpen();
        if (registry.isBarred(msg.sender)) revert Barred();
        t = registry.terms(msg.sender);
        if (amount == 0 || amount > t.limit) revert ExceedsLimit();

        _accrue();
        uint256 book = lpCash + totalPrincipal;
        if (
            amount > lpCash
                || Math.mulDiv(totalPrincipal + amount, WAD, book, Math.Rounding.Ceil) > rateParams.maxUtilization
        ) {
            revert UtilizationTooHigh();
        }
        uint256 baseRate = _baseRateAfter(amount);
        if (baseRate + t.premium > maxApr) revert AprAboveMax();

        loan.principal = amount.toUint128();
        loan.start = block.timestamp.toUint64();
        loan.due = (block.timestamp + Math.ceilDiv(registry.term(), timeScale)).toUint64();
        loan.baseRate = baseRate.toUint64();
        loan.premium = t.premium.toUint64();
    }

    function _book(Loan memory loan, uint256 pd) internal {
        if (totalUnsecured + loan.unsecured > Math.mulDiv(reserve, rateParams.reserveLeverage, WAD)) {
            revert ReserveCapacityExceeded();
        }
        loans[msg.sender] = loan;
        totalPrincipal += loan.principal;
        sumBaseRate += uint256(loan.principal) * loan.baseRate;
        totalUnsecured += loan.unsecured;
        lpCash -= loan.principal;
        emit Borrowed(msg.sender, loan.kind, loan.principal, loan.collateral, loan.baseRate, loan.premium, loan.due, pd);
    }

    function _unbook(address borrower, Loan memory loan, uint256 baseInterest) internal {
        delete loans[borrower];
        totalPrincipal -= loan.principal;
        sumBaseRate -= uint256(loan.principal) * loan.baseRate;
        accruedBase -= Math.min(accruedBase, baseInterest);
        totalUnsecured -= loan.unsecured;
    }

    function _baseRateAfter(uint256 amount) internal view returns (uint256) {
        uint256 book = lpCash + totalPrincipal;
        uint256 u = book == 0 ? WAD : Math.min(WAD, Math.mulDiv(totalPrincipal + amount, WAD, book, Math.Rounding.Ceil));
        return rateParams.baseRate + Math.mulDiv(rateParams.slope, u, WAD, Math.Rounding.Ceil);
    }

    function _interest(Loan memory loan, uint256 elapsed, Math.Rounding rounding)
        internal
        pure
        returns (uint256 baseInterest, uint256 riskInterest)
    {
        baseInterest = Math.mulDiv(uint256(loan.principal) * loan.baseRate, elapsed, YEAR * WAD, rounding);
        riskInterest = Math.mulDiv(uint256(loan.principal) * loan.premium, elapsed, YEAR * WAD, rounding);
    }

    function _accruedNow() internal view returns (uint256) {
        return accruedBase + Math.mulDiv(sumBaseRate, (block.timestamp - lastAccrual) * timeScale, YEAR * WAD);
    }

    function _accrue() internal {
        accruedBase = _accruedNow();
        lastAccrual = block.timestamp;
    }

    function _readPrice(bytes[] calldata priceUpdate) internal returns (uint256) {
        uint256 fee = oracle.updateFee(priceUpdate);
        if (msg.value != fee) revert WrongFee();
        return oracle.updateAndRead{value: fee}(priceUpdate);
    }

    function _monValue(uint256 monAmount, uint256 priceWad) internal view returns (uint256) {
        return Math.mulDiv(monAmount, priceWad, monToAsset);
    }

    function _returnCollateral(address to, Loan memory loan) internal {
        if (loan.kind == Kind.Stable) IERC20(asset()).safeTransfer(to, loan.collateral);
        else _sendMon(to, loan.collateral);
    }

    function _sendMon(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert MonTransferFailed();
    }
}
