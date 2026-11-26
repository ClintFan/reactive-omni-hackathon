// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISubscriptionService} from "@reactive/src/interfaces/ISubscriptionService.sol";
import {SepoliaTransferMonitor} from "../src/SepoliaTransferMonitor.sol";

interface TestVm {
    function deal(address account, uint256 balance) external;
    function etch(address account, bytes calldata code) external;
    function expectCall(address callee, bytes calldata data, uint64 count) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function expectRevert(bytes calldata reason) external;
    function prank(address caller) external;
}

contract SepoliaTransferMonitorTest {
    TestVm private constant vm = TestVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 private constant SEPOLIA = 11155111;
    address private constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint256 private constant TRANSFER = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 private constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    event TransferSeen(
        bytes32 indexed originTxHash, uint256 indexed originLogIndex, address indexed from, address to, uint256 value
    );

    function setUp() public {
        // The real system service lives at this fixed address on Lasna.
        vm.etch(SYSTEM, hex"00");
        vm.deal(address(this), 1 ether);
    }

    function testFundedConstructorSubscribesOnce() public {
        vm.expectCall(SYSTEM, _filter(ISubscriptionService.subscribe.selector), 1);
        SepoliaTransferMonitor monitor = new SepoliaTransferMonitor{value: 1 ether}();
        require(address(monitor).balance == 1 ether, "missing execution funds");
        require(monitor.processed() == 0, "already processed");
    }

    function testConstructorRequiresFunding() public {
        vm.expectRevert(abi.encodeWithSelector(SepoliaTransferMonitor.FundingRequired.selector));
        new SepoliaTransferMonitor();
    }

    function testOnlySystemMayReact() public {
        SepoliaTransferMonitor monitor = new SepoliaTransferMonitor{value: 1 ether}();
        IReactive.LogRecord memory entry = _transfer();
        vm.expectRevert(abi.encodeWithSignature("NotAuthorized(address,address)", address(this), SYSTEM));
        monitor.react(entry);
        require(monitor.processed() == 0, "unauthorized transfer counted");
    }

    function testIgnoresUnmatchedAndMalformedLogs() public {
        SepoliaTransferMonitor monitor = new SepoliaTransferMonitor{value: 1 ether}();
        vm.expectCall(SYSTEM, abi.encodePacked(ISubscriptionService.unsubscribe.selector), 0);
        IReactive.LogRecord memory entry = _transfer();
        entry.chainId = 1;
        _deliver(monitor, entry);
        entry.chainId = SEPOLIA;
        entry.contractAddress = address(0x1234);
        _deliver(monitor, entry);
        entry.contractAddress = USDC;
        entry.topic0 = uint256(keccak256("Approval(address,address,uint256)"));
        _deliver(monitor, entry);
        entry.topic0 = TRANSFER;
        entry.opCode = 4;
        _deliver(monitor, entry);
        entry.opCode = 3;
        entry.data = hex"01";
        _deliver(monitor, entry);
        entry.data = new bytes(64);
        _deliver(monitor, entry);
        require(monitor.processed() == 0, "invalid transfer counted");
    }

    function testFirstTransferEmitsEvidenceAndUnsubscribesOnce() public {
        SepoliaTransferMonitor monitor = new SepoliaTransferMonitor{value: 1 ether}();
        IReactive.LogRecord memory entry = _transfer();
        vm.expectCall(SYSTEM, _filter(ISubscriptionService.unsubscribe.selector), 1);
        vm.expectEmit(true, true, true, true, address(monitor));
        emit TransferSeen(bytes32(entry.txHash), entry.logIndex, address(0xa1), address(0xb2), 1_500_000);
        _deliver(monitor, entry);
        require(monitor.processed() == 1, "first transfer missed");

        // A second matching log from the same origin transaction can already be queued.
        entry.logIndex++;
        _deliver(monitor, entry);
        require(monitor.processed() == 1, "cap exceeded");
    }

    function _filter(bytes4 selector) private pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, SEPOLIA, USDC, TRANSFER, IGNORE, IGNORE, IGNORE);
    }

    function _transfer() private pure returns (IReactive.LogRecord memory entry) {
        entry.chainId = SEPOLIA;
        entry.contractAddress = USDC;
        entry.topic0 = TRANSFER;
        entry.topic1 = uint160(address(0xa1));
        entry.topic2 = uint160(address(0xb2));
        entry.opCode = 3;
        entry.txHash = uint256(keccak256("origin transaction"));
        entry.logIndex = 7;
        entry.data = abi.encode(uint256(1_500_000));
    }

    function _deliver(SepoliaTransferMonitor monitor, IReactive.LogRecord memory entry) private {
        vm.prank(SYSTEM);
        monitor.react(entry);
    }
}
