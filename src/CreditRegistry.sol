// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";

/// @notice Credit history and scoring (docs/spec.md §2).
///
///   E  = Σ_on-time min(1, P·τ / (P̄·T̄))                      history, in reference-loan units
///   F  = w · (late + liquidations + extLiquidations)          failures, as pseudo-counts
///   A  = min(1, walletAge / 1 yr)                              attested
///   PD = (b + F) / (a + g·A + E + b + F)                       Beta(a, b) posterior mean
///   c  = 1 if E < 1, else cMin + (1 − cMin)·min(1, PD / PD0)   PD0 = b / (a + b)
///   premium = PD·(1 − c) / T,   limit = min(Lmax, L0 + m·V)
///
/// V is principal repaid on time, weighted by the fraction of the term it was held, so instant
/// borrow-repay loops grow neither E nor the limit. A default bars the address for good.
contract CreditRegistry is ICreditRegistry, Ownable2Step, EIP712 {
    using SafeCast for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;

    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "Attestation(address borrower,uint64 firstTxTime,uint32 extLiquidations,uint64 issuedAt,uint64 deadline)"
    );

    /// @dev Pseudo-counts and ratios are WAD; `term` is in protocol seconds; amounts in asset units.
    struct Params {
        uint256 a; // prior successes
        uint256 b; // prior failures
        uint256 g; // successes credited for one year of wallet age
        uint256 failWeight; // failures per late repayment or liquidation
        uint256 cMin; // collateral-ratio floor
        uint256 term; // loan term, also the reference term T̄
        uint256 refPrincipal; // P̄
        uint256 baseLimit; // L0
        uint256 limitPerRepaid; // m
        uint256 maxLimit; // Lmax
    }

    struct Record {
        uint128 earned; // E (WAD)
        uint128 repaid; // V (asset units)
        uint32 late;
        uint32 liquidations;
        uint32 extLiquidations; // attested, other protocols
        uint64 firstTxTime; // attested; 0 = unknown
        uint64 attestedAt; // issuedAt of the latest attestation
        bool defaulted;
    }

    struct Attestation {
        address borrower;
        uint64 firstTxTime;
        uint32 extLiquidations;
        uint64 issuedAt;
        uint64 deadline;
    }

    Params public params;
    mapping(address => Record) public records;
    address public pool;
    address public attestor;

    event Attested(address indexed borrower, uint64 firstTxTime, uint32 extLiquidations, uint64 issuedAt);
    event HistoryUpdated(address indexed borrower, uint256 pd, uint256 score);
    event ParamsSet(Params params);
    event AttestorSet(address attestor);
    event PoolSet(address pool);

    error OnlyPool();
    error PoolAlreadySet();
    error InvalidParams();
    error AttestationExpired();
    error StaleAttestation();
    error InvalidAttestation();
    error InvalidSignature();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(address owner_, address attestor_, Params memory params_)
        Ownable(owner_)
        EIP712("CreditRegistry", "1")
    {
        attestor = attestor_;
        _setParams(params_);
        emit AttestorSet(attestor_);
    }

    // ---------------------------------------------------------------- scoring

    function pd(address borrower) public view returns (uint256) {
        Record storage r = records[borrower];
        if (r.defaulted) return WAD;
        Params storage p = params;
        uint256 failures = p.b + p.failWeight * (uint256(r.late) + r.liquidations + r.extLiquidations);
        uint256 successes = p.a + Math.mulDiv(p.g, _ageFraction(r.firstTxTime), WAD) + r.earned;
        return Math.mulDiv(failures, WAD, successes + failures, Math.Rounding.Ceil);
    }

    /// @notice 1000 × (1 − PD), rounded down.
    function score(address borrower) public view returns (uint256) {
        return (WAD - pd(borrower)) * 1000 / WAD;
    }

    function terms(address borrower) public view returns (Terms memory t) {
        Record storage r = records[borrower];
        if (r.defaulted) return Terms({pd: WAD, collateralRatio: WAD, premium: 0, limit: 0});
        Params storage p = params;
        t.pd = pd(borrower);
        t.collateralRatio = _collateralRatio(t.pd, r.earned);
        t.premium = Math.mulDiv(
            Math.mulDiv(t.pd, WAD - t.collateralRatio, WAD, Math.Rounding.Ceil), YEAR, p.term, Math.Rounding.Ceil
        );
        t.limit = Math.min(p.maxLimit, p.baseLimit + Math.mulDiv(p.limitPerRepaid, r.repaid, WAD));
    }

    function isBarred(address borrower) external view returns (bool) {
        return records[borrower].defaulted;
    }

    function term() external view returns (uint256) {
        return params.term;
    }

    function _collateralRatio(uint256 pd_, uint256 earned) internal view returns (uint256) {
        if (earned < WAD) return WAD; // first loan is always fully secured
        Params storage p = params;
        uint256 pd0 = Math.mulDiv(p.b, WAD, p.a + p.b);
        uint256 relative = Math.min(WAD, Math.mulDiv(pd_, WAD, pd0, Math.Rounding.Ceil));
        return p.cMin + Math.mulDiv(WAD - p.cMin, relative, WAD, Math.Rounding.Ceil);
    }

    function _ageFraction(uint64 firstTxTime) internal view returns (uint256) {
        if (firstTxTime == 0 || firstTxTime >= block.timestamp) return 0;
        return Math.min(WAD, (block.timestamp - firstTxTime) * WAD / YEAR);
    }

    // ---------------------------------------------------------------- history (pool only)

    /// @param elapsed protocol seconds the loan was open
    function onRepaid(address borrower, uint256 principal, uint256 elapsed, bool late) external onlyPool {
        Record storage r = records[borrower];
        if (late) {
            r.late += 1;
        } else {
            Params storage p = params;
            uint256 heldFraction = Math.min(WAD, Math.mulDiv(elapsed, WAD, p.term));
            r.earned += Math.min(WAD, principal * heldFraction / p.refPrincipal).toUint128();
            r.repaid += Math.mulDiv(principal, heldFraction, WAD).toUint128();
        }
        _emitHistory(borrower);
    }

    function onLiquidated(address borrower) external onlyPool {
        records[borrower].liquidations += 1;
        _emitHistory(borrower);
    }

    function onDefaulted(address borrower) external onlyPool {
        records[borrower].defaulted = true;
        _emitHistory(borrower);
    }

    function _emitHistory(address borrower) internal {
        uint256 pd_ = pd(borrower);
        emit HistoryUpdated(borrower, pd_, (WAD - pd_) * 1000 / WAD);
    }

    // ---------------------------------------------------------------- attestations

    /// @notice Stores a wallet-age / external-liquidation claim signed by `attestor`. Anyone may submit.
    function submitAttestation(Attestation calldata att, bytes calldata signature) external {
        if (block.timestamp > att.deadline) revert AttestationExpired();
        Record storage r = records[att.borrower];
        if (att.issuedAt <= r.attestedAt || att.extLiquidations < r.extLiquidations) revert StaleAttestation();
        if (att.firstTxTime > block.timestamp) revert InvalidAttestation();
        if (ECDSA.recover(attestationDigest(att), signature) != attestor) revert InvalidSignature();

        r.firstTxTime = att.firstTxTime;
        r.extLiquidations = att.extLiquidations;
        r.attestedAt = att.issuedAt;
        emit Attested(att.borrower, att.firstTxTime, att.extLiquidations, att.issuedAt);
        _emitHistory(att.borrower);
    }

    function attestationDigest(Attestation calldata att) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ATTESTATION_TYPEHASH, att.borrower, att.firstTxTime, att.extLiquidations, att.issuedAt, att.deadline
                )
            )
        );
    }

    // ---------------------------------------------------------------- admin

    function setPool(address pool_) external onlyOwner {
        if (pool != address(0)) revert PoolAlreadySet();
        pool = pool_;
        emit PoolSet(pool_);
    }

    function setAttestor(address attestor_) external onlyOwner {
        attestor = attestor_;
        emit AttestorSet(attestor_);
    }

    function setParams(Params calldata params_) external onlyOwner {
        _setParams(params_);
    }

    function _setParams(Params memory p) internal {
        bool ok = p.a > 0 && p.b > 0 && p.g <= 10 * WAD && p.failWeight <= 10 * WAD && p.cMin >= WAD / 10
            && p.cMin <= WAD && p.term > 0 && p.refPrincipal > 0 && p.limitPerRepaid <= 10 * WAD
            && p.maxLimit >= p.baseLimit;
        if (!ok) revert InvalidParams();
        params = p;
        emit ParamsSet(p);
    }
}
