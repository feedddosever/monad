// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {MonPriceOracle} from "../src/MonPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {SeedDemo} from "../script/SeedDemo.s.sol";
import {MockPyth} from "./mocks/MockPyth.sol";
import {Params} from "../script/Params.sol";

/// @notice Runs the SeedDemo state machine locally, ticking every 5 s like scripts/seed-demo.sh.
contract SeedDemoTest is Test {
    uint256 internal constant FUNDER_KEY = 0xF00D;

    MockUSDC internal usdc;
    CreditRegistry internal registry;
    CreditPool internal pool;
    string internal deploymentFile;

    function setUp() public {
        vm.chainId(31_337); // keep test output away from deployments/testnet.json
        vm.warp(1_800_000_000);
        address funder = vm.addr(FUNDER_KEY);
        vm.deal(funder, 10 ether);

        vm.startPrank(funder);
        usdc = new MockUSDC();
        registry = new CreditRegistry(funder, funder, Params.registry());
        MonPriceOracle oracle =
            new MonPriceOracle(IPyth(address(new MockPyth())), bytes32(0), Params.ORACLE_MAX_AGE, 200);
        pool = new CreditPool(usdc, registry, oracle, Params.DEMO_TIME_SCALE, Params.rates(), funder);
        registry.setPool(address(pool));
        usdc.mint(funder, 11_000e6);
        usdc.approve(address(pool), 11_000e6);
        pool.fundReserve(1_000e6);
        pool.deposit(10_000e6, funder);
        vm.stopPrank();

        string memory key = "d";
        vm.serializeAddress(key, "MockUSDC", address(usdc));
        vm.serializeAddress(key, "CreditRegistry", address(registry));
        string memory json = vm.serializeAddress(key, "CreditPool", address(pool));
        deploymentFile = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, deploymentFile);
        vm.setEnv("PRIVATE_KEY", vm.toString(FUNDER_KEY));
    }

    function test_SeedReachesThreeDistinctProfiles() public {
        SeedDemo seed = new SeedDemo();
        uint256 ticks;
        while (ticks < 100 && !_done()) {
            seed.run();
            skip(5);
            ++ticks;
        }
        vm.removeFile(deploymentFile);

        uint256 good = registry.score(_wallet("good-payer"));
        uint256 fresh = registry.score(_wallet("new-wallet"));
        uint256 late = registry.score(_wallet("late-payer"));
        emit log_named_uint("ticks", ticks);
        emit log_named_uint("good-payer score", good);
        emit log_named_uint("new-wallet score", fresh);
        emit log_named_uint("late-payer score", late);
        assertTrue(_done(), "seeding finished");
        assertGt(good, fresh);
        assertGt(fresh, late);
        assertEq(fresh, 800);
        assertLt(registry.terms(_wallet("good-payer")).collateralRatio, 1e18, "good payer is partly unsecured");
        (uint128 goodEarned,, uint32 goodLate,,,,,) = registry.records(_wallet("good-payer"));
        assertEq(goodLate, 0, "good payer never late");
        assertEq(goodEarned, 3e18, "three loans held past 75% of the term earn full credit");
        assertEq(usdc.balanceOf(address(pool)), pool.lpCash() + pool.reserve() + pool.stableCollateral());
    }

    function _done() internal view returns (bool) {
        (uint128 goodOpen,,,,,,,) = pool.loans(_wallet("good-payer"));
        (uint128 lateOpen,,,,,,,) = pool.loans(_wallet("late-payer"));
        (uint128 earned,,,,,,,) = registry.records(_wallet("good-payer"));
        (,, uint32 late,,,,,) = registry.records(_wallet("late-payer"));
        return goodOpen == 0 && lateOpen == 0 && earned >= 3e18 && late >= 1;
    }

    function _wallet(string memory label) internal pure returns (address) {
        return vm.addr(
            uint256(keccak256(abi.encodePacked(FUNDER_KEY, "monad-metropolis-seed:", label))) % (SECP256K1_ORDER - 1)
                + 1
        );
    }
}
