// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {MonPriceOracle} from "../src/MonPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {Params} from "./Params.sol";

/// @notice Deploys mUSDC, the registry, the Pyth adapter and the pool; seeds the reserve and LP liquidity;
///         writes the addresses to deployments/<chainId>.json.
///
///   forge script script/Deploy.s.sol --broadcast                          # Monad Testnet (account from .env)
///
/// Env (all optional): ATTESTOR_ADDRESS (default: deployer), TIME_SCALE (default 43,200),
/// PYTH_ADDRESS, MON_USD_FEED, RESERVE_SEED (default 1,000 mUSDC), LIQUIDITY_SEED (default 10,000 mUSDC).
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address attestor = vm.envOr("ATTESTOR_ADDRESS", deployer);
        uint256 timeScale = vm.envOr("TIME_SCALE", Params.DEMO_TIME_SCALE);
        address pyth = vm.envOr("PYTH_ADDRESS", Params.PYTH_TESTNET);
        bytes32 feed = vm.envOr("MON_USD_FEED", Params.MON_USD_FEED);
        uint256 reserveSeed = vm.envOr("RESERVE_SEED", uint256(1_000e6));
        uint256 liquiditySeed = vm.envOr("LIQUIDITY_SEED", uint256(10_000e6));

        MockUSDC usdc = new MockUSDC();
        CreditRegistry registry = new CreditRegistry(deployer, attestor, Params.registry());
        MonPriceOracle oracle = new MonPriceOracle(IPyth(pyth), feed, Params.ORACLE_MAX_AGE, Params.ORACLE_MAX_CONF_BPS);
        CreditPool pool = new CreditPool(usdc, registry, oracle, timeScale, Params.rates(), deployer);
        registry.setPool(address(pool));

        usdc.mint(deployer, reserveSeed + liquiditySeed);
        usdc.approve(address(pool), reserveSeed + liquiditySeed);
        pool.fundReserve(reserveSeed);
        pool.deposit(liquiditySeed, deployer);
        vm.stopBroadcast();

        console.log("CreditPool     ", address(pool));
        console.log("CreditRegistry ", address(registry));
        console.log("MonPriceOracle ", address(oracle));
        console.log("MockUSDC       ", address(usdc));
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return; // dry run: don't record addresses

        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "timeScale", timeScale);
        vm.serializeAddress(key, "attestor", attestor);
        vm.serializeAddress(key, "MockUSDC", address(usdc));
        vm.serializeAddress(key, "CreditRegistry", address(registry));
        vm.serializeAddress(key, "MonPriceOracle", address(oracle));
        string memory json = vm.serializeAddress(key, "CreditPool", address(pool));
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("written to", path);
    }
}
