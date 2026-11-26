// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {AbstractCallback} from "@reactive/src/base/AbstractCallback.sol";
import {AbstractPayer} from "@reactive/src/base/AbstractPayer.sol";
import {IPayable} from "@reactive/src/interfaces/IPayable.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISubscriptionService} from "@reactive/src/interfaces/ISubscriptionService.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";
import {GuardedSepoliaPayout, SepoliaPayoutReceiver, SEPOLIA_USDC} from "../src/GuardedSepoliaPayout.sol";
import {TestVm} from "./SepoliaTransferMonitor.t.sol";

contract PayoutSystemMock {
    uint256 public requests;
    bool public rejectRequests;
    ISystemContract.CallbackConfiguration_V_1_0 private lastRequest;

    error RequestRejected();

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function setRejectRequests(bool reject) external {
        rejectRequests = reject;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 calldata config) external {
        if (rejectRequests) revert RequestRejected();
        requests++;
        lastRequest = config;
    }

    function latest() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return lastRequest;
    }
}

contract PayoutUsdcMock {
    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract GuardedSepoliaPayoutTest {
    TestVm private constant vm = TestVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address payable private constant PROXY = payable(address(0xc1));
    address private constant WATCHED_SENDER = address(0xa1);
    address private constant BENEFICIARY = address(0xb2);
    uint256 private constant SEPOLIA = 11155111;
    uint256 private constant TRANSFER = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 private constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 private constant PER_PAYOUT = 2_000_000;
    uint256 private constant TOTAL = 3_000_000;

    PayoutSystemMock private constant system = PayoutSystemMock(SYSTEM);
    PayoutUsdcMock private constant usdc = PayoutUsdcMock(SEPOLIA_USDC);
    GuardedSepoliaPayout private automation;
    SepoliaPayoutReceiver private receiver;

    function setUp() public {
        vm.etch(SYSTEM, address(new PayoutSystemMock()).code);
        vm.etch(SEPOLIA_USDC, address(new PayoutUsdcMock()).code);
        automation = new GuardedSepoliaPayout(WATCHED_SENDER, BENEFICIARY, PER_PAYOUT, TOTAL);
        receiver = new SepoliaPayoutReceiver(IPayable(PROXY), address(automation), BENEFICIARY, PER_PAYOUT, TOTAL);
        vm.expectCall(
            SYSTEM,
            abi.encodeCall(
                ISubscriptionService.subscribe,
                (SEPOLIA, SEPOLIA_USDC, TRANSFER, uint160(WATCHED_SENDER), uint160(BENEFICIARY), IGNORE)
            ),
            1
        );
        automation.activate(address(receiver));
        usdc.setBalance(address(receiver), TOTAL);
    }

    function testMatchingTransferPaysOnceAcrossBothChains() public {
        IReactive.LogRecord memory entry = _transfer(7, PER_PAYOUT);
        bytes32 eventId = _eventId(entry);
        _react(entry);
        _react(entry);

        require(system.requests() == 1 && automation.requested(eventId), "request was not unique");
        require(automation.requestedTotal() == PER_PAYOUT, "wrong requested amount");
        ISystemContract.CallbackConfiguration_V_1_0 memory config = system.latest();
        require(config.chainId == SEPOLIA && config.recipient == address(receiver), "wrong callback destination");
        require(config.gasLimit == 300_000, "wrong callback gas limit");
        require(
            keccak256(config.payload)
                == keccak256(abi.encodeCall(SepoliaPayoutReceiver.executePayout, (address(0), eventId, PER_PAYOUT))),
            "wrong callback payload"
        );

        _deliver(eventId, PER_PAYOUT);
        _deliver(eventId, PER_PAYOUT);
        require(receiver.paid(eventId) && receiver.paidTotal() == PER_PAYOUT, "payout was not unique");
        require(usdc.balanceOf(BENEFICIARY) == PER_PAYOUT, "beneficiary balance mismatch");
        require(usdc.balanceOf(address(receiver)) == TOTAL - PER_PAYOUT, "receiver balance mismatch");
    }

    function testRejectsWrongOriginAndTransferParticipants() public {
        IReactive.LogRecord memory entry = _transfer(7, PER_PAYOUT);
        entry.chainId = 1;
        _react(entry);
        entry.chainId = SEPOLIA;
        entry.contractAddress = address(0x1234);
        _react(entry);
        entry.contractAddress = SEPOLIA_USDC;
        entry.topic1 = uint160(address(receiver));
        _react(entry);
        entry.topic1 = uint160(WATCHED_SENDER);
        entry.topic2 = uint160(address(0x1234));
        _react(entry);
        entry.topic2 = uint160(BENEFICIARY);
        entry.topic0 = 0;
        _react(entry);
        entry.topic0 = TRANSFER;
        entry.opCode = 4;
        _react(entry);
        entry.opCode = 3;
        entry.data = hex"01";
        _react(entry);
        require(system.requests() == 0 && automation.requestedTotal() == 0, "invalid log requested a payout");
    }

    function testOnlySystemAndAuthenticatedProxyCanExecute() public {
        IReactive.LogRecord memory entry = _transfer(7, PER_PAYOUT);
        bytes32 eventId = _eventId(entry);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), SYSTEM));
        automation.react(entry);

        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), PROXY));
        receiver.executePayout(address(automation), eventId, PER_PAYOUT);

        vm.expectRevert(
            abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, address(this), address(automation))
        );
        vm.prank(PROXY);
        receiver.executePayout(address(this), eventId, PER_PAYOUT);
        require(system.requests() == 0 && receiver.paidTotal() == 0, "unauthorized action executed");
    }

    function testOnlyDeployerCanActivateAndReceiverIsFixed() public {
        GuardedSepoliaPayout pending = new GuardedSepoliaPayout(WATCHED_SENDER, BENEFICIARY, PER_PAYOUT, TOTAL);
        vm.expectRevert(abi.encodeWithSelector(GuardedSepoliaPayout.ActivationDenied.selector));
        vm.prank(WATCHED_SENDER);
        pending.activate(address(receiver));

        vm.expectRevert(abi.encodeWithSelector(GuardedSepoliaPayout.InvalidAddress.selector));
        pending.activate(WATCHED_SENDER);

        vm.expectRevert(abi.encodeWithSelector(GuardedSepoliaPayout.ActivationDenied.selector));
        automation.activate(address(0xd1));
        require(pending.receiver() == address(0) && automation.receiver() == address(receiver), "receiver changed");
    }

    function testEnforcesPerPayoutAndLifetimeLimits() public {
        _react(_transfer(6, 0));
        _react(_transfer(7, PER_PAYOUT + 1));
        require(system.requests() == 0, "invalid amount accepted");

        _react(_transfer(8, PER_PAYOUT));
        _react(_transfer(9, TOTAL - PER_PAYOUT + 1));
        require(system.requests() == 1, "lifetime cap exceeded");

        _react(_transfer(10, TOTAL - PER_PAYOUT));
        _react(_transfer(11, 1));
        require(system.requests() == 2 && automation.requestedTotal() == TOTAL, "wrong cap boundary");

        vm.expectRevert(abi.encodeWithSelector(SepoliaPayoutReceiver.LimitExceeded.selector));
        _deliver(bytes32(uint256(7)), PER_PAYOUT + 1);
        _deliver(bytes32(uint256(8)), PER_PAYOUT);
        vm.expectRevert(abi.encodeWithSelector(SepoliaPayoutReceiver.LimitExceeded.selector));
        _deliver(bytes32(uint256(9)), TOTAL - PER_PAYOUT + 1);
        _deliver(bytes32(uint256(10)), TOTAL - PER_PAYOUT);
        vm.expectRevert(abi.encodeWithSelector(SepoliaPayoutReceiver.LimitExceeded.selector));
        _deliver(bytes32(uint256(11)), 1);
        require(receiver.paidTotal() == TOTAL && usdc.balanceOf(BENEFICIARY) == TOTAL, "wrong payout cap");
    }

    function testDestinationFailureRollsBackPayoutButKeepsSourceRequest() public {
        IReactive.LogRecord memory first = _transfer(7, PER_PAYOUT);
        IReactive.LogRecord memory second = _transfer(8, TOTAL - PER_PAYOUT);
        _react(first);
        _react(second);
        _deliver(_eventId(first), PER_PAYOUT);

        usdc.setBalance(address(receiver), 0);
        bytes32 eventId = _eventId(second);
        vm.expectRevert(abi.encodeWithSelector(SepoliaPayoutReceiver.PayoutFailed.selector));
        _deliver(eventId, TOTAL - PER_PAYOUT);
        require(!receiver.paid(eventId) && receiver.paidTotal() == PER_PAYOUT, "failed payout changed state");
        require(usdc.balanceOf(BENEFICIARY) == PER_PAYOUT, "failed payout moved USDC");
        _react(second);
        require(system.requests() == 2 && automation.requestedTotal() == TOTAL, "source reissued request");

        usdc.setBalance(address(receiver), TOTAL - PER_PAYOUT);
        _deliver(eventId, TOTAL - PER_PAYOUT);
        require(receiver.paid(eventId) && receiver.paidTotal() == TOTAL, "redelivered callback failed");
    }

    function testRejectedRequestDoesNotConsumeBudgetOrEvent() public {
        IReactive.LogRecord memory entry = _transfer(7, PER_PAYOUT);
        bytes32 eventId = _eventId(entry);
        system.setRejectRequests(true);
        vm.expectRevert(abi.encodeWithSelector(PayoutSystemMock.RequestRejected.selector));
        _react(entry);
        require(!automation.requested(eventId) && automation.requestedTotal() == 0, "rejected request used budget");
        system.setRejectRequests(false);
        _react(entry);
        require(system.requests() == 1 && automation.requested(eventId), "valid request was lost");
    }

    function _transfer(uint256 logIndex, uint256 amount) private pure returns (IReactive.LogRecord memory entry) {
        entry.chainId = SEPOLIA;
        entry.contractAddress = SEPOLIA_USDC;
        entry.topic0 = TRANSFER;
        entry.topic1 = uint160(WATCHED_SENDER);
        entry.topic2 = uint160(BENEFICIARY);
        entry.opCode = 3;
        entry.txHash = uint256(keccak256("origin transaction"));
        entry.logIndex = logIndex;
        entry.data = abi.encode(amount);
    }

    function _eventId(IReactive.LogRecord memory entry) private pure returns (bytes32) {
        return keccak256(abi.encode(entry.chainId, entry.txHash, entry.logIndex));
    }

    function _react(IReactive.LogRecord memory entry) private {
        vm.prank(SYSTEM);
        automation.react(entry);
    }

    function _deliver(bytes32 eventId, uint256 amount) private {
        vm.prank(PROXY);
        receiver.executePayout(address(automation), eventId, amount);
    }
}
