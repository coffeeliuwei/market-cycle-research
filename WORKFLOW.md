# 投资分析工作流（唯一运行入口）

## 请求分流

- 用户只要求账户汇总、资产/持仓/挂单/网格/机器人盘点或读取最新账户数据时，读取账户总览并运行 scripts/get-compact-account-context.ps1。除非用户同时明确要求实时行情判断、市场分析或重新刷新，否则不得运行`doctor.ps1`和`run-analysis-refresh.ps1`。
- 用户说“分析”或明确要求结合当前市场复核组合时，执行下方完整流程。
- 用户明确说“强制刷新”“重新拉取全部行情”或同义要求时，刷新命令增加`-ForceRefresh`。

## 完整分析启动顺序

当用户说“分析”或要求复核组合时，Agent必须按顺序执行：

1. 读取根目录 `PORTFOLIO.md`，先建立账户全貌。
2. 运行 `scripts/doctor.ps1 -Repair -Json`，在TradingView CDP未连接时先调用项目恢复脚本启动或重连，再确认本机运行条件；只有修复后必需项仍失败才停止。
   若宿主已连接 `tradingview-official`，可将其作为只读行情与元数据增强源；批量快照与120根深拉仍以项目脚本为可复现基线，官方MCP不可用时自动保留Screener+桌面CDP路径。`binance-official`只允许Market data/Read account，禁止Trade/Transfer；Binance AI站内Beta不视为外部API。
3. 读取 `config/analysis-budget.json`、`config/watchlist.json`、`config/accounts.json`。`config/analysis-universe.json`仅保留为用户明确指定旧范围时的参考，不再是币圈分析的默认刷新范围。
4. 读取 `knowledge/` 中的方法论与输出模板。
5. 读取 `state/current/` 中四个独立账户的全部权威状态，不能只依赖总览。
6. 运行 `scripts/get-effective-decisions.ps1` 获取用户当前有效硬规则。
6a. 币圈下单建议和历史决策复盘必须应用`knowledge/user-spot-order-model.md`：同时输出“模拟用户选择”和“独立风险审计”，并严格区分用户自主判断、Agent建议和最终执行。涉及机器人历史时还必须读取`knowledge/user-bot-execution-model.md`，把选择层、配置层和机械执行层分开评价。
7. 先用 Binance 和 CoinMarketCap 做不调用 TradingView 的市场筛选，保留最多5个入围币。再运行 `scripts/run-analysis-refresh.ps1 -CandidateSymbols <入围币>` 获取实时数据；入口自动合并 Binance、OK、Gate 的有效账户币种，以一次 TradingView Screener 批量请求覆盖完整动态范围，再只对入围币、BTC、Screener失败项及靠近挂单/机器人边界的关键币执行有上限的桌面CDP深拉。筛选源不可用时省略 `-CandidateSymbols`，仅分析账户币种，不得回退固定观察池。默认允许复用10分钟内、`complete=true`且标的与周期范围完全一致的快照；否则执行新刷新。
8. 仅使用本次新刷新或符合上述条件的短时完整快照形成实时结论；更旧、不完整或范围不同的快照只作背景。
9. 按 `knowledge/analysis-template.md` 输出，并披露全部失败项和状态陈旧项。
9a. 对本轮覆盖的主要市场锚点执行 `knowledge/market-forecast.md`。先给月度、季度预判，再补充短期和波段。发布前用共用预测脚本记录各周期主次方向、证据与改判条件，并复盘已到期记录。缺合格数据时明确保留判断，不增加刷新范围。
10. 从刷新快照的 `deferredOrderRuleCheck`、`deferredOrderAlerts` 读取全部条件计划提醒：`current_executable` 输出“当前可尝试挂单”（只提醒、不自动提交），`prepare` 输出“准备挂单”，`waiting` 保留条件计划和触发距离，`blocked` 或 `unavailable` 明确说明失败规则或本次未完成核验；不得把条件计划写成当前可执行挂单。

## 数据完整性

TradingView Desktop may inject upgrade/promotional dialogs after an application update. The CDP deep collector dismisses only dialogs matching the known promotion text through TradingView's own close control (or Escape fallback) before symbol/timeframe changes; it never deletes the dialog DOM directly. It treats chart-readiness timeouts as failures and validates the chart API symbol, main-series symbol, requested timeframe, and actual bar spacing before accepting OHLCV. A mismatch is a failed symbol/timeframe, never usable market data.

### A股只读刷新

