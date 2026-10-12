// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPyth} from "../../src/interfaces/IPyth.sol";

/// @notice Pyth stand-in: one feed, settable price, fee per update entry, staleness enforced.
contract MockPyth is IPyth {
    Price internal stored;
    uint256 public feePerUpdate;

    error StalePrice();
    error WrongFee();

    function setPrice(int64 price, uint64 conf, int32 expo) external {
        stored = Price({price: price, conf: conf, expo: expo, publishTime: block.timestamp});
    }

    function setFee(uint256 fee) external {
        feePerUpdate = fee;
    }

    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return feePerUpdate * updateData.length;
    }

    /// @dev Each entry is abi.encode(int64 price, uint64 conf, int32 expo), published now.
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        if (msg.value != feePerUpdate * updateData.length) revert WrongFee();
        for (uint256 i; i < updateData.length; ++i) {
            (int64 price, uint64 conf, int32 expo) = abi.decode(updateData[i], (int64, uint64, int32));
            stored = Price({price: price, conf: conf, expo: expo, publishTime: block.timestamp});
        }
    }

    function getPriceNoOlderThan(bytes32, uint256 age) external view returns (Price memory) {
        if (block.timestamp - stored.publishTime > age) revert StalePrice();
        return stored;
    }
}
