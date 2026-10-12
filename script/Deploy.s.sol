// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {MonPriceOracle} from "../src/MonPriceOracle.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";
import {GasLimits, Params} from "./Params.sol";

/// @notice Deploys mUSDC, the registry, the Pyth adapter and the pool; seeds the reserve and LP liquidity;
///         on a real broadcast writes the addresses to deployments/<network>.json.
///
///   scripts/deploy-testnet.sh        # broadcast with gas headroom, verify on Sourcify, collect tx hashes
///
/// Local fork: foundry.toml pins chain_id = 10143, which also overrides block.chainid, so run local scripts with
/// FOUNDRY_CHAIN_ID=31337 (writes deployments/31337.json, gitignored) or they would overwrite the testnet files.
///
/// Signer: PRIVATE_KEY from .env if set (read in-script, never printed), else the --account keystore.
/// Optional env: ATTESTOR_ADDRESS (default: deployer), TIME_SCALE (default 43,200), PYTH_ADDRESS,
/// MON_USD_FEED, RESERVE_SEED (default 1,000 mUSDC), LIQUIDITY_SEED (default 10,000 mUSDC).
contract Deploy is Script {
    function run() external {
        address deployer = _startBroadcast();

        address attestor = vm.envOr("ATTESTOR_ADDRESS", deployer);
        uint256 timeScale = vm.envOr("TIME_SCALE", Params.DEMO_TIME_SCALE);
        address pyth = vm.envOr("PYTH_ADDRESS", Params.PYTH_TESTNET);
        bytes32 feed = vm.envOr("MON_USD_FEED", Params.MON_USD_FEED);
        uint256 reserveSeed = vm.envOr("RESERVE_SEED", uint256(1_000e6));
        uint256 liquiditySeed = vm.envOr("LIQUIDITY_SEED", uint256(10_000e6));

        // Creations: gas = forge estimate x --gas-estimate-multiplier (Solidity has no gas option for `new`).
        MockUSDC usdc = new MockUSDC();
        CreditRegistry registry = new CreditRegistry(deployer, attestor, Params.registry());
        MonPriceOracle oracle = new MonPriceOracle(IPyth(pyth), feed, Params.ORACLE_MAX_AGE, Params.ORACLE_MAX_CONF_BPS);
        CreditPool pool = new CreditPool(usdc, registry, oracle, timeScale, Params.rates(), deployer);

        // Calls: explicit limits, because Monad charges the limit.
        registry.setPool{gas: GasLimits.SET_POOL}(address(pool));
        usdc.mint{gas: GasLimits.MINT}(deployer, reserveSeed + liquiditySeed);
        usdc.approve{gas: GasLimits.APPROVE}(address(pool), reserveSeed + liquiditySeed);
        pool.fundReserve{gas: GasLimits.FUND_RESERVE}(reserveSeed);
        pool.deposit{gas: GasLimits.DEPOSIT}(liquiditySeed, deployer);
        vm.stopBroadcast();

        console.log("CreditPool     ", address(pool));
        console.log("CreditRegistry ", address(registry));
        console.log("MonPriceOracle ", address(oracle));
        console.log("MockUSDC       ", address(usdc));
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return; // dry run: don't record addresses

        string memory key = "deployment";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "deployBlock", block.number);
        vm.serializeUint(key, "timeScale", timeScale);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "attestor", attestor);
        vm.serializeAddress(key, "MockUSDC", address(usdc));
        vm.serializeAddress(key, "CreditRegistry", address(registry));
        vm.serializeAddress(key, "MonPriceOracle", address(oracle));
        string memory json = vm.serializeAddress(key, "CreditPool", address(pool));
        string memory path = deploymentPath();
        vm.writeJson(json, path);
        console.log("written to", path);
    }

    function _startBroadcast() internal returns (address deployer) {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk != 0) {
            vm.startBroadcast(pk);
        } else {
            vm.startBroadcast();
        }
        (, deployer,) = vm.readCallers();
    }

    function deploymentPath() public view returns (string memory) {
        string memory name =
            block.chainid == 10143 ? "testnet" : block.chainid == 143 ? "mainnet" : vm.toString(block.chainid);
        return string.concat("deployments/", name, ".json");
    }
}