- A股行情与组合分析统一调用`scripts/run-ashare-refresh.ps1`，默认范围只包含当前A股持仓、代码有效的活动订单和用户明确指定的代码。
- 共享数据链为腾讯逐标的行情（必需报价）、AKShare分项增强、BaoStock最近交易日历史行情最终回退；Tushare在没有明确Token配置时保持禁用。`complete=true`只表示请求代码全部获得逐标的报价且没有未恢复的必需错误；`enrichmentComplete=false`、`optionalFailureCount`和`failures`必须继续披露分项缺失。BaoStock回退或报价覆盖不全不得标为完整。
- 默认只输出紧凑摘要和快照路径。完全相同的代码范围仅可复用10分钟内且`complete=true`的快照；用户明确要求强制刷新时使用`-ForceRefresh`。
- 每个分析任务最多执行一次完整A股提供商刷新。禁止默认全市场反复抓取、递归读取历史快照或把整份原始行情塞入上下文。
- 宿主侧证券研究工具只作为可选交叉验证或研究补充，不能成为Codex/OpenCode复现共享分析结果的必要条件。

- 日常分析只读取本项目内的账户JSON和总览；禁止去外部回滚归档、旧会话JSONL或Agent记忆中寻找账户状态。归档仅用于用户明确要求的故障恢复。
- TradingView Screener 对完整动态范围只发一次批量请求；只有需要120根历史K线和精确区间的深拉标的才使用唯一受控图表。两层均由一个刷新进程串行执行并受同一互斥锁保护。
- 币圈分析的TradingView范围由`scripts/get-dynamic-crypto-analysis-symbols.ps1`生成：纳入 Binance、OK、Gate 中市值不低于`cryptoAnalysis.dustThresholdUsd`（当前100 USDT）的持仓，以及所有有效挂单和运行中机器人涉及的币；后两类不受粉尘阈值限制。
- 每次用户明确要求完整“分析”时，还必须对上述全部有效持仓、现货挂单、运行中现货/合约网格及其他未结清开单所涉及的标的执行消息面与基本面异常检查。检查范围至少包括：项目团队或官方长期失联、停止维护、黑客攻击/漏洞/链停摆、脱锚、重大监管或诉讼、交易所下架或风险警示、代币合约迁移、异常增发/解锁/供应变化，以及上市公司重大财报、指引、会计、公司行动或退市风险。普通重复新闻不逐条罗列；只有足以改变标的质量、下架概率、网格安全边界或持仓处置判断的异常才必须置顶上报并给出受影响账户、订单或机器人。若某标的消息源或基本面数据不可用，必须逐项标为`unavailable`，不得把“未查到”表述为“没有异常”。该检查是完整分析的账户风险层，不等同于用户明确要求的全市场“筛币”。
- 市场初筛只使用 Binance 和 CoinMarketCap，不为初筛池调用TradingView。最多5个最终候选与账户币种合并后由Screener批量刷新D/W/M/3M；桌面CDP默认最多深拉`config/sources.json`配置的8个关键币。Screener数据缺失时优先回退CDP，不得伪造历史K线字段。
- 固定观察池、A股、美股、黄金、汇率及其他未持有且未入围币种不得混入本次币圈TradingView刷新。只有用户明确指定完整标的集合时才使用`-Symbols`覆盖动态范围。
- 任一标的或周期失败必须列出，结果`complete=false`。
- 禁止用旧快照填补实时失败。
- CoinGlass属于慢变化辅助指标，可在`config/sources.json`规定的窗口内复用最近一次成功结果；复用项必须包含`provenance=fresh_cache`、缓存年龄和来源快照。过期或失败数据不得冒充实时结果。
- Polymarket只把数量受限的相关市场摘要写入分析快照。X数据必须明确区分实时采集、新鲜缓存、缓存过期、采集器缺失和认证缺失；禁止静默使用陈旧缓存。
- 币圈完整分析的舆情范围由`scripts/get-social-intelligence-plan.ps1`生成，必须覆盖Binance、OK、Gate全部有效账户币种并加入最多5个市场入围币。X按计划分批查询，摘要固定披露查询数、降级状态、已覆盖与未覆盖币种；不能再用单一静态`bitcoin`查询代表账户舆情。
- 宿主具备币安只读增强工具时，每次完整分析调用一次market overview和hot coin/community focus，并只对`binanceSquare.deepAssets`调用逐币quote；这类输出标记为币安广场衍生增强。宿主没有对应能力时必须输出`binanceSquare=unavailable`，不得用普通搜索结果伪装成币安广场实时数据。
- 舆情证据按项目/交易所/监管/安全机构官方、可信机构、已验证专家、社区作者依次降权。舆情用于发现官方动态、漏洞/链停摆、团队失联、下架/风险标签、迁移、异常增发或解锁、监管事件与情绪突变；不能仅凭热度把币提升为买入或网格候选。
- 所有价格、宏观数据和账户状态必须标注采集或观察时间。
- 刷新脚本默认标准输出只包含精简状态和完整快照路径。分析时按需读取保存的快照字段，不为把整份原始JSON塞入对话而使用`-EmitFullJson`。
- 长时间刷新期间不为无变化的轮询反复生成消息；约每分钟检查一次，只在状态变化或完成时汇报。
- 用户提供普通现货订单导出并要求历史复盘时，使用`scripts/replay-binance-spot-history.ps1`生成逐笔记录和决策簇。该任务默认不启动行情采集器；除非用户另行要求事前市场重建，订单簿只能证明委托、成交和撤销，不能代表网格、期货、理财或完整账户收益。
- 历史复盘用`orderTime`解释事前意图，用实际成交或结果时间解释风险暴露；不得把未成交挂单计为盈利或亏损，不得给无成本来源的卖单虚构收益。
- 用户提供机器人订单与交易流水时，使用`scripts/replay-binance-bot-history.ps1`补充执行层。现货网格按导出状态统计；U本位订单只有成交均价非空时才标为观察到成交，其余只能标为`unresolved`，不得推定为当前挂单。流水缺少币对时只做账户/资产汇总，不得虚构单币种资金费或收益。

