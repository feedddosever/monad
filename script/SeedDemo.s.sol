// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CreditPool} from "../src/CreditPool.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {GasLimits} from "./Params.sol";

/// @notice One tick of the demo seeding state machine. Real time must pass between a borrow and its repayment
///         (a 30-day term lasts 60 s on the demo clock), so scripts/seed-demo.sh re-runs this every few seconds
///         until it prints SEED_DONE. Each tick reads chain state and sends only the transactions that are due.
///
/// Three wallets are derived from PRIVATE_KEY (keys never printed):
///   good-payer  three loans, each repaid on time after holding it 40 of 60 s  -> score ~934, collateral ~50%
///   new-wallet  funded, no history                                           -> score 800, collateral 100%
///   late-payer  one loan repaid after the due time                           -> score ~571, collateral 100%
contract SeedDemo is Script {
    uint256 internal constant GAS_MON = 0.6 ether; // per wallet; covers ~15 txs charged at their gas limits
    uint256 internal constant STABLE_FLOAT = 2_000e6;
    uint256 internal constant HOLD_SECONDS = 40; // repay 40 s into a 60 s term: on time with 20 s of slack
    uint256 internal constant GOOD_TARGET_EARNED = 2.4e18; // ~3 loans

    struct Wallet {
        string label;
        uint256 key;
        address addr;
    }

    CreditPool internal pool;
    CreditRegistry internal registry;
    MockUSDC internal usdc;
    uint256 internal funderKey;

    function run() external {
        funderKey = vm.envUint("PRIVATE_KEY");
        string memory json = vm.readFile(deploymentPath());
        pool = CreditPool(vm.parseJsonAddress(json, ".CreditPool"));
        registry = CreditRegistry(vm.parseJsonAddress(json, ".CreditRegistry"));
        usdc = MockUSDC(vm.parseJsonAddress(json, ".MockUSDC"));

        Wallet memory good = _wallet("good-payer");
        Wallet memory fresh = _wallet("new-wallet");
        Wallet memory late = _wallet("late-payer");
        _prepare(good);
        _prepare(fresh);
        _prepare(late);

        bool goodDone = _tickGoodPayer(good);
        bool lateDone = _tickLatePayer(late);

        _report(good);
        _report(fresh);
        _report(late);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _writeWallets(good, fresh, late);
        console.log(goodDone && lateDone ? "SEED_DONE" : "SEED_PENDING");
    }

    // ---------------------------------------------------------------- behaviours

    function _tickGoodPayer(Wallet memory w) internal returns (bool done) {
        (uint128 principal,,, uint64 start,,,,) = pool.loans(w.addr);
        if (principal != 0) {
            // Ticks run every few seconds, so this lands 40-50 s into the 60 s term: on time, ~67% held.
            if (block.timestamp >= start + HOLD_SECONDS) _repay(w);
            return false;
        }
        (uint128 earned,,,,,,,) = registry.records(w.addr);
        if (earned >= GOOD_TARGET_EARNED) return true;
        _borrow(w, registry.terms(w.addr).limit);
        return false;
    }

    function _tickLatePayer(Wallet memory w) internal returns (bool done) {
        (uint128 principal,,,, uint64 due,,,) = pool.loans(w.addr);
        (,, uint32 lateCount,,,,,) = registry.records(w.addr);
        if (principal != 0) {
            if (block.timestamp > due) _repay(w); // after due, before anyone marks a default
            return false;
        }
        if (lateCount >= 1) return true;
        _borrow(w, 100e6);
        return false;
    }

    // ---------------------------------------------------------------- transactions

    function _prepare(Wallet memory w) internal {
        if (w.addr.balance < GAS_MON / 2) {
            vm.broadcast(funderKey);
            (bool ok,) = payable(w.addr).call{value: GAS_MON - w.addr.balance, gas: GasLimits.SEND_MON}("");
            require(ok, "fund MON");
        }
        if (usdc.balanceOf(w.addr) < STABLE_FLOAT / 2) {
            vm.broadcast(funderKey);
            usdc.mint{gas: GasLimits.MINT}(w.addr, STABLE_FLOAT);
        }
        if (usdc.allowance(w.addr, address(pool)) < STABLE_FLOAT) {
            vm.broadcast(w.key);
            usdc.approve{gas: GasLimits.APPROVE}(address(pool), type(uint256).max);
        }
    }

    function _borrow(Wallet memory w, uint256 amount) internal {
        CreditPool.Quote memory q = pool.quote(w.addr, amount);
        vm.broadcast(w.key);
        pool.borrowStable{gas: GasLimits.BORROW_STABLE}(amount, q.apr);
        console.log(string.concat(w.label, " borrowed"), amount);
    }

    function _repay(Wallet memory w) internal {
        vm.broadcast(w.key);
        pool.repay{gas: GasLimits.REPAY}();
        console.log(string.concat(w.label, " repaid"));
    }

    // ---------------------------------------------------------------- helpers

    function _wallet(string memory label) internal view returns (Wallet memory w) {
        w.label = label;
        w.key = uint256(keccak256(abi.encodePacked(funderKey, "monad-metropolis-seed:", label))) % (SECP256K1_ORDER - 1)
            + 1;
        w.addr = vm.addr(w.key);
    }

    function _report(Wallet memory w) internal view {
        console.log(w.label, w.addr, "score", registry.score(w.addr));
    }

    function _writeWallets(Wallet memory good, Wallet memory fresh, Wallet memory late) internal {
        string memory key = "wallets";
        vm.serializeAddress(key, good.label, good.addr);
        vm.serializeAddress(key, fresh.label, fresh.addr);
        string memory json = vm.serializeAddress(key, late.label, late.addr);
        vm.writeJson(json, "deployments/demo-wallets.json");
    }

    function deploymentPath() public view returns (string memory) {
        return block.chainid == 10143
            ? "deployments/testnet.json"
            : string.concat("deployments/", vm.toString(block.chainid), ".json");
    }
}
