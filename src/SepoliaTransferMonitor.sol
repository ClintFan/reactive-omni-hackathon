// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";

/// @notice Records one Circle USDC Transfer from Ethereum Sepolia, then unsubscribes on Lasna.
contract SepoliaTransferMonitor is AbstractReactive {
    uint256 private constant ORIGIN_CHAIN_ID = 11155111;
    address private constant TOKEN = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint256 private constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));

    uint256 public processed;

    error FundingRequired();

    event TransferSeen(
        bytes32 indexed originTxHash, uint256 indexed originLogIndex, address indexed from, address to, uint256 value
    );

    constructor() payable {
        if (msg.value == 0) revert FundingRequired();
        SYSTEM.subscribe(ORIGIN_CHAIN_ID, TOKEN, TRANSFER_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function react(LogRecord calldata record) external override onlySystem {
        if (processed == 1) return;
        if (record.chainId != ORIGIN_CHAIN_ID) return;
        if (record.contractAddress != TOKEN) return;
        if (record.topic0 != TRANSFER_TOPIC) return;
        // A standard ERC-20 Transfer has two indexed addresses and one ABI word of data.
        if (record.opCode != 3) return;
        bytes calldata data = record.data;
        if (data.length != 32) return;

        processed = 1;
        emit TransferSeen(
            bytes32(record.txHash),
            record.logIndex,
            address(uint160(record.topic1)),
            address(uint160(record.topic2)),
            abi.decode(data, (uint256))
        );
        SYSTEM.unsubscribe(ORIGIN_CHAIN_ID, TOKEN, TRANSFER_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }
}
