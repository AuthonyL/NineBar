# Manual acceptance during a live trading session

Automated tests prove the counting rules, aggregation, storage and restart de-duplication on fixed data. A release still needs one complete A-share trading session, with a few stocks and ETFs, checked against Eastmoney:

- [ ] Source timestamps line up at the open, the lunch break, the afternoon open and the close.
- [ ] Every 1-minute bar matches Eastmoney's time and OHLC, with no missing, duplicated or unclosed bars confirmed.
- [ ] Every 5-minute bar contains exactly five 1-minute bars, and no bar spans 11:30 to 13:00.
- [ ] Top and bottom counts follow `close[t]` versus `close[t-4]` bar by bar, and gaps, equal closes and missing data reset them.
- [ ] An unclosed ninth bar only shows as a candidate; it shows as confirmed after it closes with fresh data.
- [ ] Bar 8 and bar 9 alerts arrive at the right time with the right direction, timeframe and reference price.
- [ ] Restarting the app does not repeat an alert for the same sequence.
- [ ] Cutting the network or feeding stale data stops counting, and the app resynchronises before counting again.

Until this check passes, signals should not be used for real trading decisions.

---

# 交易时段人工验收

自动化测试用固定数据证明了计数规则、K 线聚合、存储和重启去重。每个版本仍须在一个完整的 A 股交易时段内，用少量股票和 ETF 对照东方财富完成以下核对：

- [ ] 开盘、午休、下午开盘和收盘的源时间戳一致。
- [ ] 每根 1 分钟 K 线的时间与 OHLC 一致，无缺根、重复或未收盘误确认。
- [ ] 每组 5 分钟 K 线恰含五根 1 分钟线，11:30 与 13:00 之间不跨午休合并。
- [ ] 顶部/底部数字逐根符合 `close[t]` 与 `close[t-4]`，中断、相等和缺失会重置。
- [ ] 未收盘的第 9 根只显示候选；收盘且数据新鲜后才显示已确认。
- [ ] 第 8 根和第 9 根通知的时点、方向、周期和参考价正确。
- [ ] 重启应用后同一序列不重复提醒。
- [ ] 主动断网或制造过期数据时停止推进，恢复后先重新同步。

在这项核对通过前，不应把信号直接作为实盘决策依据。
