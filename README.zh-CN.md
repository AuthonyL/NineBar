# 九转雷达（NineBar）

[English](README.md)

九转雷达是 macOS 菜单栏应用。它监控你填写的沪深 A 股和场内 ETF，按 1 分钟和 5 分钟 K 线计算九转序列，在第 8 根和第 9 根收盘确认时提醒。界面支持中文和英文。

> **不构成投资建议。** 九转雷达只在你的 Mac 上监控行情条件，不交易、不下单，也不读取账户、Cookie、交易记录或钥匙串。行情来自东方财富网页端点，它不是有服务承诺的正式开放 API，随时可能变更、限流或停止返回数据。

## 环境要求

- macOS 14 或更高版本
- Swift 6.2 或更高版本，来自 Xcode 或 Command Line Tools（`xcode-select --install`）

本项目在 Swift 6.2 Command Line Tools 上构建和测试过。

## 快速开始

```bash
git clone https://github.com/AuthonyL/NineBar.git
cd NineBar
./run.sh
```

也可以在 Finder 中双击 `NineBar.command`。首次构建需要几分钟。`./run.sh --install` 会同时把应用复制到“应用程序”文件夹；如果要开启登录时启动，建议这样安装。

应用没有 Dock 图标。首次启动时默认只监控一个示例：沪深300ETF（510300）。要修改，点击菜单栏图标，选择“编辑自选”，每行填一个代码：

```text
600519
159915 创业板ETF
513500
```

代码后的名称可以不填，下次行情刷新时会自动补全。保存后会整体替换当前列表。支持沪深 A 股和场内 ETF，不支持北交所、LOF、可转债和港股。

要接收提醒，请在“设置 → 通知”中点击“请求权限”。

## 九转规则

每根 K 线的收盘价与四根之前的收盘价比较：

- 顶部序列：`close[t] > close[t-4]`
- 底部序列：`close[t] < close[t-4]`

相等会重置计数；分钟缺失会中断序列，并从缺口后重新预热四根。规则只看跨四根的比较，不看单根 K 线是涨是跌，所以中间即使出现反向涨跌，只要每一根仍满足与四根之前的比较，就会继续计数。

1 分钟和 5 分钟分别计算，只有完整收盘的 K 线能推进计数：

- **第 8 根**：接近完成
- **候选 9**：第 9 根尚未收盘，但即时价已满足条件
- **已确认 9**：第 9 根收盘并通过完整性校验

**参考价**：顶部序列取第 1–9 根的最高价，底部序列取第 1–9 根的最低价。它不是价格预测，也不是下单价格。

连续竞价时段内，请求接收时间和最新分钟的结束时间都必须在 75 秒以内。过期、空、缺失或格式异常的数据不会推进计数，也不会产生确认。当天收盘后，应用从 10 秒报价轮询改为低频检查。

这一计数规则与 TD Sequential 的 setup 阶段相同。TD Sequential 是其权利人的商标，本项目与其无关，也未获其认可。

## 设置

- 语言：跟随系统、简体中文或 English。Finder 和通知横幅里的应用名称始终跟随系统语言。
- 监控周期：1 分钟和/或 5 分钟。
- 第 8 根提醒、第 9 根确认提醒，第 9 根可选播放系统声音。
- 登录时启动。如果系统显示“需要系统批准”，请到“系统设置 → 通用 → 登录项”中批准。
- 本地数据：查看占用空间，清理 30 个交易日之前的历史。
- 诊断：复制版本、数据状态、自选数量、监控周期和错误类别，不包含路径、网址、账户或原始响应。

历史记录保存每次第 9 根确认、参考价，以及确认后 5、15、30、60 分钟的收益。`—` 表示后续 K 线尚未出现，不代表收益为零。

## 数据与隐私

所有数据都保存在用户目录内：

```text
~/Library/Application Support/NineBar/
├── NineBar.sqlite      K 线、信号和通知去重记录
├── settings.json
├── watchlist.json
└── logs/               只记录时间、组件、错误类别和可选的证券代码
```

每个交易日正常刷新后，会删除最近 30 个交易日之前的 K 线和信号。清理历史不会改动设置和自选。

## 在线健康检查

应用包内附带一个命令行检查，用与应用相同的客户端和解析器请求 `600519`（沪市股票）和 `159915`（深市 ETF）：

```bash
dist/NineBar.app/Contents/MacOS/NineBarHealthCheck
```

它输出一行 JSON，只有 `ok` 为 true 时退出码才是 0：

```json
{"errors":[],"latestAgeSeconds":12,"marketOpen":true,"minuteSeriesCount":2,"ok":true,"quoteCount":2}
```

| 字段 | 含义 |
| --- | --- |
| `ok` | 两只证券的报价、名称、OHLC、分钟序列、共同交易日和时间要求是否全部通过 |
| `marketOpen` | 执行时是否处于上海连续竞价时段 |
| `quoteCount`、`minuteSeriesCount` | 通过校验的数量，正常均为 2 |
| `latestAgeSeconds` | 所有必需时间中最旧者的年龄，没有有效时间时为 `null` |
| `errors` | 固定的错误类别，不包含网址、证券名称、路径或响应正文 |

失败通常表示数据源当时不可用，与计数逻辑、存储或界面无关；这些由测试覆盖。

## 常见问题

- **提示“无法打开，因为 Apple 无法检查其是否包含恶意软件”**：只有从别人那里下载的应用才会出现，本地构建的应用是 ad-hoc 签名。请用 `./run.sh` 自己构建，或右键点击应用选择“打开”。
- **收不到提醒**：到“系统设置 → 通知 → 九转雷达”允许通知，再回到应用设置查看状态。
- **数据暂停或数据源不可用**：检查网络和系统时间。应用会先从东方财富分钟历史主机切换到延迟主机；两个来源都失败时会暂停，不会用旧数据确认信号。

## 开发

```bash
scripts/test.sh                      # 全部测试，并检查应用包
scripts/test.sh RadarPipelineTests   # 只运行名称匹配的测试
scripts/build-app.sh release         # 构建 dist/NineBar.app
```

测试目标是使用 Swift Testing 的可执行程序，因此只有 Command Line Tools 的机器也能运行。请用 `scripts/test.sh`，不要用 `swift test`。

```text
Sources/
├── NineBarCore/          领域模型、计数引擎、行情、存储、通知
├── NineBarUI/            SwiftUI 界面和 ViewModel
├── NineBar/              应用入口和组装
└── NineBarHealthCheck/   命令行数据源检查
Tests/
├── NineBarCoreTests/
└── NineBarUITests/
Resources/                Info.plist、图标和本地化应用名
scripts/                  构建、测试和应用包检查
```

界面文案用 `L10n.t("中文", "English")` 成对书写，每条文案都同时有中英文，运行中也能切换语言。

自动化测试用固定数据覆盖了计数规则、K 线聚合、存储和重启去重。仍需在真实交易时段人工核对的项目见 [docs/manual-acceptance.md](docs/manual-acceptance.md)。

## 许可证

[MIT](LICENSE)