## 账户边界

- 按账户配置区分归属，并按标的汇总风险，避免重复计价。
- 三个交易所账户仍须分开呈现，不因所有权相同而混淆余额、挂单或机器人状态。
- A股账户单独统计。
- 不因不同账户持有相同资产而自动合并仓位或撤销策略。

## 变化处理

- 用户长期有效的新要求通过`scripts/record-decision.ps1`追加。
- 完整账户快照写入相应`state/current/<account>.json`并更新`observedAt`；局部账户动作必须通过账户事件脚本更新并使用`lastEventAt`。
- 每次账户 JSON 更新后运行`scripts/build-account-overview.ps1`，同步根目录可读总览。
- 实时行情推导只进入当次快照，不自动改写用户硬规则。
- Agent认为长期规则应改变时必须提出理由并获得用户确认。

### 账户动作持久化闭环

- 已获得明确结果的账户动作必须在同一任务内通过`scripts/record-account-event.ps1`写入；事件事实追加到`state/events/account-events.jsonl`，再幂等投影到当前账户JSON。
- 事件必须带稳定`eventId`。重复执行同一事件不得产生重复日志或重复当前对象；订单部分成交必须保存成交后绝对的剩余数量和已成交数量。
- `eventId`在`accountId`内唯一；不同账户可使用相同外部事件ID。`orderId`和`clientOrderId`必须作为同一订单的身份别名合并。
- 账户记忆不强制要求交易所订单ID。用户确认、截图或Agent观察到的动作结果可使用稳定本地`recordId`持久化，并明确证据来源与待核验状态。
- 每次记录事件时必须自动重放该账户所有尚未投影的历史事件；对象级较旧事件不得覆盖较新的`updatedAt`状态，终态订单不得被迟到的旧事件重新创建。
- OpenCode 的完整操作约定见根目录`OPENCODE.md`，不得依赖聊天记录记住写回步骤。
- 成交、撤单或机器人停止等终态变化必须从当前活动列表移除或转移到对应终态列表；被拒绝、失败和结果不明确的动作不得伪装成当前挂单或已成交持仓。
- `observedAt`只表示最后一次完整账户核验；`lastEventAt`只表示最后一次已确认账户动作。局部事件不得覆盖完整快照时间。
- 每次事件写入后由入口自动执行事件日志校验、当前状态一致性校验、`scripts/build-account-overview.ps1`和对应账户测试。
- `state/decisions/decisions.jsonl`只保存长期策略和用户规则，不保存单次成交、订单、机器人、转账或余额事实。
- Agent 给出含具体账户、币对、方向、价格或金额的订单建议前，必须先以 `order.proposed` 保存完整参数；该状态只进入 `proposedOrders`，不计入真实挂单。用户以后确认已经按建议操作时，以相同 `recordId` 写入 `order.created`，自动沿用已保存价量并转入当前委托，无需用户重复报参数。最新用户明确确认优先于旧的待挂、拒单或未执行判断，`decisions.jsonl`不得作为单笔账户动作是否发生的证据。
- 订单建议在标为“当前可执行”前，必须按对应平台、市场、交易对和方向校验当时有效的价格精度、数量精度、最小/最大名义金额、动态价格区间和订单数量限制。未通过任一过滤器的目标只能记录为 `order.deferred` 并列入“条件计划”，同时写明失败规则、当前有效边界与重新校验条件；不得把它写成可立即替换的挂单，也不得为了通过过滤器擅自改变策略目标价。

## 安全边界

