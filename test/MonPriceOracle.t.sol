// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MonPriceOracle} from "../src/MonPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

contract MonPriceOracleTest is Test {
    MockPyth internal pyth;
    MonPriceOracle internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pyth = new MockPyth();
        pyth.setFee(7);
        pyth.setPrice(2_500_000, 1_000, -8); // $0.025 ± 0.04%
        oracle = new MonPriceOracle(IPyth(address(pyth)), bytes32("MON/USD"), 60, 200);
    }

    function test_UpdateFee() public view {
        assertEq(oracle.updateFee(new bytes[](0)), 0);
        assertEq(oracle.updateFee(_update(1, 0, -8)), 7);
    }

    function test_ReadStoredPriceWithoutUpdate() public {
        assertEq(oracle.updateAndRead(new bytes[](0)), 0.025e18);
    }

    function test_UpdateThenRead() public {
        assertEq(oracle.updateAndRead{value: 7}(_update(3_000_000, 100, -8)), 0.03e18);
    }

    function testFuzz_ScalesAnyExponent(uint32 price, uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 18));
        vm.assume(price > 0);
        int32 expo = -int32(uint32(decimals));
        uint256 got = oracle.updateAndRead{value: 7}(_update(int64(uint64(price)), 0, expo));
        assertEq(got, uint256(price) * 10 ** (18 - decimals));
    }

    function test_RevertWhen_WrongFee() public {
        bytes[] memory u = _update(3_000_000, 100, -8);
        vm.expectRevert(MonPriceOracle.WrongFee.selector);
        oracle.updateAndRead{value: 6}(u);
        vm.expectRevert(MonPriceOracle.WrongFee.selector);
        oracle.updateAndRead{value: 1}(new bytes[](0));
    }

    function test_RevertWhen_Stale() public {
        skip(61);
        vm.expectRevert(MockPyth.StalePrice.selector);
        oracle.updateAndRead(new bytes[](0));
    }

    function test_RevertWhen_NonPositiveOrBadExponent() public {
        bytes[] memory zero = _update(0, 0, -8);
        vm.expectRevert(MonPriceOracle.InvalidPrice.selector);
        oracle.updateAndRead{value: 7}(zero);

        bytes[] memory positiveExpo = _update(1, 0, 1);
        vm.expectRevert(MonPriceOracle.InvalidPrice.selector);
        oracle.updateAndRead{value: 7}(positiveExpo);

        bytes[] memory tinyExpo = _update(1, 0, -19);
        vm.expectRevert(MonPriceOracle.InvalidPrice.selector);
        oracle.updateAndRead{value: 7}(tinyExpo);
    }

    function test_RevertWhen_ConfidenceTooWide() public {
        bytes[] memory wide = _update(1_000_000, 20_001, -8); // conf > 2% of price
        vm.expectRevert(MonPriceOracle.PriceTooUncertain.selector);
        oracle.updateAndRead{value: 7}(wide);

        assertEq(oracle.updateAndRead{value: 7}(_update(1_000_000, 20_000, -8)), 0.01e18, "exactly 2% is accepted");
    }

    function _update(int64 price, uint64 conf, int32 expo) internal pure returns (bytes[] memory u) {
        u = new bytes[](1);
        u[0] = abi.encode(price, conf, expo);
    }
}

contract MockUSDCTest is Test {
    function test_MintAndDecimals() public {
        MockUSDC usdc = new MockUSDC();
        usdc.mint(address(1), 100_000e6);
        assertEq(usdc.balanceOf(address(1)), 100_000e6);
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.symbol(), "mUSDC");
    }

    function test_RevertWhen_MintAboveCap() public {
        MockUSDC usdc = new MockUSDC();
        vm.expectRevert(MockUSDC.MintTooLarge.selector);
        usdc.mint(address(1), 100_000e6 + 1);
    }
}
