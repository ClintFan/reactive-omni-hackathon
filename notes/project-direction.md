# 项目方向卡｜Sepolia USDC 自动配捐

## 一句话

监听 Ethereum Sepolia 上测试 USDC 合约的 `Transfer` 事件，当指定捐款钱包向固定收款地址转入正数金额、单笔与累计申请额均在预算内且该事件尚未处理时，由 Lasna 请求回调，让 Sepolia 上预存测试 USDC 的配捐合约向同一收款地址支付等额款项。

## 赛道

**2 · Set It and Forget It（个人自动化）**。配捐人设定捐款钱包、收款地址、单笔上限和总预算，预存配捐资金并启用规则，之后符合条件的捐款会自动触发配捐。

## 目标用户和真实场景

目标用户是为社区募捐提供等额配捐的个人赞助人。例如，一位赞助人承诺为某个开源社区的募捐活动配捐，在活动开始前约定捐款钱包、收款地址和预算。目前可以在区块浏览器逐笔核对转账，在表格里记录已配捐金额，再手动签名付款。也可以自己运行监听脚本，持续检查交易、保存处理进度并管理付款钱包。项目将筛选、限额和去重交给合约。

## 第 2 周最小 Demo

跑通 **Ethereum Sepolia → Reactive Lasna → Ethereum Sepolia**：

1. 指定捐款钱包向固定收款地址转入 **0.01 测试 USDC**，源交易发出 `Transfer`。
2. Lasna 的 `GuardedSepoliaPayout` 在带 `onlySystem` 的 `react()` 中检查地址、金额、预算与事件 ID，调用 `SYSTEM.requestCallbackV_1_0()`。
3. Sepolia 回调代理调用 `SepoliaPayoutReceiver.executePayout()`。接收合约验证代理和授权的 Lasna 合约，从预存余额向同一收款地址再转 **0.01 测试 USDC**，并记录 `PayoutExecuted`。

验收时用同一事件 ID 串起源日志、Lasna 回调请求和目标付款日志，并确认源转账与配捐合计到账 **0.02 测试 USDC**。仓库已记录一组测试网回执：

- [源链捐款交易](https://sepolia.etherscan.io/tx/0x12bec47113c865c838f2f3768f679575e3e4f4396d12a584a6050eb48897f37a)
- [Lasna 回调请求交易](https://lasna.reactscan.net/tx/0xcb1d6e2ef639709c97302533204658f4c88dbc3823c41371413653560c0fafbb)
- [目标链配捐交易](https://sepolia.etherscan.io/tx/0x82353d6d6ffc605cd5ef4e44c82ae118da63aa0cad604bc5f29547f85178c624)

[合约源码](../src/GuardedSepoliaPayout.sol) · [Omni 回调请求](https://dev.reactive.network/reactive-contracts#requesting-callbacks) · [回调鉴权](https://dev.reactive.network/callback-contracts#authorizing-callbacks)

## 参赛方式

暂定单人参赛，由 ClintFan 负责合约开发、测试网部署、验收和演示。