- 本项目第一阶段只读取市场数据和本地状态，不调用交易所写接口。
- 不读取任何Agent账号的聊天记忆作为权威状态。
- 不记录API密钥、Cookie、登录凭据或助记词。

## 额度优化入口

- 先读取 `config/analysis-budget.json`。账户盘点和账户动作只运行 `scripts/get-compact-account-context.ps1`，不得启动行情采集器，也不得拼接读取全部 `state/current/*.json`。默认紧凑上下文不重复携带决策正文和长对象ID；决策只通过 `scripts/get-effective-decisions.ps1` 读取一次，具体账户动作再用 `-AccountId`、`-Symbols`、`-IncludeRecordIds` 精确获取对象身份。
- 指定币种使用 `targeted`；币圈组合分析先用 Binance/CoinMarketCap 筛选，再把最多5个入围币通过`-CandidateSymbols`交给一次`portfolio`刷新；Screener批量处理动态账户币种与入围币，桌面CDP只处理关键深拉子集。明确强制刷新时仍使用同一动态范围并增加`-ForceRefresh`，除非用户明确传入完整`-Symbols`。
- 刷新后默认运行 `scripts/get-analysis-snapshot-summary.ps1`。日常分析禁止 `-EmitFullJson`；只在摘要缺字段时按精确币种或来源读取原始快照。
- 禁止递归枚举 `.tools`、`state/runtime`、浏览器配置、归档和全部历史快照，禁止把多个大文件拼接为一次工具输出。输出截断后必须改用过滤读取，不得整份重读。
- 轮询间隔不得小于配置值，无状态变化不产生重复消息。

## 三市场长期周期预警

完整分析完成既有刷新后，运行一次 PowerShell 7 入口 `scripts/get-weekly-cycle-context.ps1`。在月度、季度判断后附上沪深300全收益、SPY、BTC的周度周期背景。账户盘点、成交记录、单纯行情查询跳过。两端只消费摘要。

历史基线位于 `state/cycle-weekly/v1`，沿用此前图表的本地数据。沪深300全收益和中证非纯债债券型基金指数均从共同起点归一化；SPY复权价配AGG，BTC美元现货配BIL。后两组按各自最后一个工作日观察归入周五。以UTC周五结束为统一截止点。数据维护时按同一来源、同一复权/归一化基准补齐成对周值，按日期排序且唯一；复权重算时复核重叠历史，不能拼接不同基点。当前没有自动周线补源；过期即披露最近日期并暂停该市场的新预警。

日常每个市场仅取截止日以前最多313个成对周值参与计算，原始历史不进入对话。Z 对照当周之前156个观测的样本标准差。过去52周排名上下20%标记年度位置；展示实际回撤、本周与四周前Z，以及左右各四周确认的同类峰谷。沪深300观察线为±2；SPY上方+2至+2.34、下方−0.78；BTC上方+2.2至+2.68、下方+0.3至+0.1。正值同样报告。低位或高位先提示观察；价格创新极值而Z背离才提示候选。月末价格与两峰间低点或两谷间高点人工核对后才能确认结构；无对应月末证据标为待确认。四周突破只代表短线反弹。不得直接生成交易指令。

日常分析不回测或调整参数。研究时隔离样本内与前瞻结果，同轮报警按事件簇审视，报告分母、未接回次数及相同期限基准。变更规则另建版本。周度背景与短周期实时快照分别注明观察日期，不以实时行情替代已完成周线。

## 研究知识库

完整分析及相关专项分析按 [板块与跨市场研究索引](knowledge/research-index.md) 检索适用案例，核对最新证据，并在事件到期后的首次相关分析补录结果。

## 按问题选择入口

| 用户问题 | 使用路径 | 交付 |
|---|---|---|
| 余额、持仓、已挂单 | 账户摘要和已确认事件；询问今天是否触价时另查同品种行情 | 时间、数量、状态和确认依据 |
| 现价或走势 | 刷新所问市场；单独询价按标的查询 | 报价时间和与上次比较的变化 |
| 值不值得买、行业周期、完整分析 | 先读账户与决策，按市场、行业、标的调用 scripts/find-research-cases.ps1 -Terms，再按既有范围刷新，核对原始公告、行情和反证 | 首选动作、失效条件、已有挂单 |
| 验证胜率和相似事件 | 按历史时点调用同一检索脚本并传 -AsOf，然后读取到期预测、基准和价格路径 | 独立样本数、相对基准结果和预警后回撤 |

混合提问按涉及的路径合并，一次刷新供各部分共用。案例无匹配时直接说明，继续查当期证据。案例排序仅用于找资料。

完整分析分别检索 A股、美股、币圈与跨市场案例；单市场问题只取相关主题。各市场锚点、账户归属和交易场所遵循上文既有规则。

