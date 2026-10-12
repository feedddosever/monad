// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMonPriceOracle} from "./interfaces/IMonPriceOracle.sol";
import {IPyth} from "./interfaces/IPyth.sol";

/// @notice Pyth MON/USD adapter. Pyth is a pull oracle (its stored testnet price can be days old),
///         so every read applies the update the caller fetched from Hermes in the same transaction.
contract MonPriceOracle is IMonPriceOracle {
    uint256 internal constant BPS = 10_000;

    IPyth public immutable pyth;
    bytes32 public immutable priceId;
    uint256 public immutable maxAge; // seconds
    uint256 public immutable maxConfBps; // max confidence interval as a share of price

    error WrongFee();
    error InvalidPrice();
    error PriceTooUncertain();

    constructor(IPyth pyth_, bytes32 priceId_, uint256 maxAge_, uint256 maxConfBps_) {
        pyth = pyth_;
        priceId = priceId_;
        maxAge = maxAge_;
        maxConfBps = maxConfBps_;
    }

    function updateFee(bytes[] calldata update) public view returns (uint256) {
        return update.length == 0 ? 0 : pyth.getUpdateFee(update);
    }

    function updateAndRead(bytes[] calldata update) external payable returns (uint256 priceWad) {
        if (msg.value != updateFee(update)) revert WrongFee();
        if (update.length != 0) pyth.updatePriceFeeds{value: msg.value}(update);

        IPyth.Price memory p = pyth.getPriceNoOlderThan(priceId, maxAge);
        if (p.price <= 0 || p.expo > 0 || p.expo < -18) revert InvalidPrice();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(uint64(p.price)); // p.price > 0 checked above
        if (uint256(p.conf) * BPS > price * maxConfBps) revert PriceTooUncertain();
        // forge-lint: disable-next-line(unsafe-typecast)
        priceWad = price * 10 ** uint256(int256(18 + p.expo)); // expo in [-18, 0] checked above
    }
}
