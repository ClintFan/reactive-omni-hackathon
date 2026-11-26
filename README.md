# Reactive Network Omni 共学

这里记录 Reactive Network Omni 的共学笔记和 Solidity 练习。现有练习通过 Reactive 合约监听 Sepolia 上的转账事件。

## 本地开发

按 [Foundry 官方指南](https://www.getfoundry.sh/introduction/installation) 安装后，在仓库根目录运行：

```sh
forge --version
cast --version
forge test
```

项目使用 Solidity `0.8.29` 和仓库内的 Reactive Omni 合约库。给 AI 编程工具的版本约束和参考文档见 [AGENTS.md](AGENTS.md)。

## 测试网

使用本期专用钱包，在 Ethereum Sepolia 领取测试 ETH，再按官方步骤兑换 Lasna 的 lREACT。测试钱包文件和密码保存在本地。 [Reactive 官方 faucet 指南](https://dev.reactive.network/reactive-mainnet#reactive-faucet)

## 共学笔记

每日打卡记录放在 [notes/](notes/)，合约和测试分别放在 [src/](src/) 与 [test/](test/)。

## 带保护的 Sepolia 回调付款

`GuardedSepoliaPayout` 只响应 Sepolia 上指定发送方向固定收款人发出的 USDC `Transfer`。每条符合条件的日志最多请求一次回调，`SepoliaPayoutReceiver` 从预存的测试 USDC 中向同一收款人支付等额款项。两端都按来源链 ID、交易哈希和日志索引组成的事件 ID 去重，并检查单次及合约生命周期总上限。金额使用 USDC 最小单位（`1 USDC = 1_000_000`）。

先在 Lasna 部署 `GuardedSepoliaPayout`，再在 Sepolia 部署 `SepoliaPayoutReceiver`。接收合约需要 Sepolia 回调代理、Lasna 合约地址，以及与 Lasna 合约相同的收款人和两项上限。分别准备 Lasna 的 lREACT 与 Sepolia 的 ETH 作为手续费，并向接收合约转入测试 USDC 作为付款资金。最后由 Lasna 合约的部署者调用一次 `activate(receiver)` 开启订阅。

[Foundry 测试](test/GuardedSepoliaPayout.t.sol)覆盖正常付款、重复投递、触发条件、两项金额上限和回调失败回滚。

### 出问题怎么办

- **手续费耗尽。** 预付额度和合约余额不足以付费并产生欠费时，Lasna 系统合约会自动停止投递源事件，Sepolia 回调代理也会对欠费的接收合约暂停投递。用 Lasna 系统合约的 `depositTo(reactiveAddress)` 充 lREACT，或用 Sepolia 回调代理的 `depositTo(receiverAddress)` 充 ETH。到对应链查 `debt(address)`，欠费归零即恢复服务。 [Omni 充值与欠费说明](https://dev.reactive.network/economy)
- **目标链执行失败。** 例如接收合约的测试 USDC 不足，付款会回滚，目标链的去重标记和已付金额保持原值。代理执行回调时发生的失败仍会计费，可查看 `CallbackFailure` 或用 Lasna 系统合约的 `getCallbacks(reactiveTxHash)` 查目标交易哈希和错误数据。Lasna 上已提交的请求继续占用请求额度，同一源事件重复送达也不会再次发起回调。修复失败原因后，只有回调代理重新投递原请求才会再次尝试付款。 [回调计费](https://dev.reactive.network/callback-contracts#paying-for-callbacks) · [回调状态查询](https://dev.reactive.network/economy#inspecting-callbacks)
