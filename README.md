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

### 第一条完整链路

2026 年 11 月 28 日，Ethereum Sepolia 上的一笔 0.01 测试 USDC 捐款触发了 Lasna 的配捐判断，随后 Sepolia 接收合约向同一收款钱包支付了 0.01 测试 USDC。

```mermaid
sequenceDiagram
    actor Donor as 捐款钱包
    participant USDC as Sepolia · 测试 USDC
    participant System as Lasna · 系统合约
    participant Reactive as Lasna · GuardedSepoliaPayout
    participant Proxy as Sepolia · 回调代理
    participant Receiver as Sepolia · SepoliaPayoutReceiver

    Donor->>USDC: 转 0.01 USDC 给收款钱包
    Note over Donor,USDC: ① 源交易产生 Transfer
    System->>Reactive: 投递 Transfer，调用 react()
    Note over System,Reactive: ② 检查参与方、配捐额度和事件 ID
    Reactive->>System: requestCallbackV_1_0()
    Proxy->>Receiver: ③ executePayout()
    Receiver->>USDC: 再转 0.01 USDC 给同一收款钱包
    Note over Proxy,Receiver: 回执包含 PayoutExecuted
```

| 项目 | 测试网记录 |
| --- | --- |
| 募捐钱包 | `0xAcF2cde557949A9189E304D9f255486F2997b55d` |
| 收款钱包 | `0x36183F4A182aB53d6EBD3B6039408a325A6DF986` |
| Lasna 配捐合约 | `0x632fd45BBEF8Dcc04792b46760dcE664f6C2cB6A` · [部署交易](https://lasna.reactscan.net/tx/0x2b03765dafda34105953102b419fe0524ea1864a4dc3fca0f7aabc1b43d9fafe) |
| Sepolia 接收合约 | `0x9cE32B963cAeA9437B96aC911a3e3b6C1Abf254F` · [部署交易](https://sepolia.etherscan.io/tx/0x3e247801891b3039e65104bd1779377c4832952380579bd96fcbe8d2622cd472) |
| Ethereum Sepolia 回调代理 | `0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`，已通过 Sepolia RPC 核验链上代码 |
| ① 源链交易 | [Sepolia · USDC 捐款](https://sepolia.etherscan.io/tx/0x12bec47113c865c838f2f3768f679575e3e4f4396d12a584a6050eb48897f37a) · `Transfer` 0.01 USDC |
| ② Reactive 交易 | [Lasna · 配捐判断](https://lasna.reactscan.net/tx/0xcb1d6e2ef639709c97302533204658f4c88dbc3823c41371413653560c0fafbb) · `CallbackRequest` |
| ③ 目标链交易 | [Sepolia · 配捐到账](https://sepolia.etherscan.io/tx/0x82353d6d6ffc605cd5ef4e44c82ae118da63aa0cad604bc5f29547f85178c624) · `PayoutExecuted` 和接收合约发出的 0.01 USDC `Transfer` |

三笔交易以事件 ID `0xbf94c52af88ebca8ec90843be16e1134176a9618bd6aea2446c86878635a85ab` 串联。用源链 ID `11155111`、源交易哈希和 `Transfer` 日志索引 `89` 计算该 ID。Lasna `CallbackRequest` 的回调参数和 Sepolia `PayoutExecuted` 日志都包含该 ID。

本次部署将单笔和总上限都设为 `10000`（0.01 测试 USDC）。首次尝试中，回调 gas 上限为 300,000，代理扣除开销后，接收合约调用 USDC `transfer()` 时耗尽 gas。修正版将回调上限提高到 1,000,000，上表记录的是修正版跑通的链路。 [首次回调回执](https://sepolia.etherscan.io/tx/0x52ebfde2e055e7ad6a00f55c5613e33be4f45b1bbf152746ed3fad152bfc0445) · [Omni 回调 gas 说明](https://dev.reactive.network/economy#gas-limits)

### 出问题怎么办

- **手续费耗尽。** 预付额度和合约余额不足以付费并产生欠费时，Lasna 系统合约会自动停止投递源事件，Sepolia 回调代理也会对欠费的接收合约暂停投递。用 Lasna 系统合约的 `depositTo(reactiveAddress)` 充 lREACT，或用 Sepolia 回调代理的 `depositTo(receiverAddress)` 充 ETH。到对应链查 `debt(address)`，欠费归零即恢复服务。 [Omni 充值与欠费说明](https://dev.reactive.network/economy)
- **目标链执行失败。** 例如接收合约的测试 USDC 不足，付款会回滚，目标链的去重标记和已付金额保持原值。代理执行回调时发生的失败仍会计费，可查看 `CallbackFailure` 或用 Lasna 系统合约的 `getCallbacks(reactiveTxHash)` 查目标交易哈希和错误数据。Lasna 上已提交的请求继续占用请求额度，同一源事件重复送达也不会再次发起回调。修复失败原因后，只有回调代理重新投递原请求才会再次尝试付款。 [回调计费](https://dev.reactive.network/callback-contracts#paying-for-callbacks) · [回调状态查询](https://dev.reactive.network/economy#inspecting-callbacks)
