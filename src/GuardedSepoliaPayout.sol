// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {AbstractReactive} from "@reactive/src/base/AbstractReactive.sol";
import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

interface IUsdc {
    function transfer(address to, uint256 amount) external returns (bool);
}

abstract contract PayoutLimits {
    uint256 public immutable maxPerPayout;
    uint256 public immutable maxTotal;

    error InvalidLimits();

    constructor(uint256 maxPerPayout_, uint256 maxTotal_) {
        if (maxPerPayout_ == 0 || maxPerPayout_ > maxTotal_) revert InvalidLimits();
        maxPerPayout = maxPerPayout_;
        maxTotal = maxTotal_;
    }

    function _withinLimits(uint256 amount, uint256 used) internal view returns (bool) {
        return amount != 0 && amount <= maxPerPayout && amount <= maxTotal - used;
    }
}

/// @notice Deploy on Lasna, then activate after deploying the Sepolia receiver.
contract GuardedSepoliaPayout is AbstractReactive, PayoutLimits {
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant TRANSFER = uint256(keccak256("Transfer(address,address,uint256)"));
    // Leave room for the Sepolia proxy's overhead and the USDC proxy transfer.
    uint64 private constant CALLBACK_GAS_LIMIT = 1_000_000;

    address public immutable deployer;
    address public immutable watchedSender;
    address public immutable beneficiary;
    address public receiver;
    uint256 public requestedTotal;
    mapping(bytes32 => bool) public requested;

    error InvalidAddress();
    error ActivationDenied();

    constructor(address watchedSender_, address beneficiary_, uint256 maxPerPayout_, uint256 maxTotal_)
        payable
        PayoutLimits(maxPerPayout_, maxTotal_)
    {
        if (watchedSender_ == address(0) || beneficiary_ == address(0)) revert InvalidAddress();
        deployer = msg.sender;
        watchedSender = watchedSender_;
        beneficiary = beneficiary_;
    }

    function activate(address receiver_) external {
        if (msg.sender != deployer || receiver != address(0)) revert ActivationDenied();
        // A transfer paid by the receiver must never satisfy the source filter.
        if (receiver_ == address(0) || receiver_ == watchedSender || receiver_ == beneficiary) revert InvalidAddress();
        receiver = receiver_;
        SYSTEM.subscribe(SEPOLIA, SEPOLIA_USDC, TRANSFER, uint160(watchedSender), uint160(beneficiary), REACTIVE_IGNORE);
    }

    function react(LogRecord calldata record) external override onlySystem {
        if (receiver == address(0) || record.chainId != SEPOLIA || record.contractAddress != SEPOLIA_USDC) return;
        if (record.topic0 != TRANSFER || record.opCode != 3 || record.data.length != 32) return;
        if (record.topic1 != uint160(watchedSender) || record.topic2 != uint160(beneficiary)) return;

        bytes32 eventId = keccak256(abi.encode(record.chainId, record.txHash, record.logIndex));
        uint256 amount = abi.decode(record.data, (uint256));
        if (requested[eventId] || !_withinLimits(amount, requestedTotal)) return;

        requested[eventId] = true;
        requestedTotal += amount;
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: SEPOLIA,
                recipient: receiver,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeCall(SepoliaPayoutReceiver.executePayout, (address(0), eventId, amount))
            })
        );
    }
}

/// @notice Deploy on Sepolia and fund separately with USDC for payouts and ETH for callback fees.
contract SepoliaPayoutReceiver is AbstractCallback, PayoutLimits {
    address public immutable beneficiary;
    uint256 public paidTotal;
    mapping(bytes32 => bool) public paid;

    error InvalidAddress();
    error LimitExceeded();
    error PayoutFailed();

    event PayoutExecuted(bytes32 indexed eventId, address indexed beneficiary, uint256 amount);

    constructor(IPayable proxy, address reactiveSender, address beneficiary_, uint256 maxPerPayout_, uint256 maxTotal_)
        payable
        AbstractCallback(proxy, reactiveSender)
        PayoutLimits(maxPerPayout_, maxTotal_)
    {
        if (address(proxy) == address(0) || reactiveSender == address(0) || beneficiary_ == address(0)) {
            revert InvalidAddress();
        }
        beneficiary = beneficiary_;
    }

    function executePayout(address reactiveSender, bytes32 eventId, uint256 amount)
        external
        onlyServiceProvider
        onlyCallbackSender(reactiveSender)
    {
        if (paid[eventId]) return;
        if (!_withinLimits(amount, paidTotal)) revert LimitExceeded();

        paid[eventId] = true;
        paidTotal += amount;
        if (!IUsdc(SEPOLIA_USDC).transfer(beneficiary, amount)) revert PayoutFailed();
        emit PayoutExecuted(eventId, beneficiary, amount);
    }
}
