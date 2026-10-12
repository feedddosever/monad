// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {ICreditRegistry} from "../src/interfaces/ICreditRegistry.sol";
import {Params} from "../script/Params.sol";

contract CreditRegistryTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TERM = 30 days;

    CreditRegistry internal registry;
    uint256 internal attestorKey = 0xA77E57;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        registry = new CreditRegistry(address(this), vm.addr(attestorKey), Params.registry());
        registry.setPool(address(this)); // this test acts as the pool
    }

    // ---------------------------------------------------------------- spec worked example

    function test_Newcomer() public view {
        ICreditRegistry.Terms memory t = registry.terms(alice);
        assertEq(t.pd, 0.2e18, "PD0 = b / (a + b)");
        assertEq(registry.score(alice), 800);
        assertEq(t.collateralRatio, WAD, "first loan fully secured");
        assertEq(t.premium, 0);
        assertEq(t.limit, 100e6);
    }

    function test_AttestedOneYearWallet() public {
        _attest(alice, uint64(block.timestamp - 365 days), 0);
        assertApproxEqRel(registry.pd(alice), 0.111111e18, 1e13); // 0.25 / 2.25
        assertEq(registry.score(alice), 888); // 1000·(1 − 0.1111…) rounded down
        assertEq(registry.terms(alice).collateralRatio, WAD, "age alone never unsecures");
    }

    function test_WorkedExampleTable() public {
        _attest(alice, uint64(block.timestamp - 365 days), 0);

        _repayReferenceLoans(alice, 1);
        ICreditRegistry.Terms memory t = registry.terms(alice);
        assertApproxEqRel(t.pd, 0.076923e18, 1e13, "E=1 PD"); // 0.25 / 3.25
        assertApproxEqRel(t.collateralRatio, 0.538462e18, 1e13, "E=1 c");
        assertApproxEqRel(t.premium, 0.431953e18, 1e13, "E=1 premium"); // PD(1-c)·365/30
        assertEq(t.limit, 150e6);

        _repayReferenceLoans(alice, 9);
        t = registry.terms(alice);
        assertApproxEqRel(t.pd, 0.020408e18, 1e13, "E=10 PD"); // 0.25 / 12.25
        assertApproxEqRel(t.collateralRatio, 0.326531e18, 1e13, "E=10 c");
        assertApproxEqRel(t.premium, 0.167222e18, 1e13, "E=10 premium");
        assertEq(t.limit, 600e6);
        assertEq(registry.score(alice), 979); // 1000·(1 − 0.0204…) rounded down
    }

    function test_LateAndLiquidationAreHalfFailures() public {
        _attest(alice, uint64(block.timestamp - 365 days), 0);
        _repayReferenceLoans(alice, 10);
        registry.onRepaid(alice, 100e6, TERM, true);
        registry.onLiquidated(alice);
        ICreditRegistry.Terms memory t = registry.terms(alice);
        assertApproxEqRel(t.pd, 0.09434e18, 1e13); // 1.25 / 13.25
        assertApproxEqRel(t.collateralRatio, 0.603774e18, 1e13);
        assertEq(t.limit, 600e6, "late repayment adds no limit");
    }

    // ---------------------------------------------------------------- anti-gaming

    function test_ShortOrSmallLoansEarnProportionally() public {
        registry.onRepaid(alice, 50e6, TERM / 2, false);
        (uint128 earned, uint128 repaid,,,,,,) = registry.records(alice);
        assertEq(earned, 0.25e18, "50% principal x 50% term");
        assertEq(repaid, 25e6, "V is time-weighted");
    }

    function test_InstantRepayEarnsNothing() public {
        for (uint256 i; i < 50; ++i) {
            registry.onRepaid(alice, 100e6, 0, false);
        }
        (uint128 earned, uint128 repaid,,,,,,) = registry.records(alice);
        assertEq(earned, 0);
        assertEq(repaid, 0);
        assertEq(registry.terms(alice).collateralRatio, WAD);
    }

    function test_BigLoanEarnsAtMostOneUnit() public {
        registry.onRepaid(alice, 5000e6, TERM, false);
        (uint128 earned,,,,,,,) = registry.records(alice);
        assertEq(earned, WAD);
    }

    function test_DefaultBars() public {
        _repayReferenceLoans(alice, 5);
        registry.onDefaulted(alice);
        assertTrue(registry.isBarred(alice));
        assertEq(registry.pd(alice), WAD);
        assertEq(registry.score(alice), 0);
        assertEq(registry.terms(alice).limit, 0);
    }

    function test_RevertWhen_NotPool() public {
        vm.prank(alice);
        vm.expectRevert(CreditRegistry.OnlyPool.selector);
        registry.onRepaid(alice, 100e6, TERM, false);
    }

    // ---------------------------------------------------------------- attestations

    function test_RevertWhen_WrongSigner() public {
        CreditRegistry.Attestation memory att = _att(alice, uint64(block.timestamp - 100 days), 0, 1);
        bytes memory sig = _sign(0xBAD, att);
        vm.expectRevert(CreditRegistry.InvalidSignature.selector);
        registry.submitAttestation(att, sig);
    }

    function test_RevertWhen_Expired() public {
        CreditRegistry.Attestation memory att = _att(alice, uint64(block.timestamp - 100 days), 0, 1);
        bytes memory sig = _sign(attestorKey, att);
        vm.warp(att.deadline + 1);
        vm.expectRevert(CreditRegistry.AttestationExpired.selector);
        registry.submitAttestation(att, sig);
    }

    function test_RevertWhen_Replayed() public {
        CreditRegistry.Attestation memory att = _att(alice, uint64(block.timestamp - 100 days), 0, 1);
        bytes memory sig = _sign(attestorKey, att);
        registry.submitAttestation(att, sig);
        vm.expectRevert(CreditRegistry.StaleAttestation.selector);
        registry.submitAttestation(att, sig);
    }

    function test_RevertWhen_ExtLiquidationsRolledBack() public {
        _attest(alice, uint64(block.timestamp - 100 days), 2);
        CreditRegistry.Attestation memory att = _att(alice, uint64(block.timestamp - 100 days), 1, 2);
        bytes memory sig = _sign(attestorKey, att);
        vm.expectRevert(CreditRegistry.StaleAttestation.selector);
        registry.submitAttestation(att, sig);
    }

    function test_ExtLiquidationsRaisePd() public {
        uint256 before = registry.pd(alice);
        _attest(alice, 0, 2);
        assertGt(registry.pd(alice), before);
    }

    // ---------------------------------------------------------------- properties

    function testFuzz_PdFallsAndCollateralBoundedAsHistoryGrows(uint8 loans, uint32 ageDays, uint8 lates) public {
        ageDays = uint32(bound(ageDays, 0, 3650));
        if (ageDays != 0) _attest(alice, uint64(block.timestamp - uint256(ageDays) * 1 days), 0);
        for (uint256 i; i < lates % 5; ++i) {
            registry.onRepaid(alice, 100e6, TERM, true);
        }
        uint256 prevPd = registry.pd(alice);
        for (uint256 i; i < loans % 40; ++i) {
            registry.onRepaid(alice, 100e6, TERM, false);
            ICreditRegistry.Terms memory t = registry.terms(alice);
            assertLt(t.pd, prevPd, "PD strictly falls with each on-time loan");
            assertGe(t.collateralRatio, 0.25e18);
            assertLe(t.collateralRatio, WAD);
            assertLe(t.limit, 5000e6);
            prevPd = t.pd;
        }
    }

    // ---------------------------------------------------------------- helpers

    function _repayReferenceLoans(address who, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            registry.onRepaid(who, 100e6, TERM, false);
        }
    }

    function _attest(address who, uint64 firstTxTime, uint32 extLiq) internal {
        (,,,,,, uint64 attestedAt,) = registry.records(who);
        CreditRegistry.Attestation memory att = _att(who, firstTxTime, extLiq, attestedAt + 1);
        registry.submitAttestation(att, _sign(attestorKey, att));
    }

    function _att(address who, uint64 firstTxTime, uint32 extLiq, uint64 issuedAt)
        internal
        view
        returns (CreditRegistry.Attestation memory)
    {
        return CreditRegistry.Attestation({
            borrower: who,
            firstTxTime: firstTxTime,
            extLiquidations: extLiq,
            issuedAt: issuedAt,
            deadline: uint64(block.timestamp + 1 hours)
        });
    }

    function _sign(uint256 key, CreditRegistry.Attestation memory att) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, registry.attestationDigest(att));
        return abi.encodePacked(r, s, v);
    }
}
