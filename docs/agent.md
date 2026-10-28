# 星愿的规划 Agent

把一句「今晚想读一会儿书」，变成一份可以检查、修改、确认的计划。
Agent 负责找方案，用户负责决定是否采用。

## 不是把聊天回复直接写进数据库

```text
用户提出需求
  -> 后端请求模型，返回结构化工具调用
  -> App 检查授权，在本地执行允许的工具
  -> 工具结果回到模型，继续规划或调整
  -> 提交草稿，本地重新校验
  -> 用户检查 / 修改 / 确认
  -> 再次校验当前安排，事务性创建目标
```

这是一个有边界的工具调用循环，不是固定顺序的五步向导。
模型可以选择工具、根据结果调整，或者提出澄清问题；README 的截图用固定五步脚本
展示完整路径，不表示每次请求都会按这个顺序执行。

## 五个工具，分清职责

| 工具 | 数据与效果 |
| --- | --- |
| `get_planning_preferences` | 读取当前身份允许发送的已保存规划偏好 |
| `query_schedule` | 查询指定日期内的星愿目标安排，不连接 Apple Calendar |
| `find_free_slots` | 本地计算符合时长、时段与每日上限的候选空档 |
| `validate_plan` | 校验候选项的日期、时长、重复、重叠与本轮每日上限 |
| `submit_plan_draft` | 重新读取安排、校验候选项，形成待确认草稿，不直接保存为目标 |

当前日期范围为当天至第 14 天。草稿提交与用户确认都会重新校验，
不会仅凭早先一次查询结果创建。已知冲突会阻止确认；无法完整判断的项有单独提示，
需要用户明确知情，不能把它们包装成「已验证无冲突」。

过程卡片显示工具名称、状态与耗时，不在卡片中展开原始工具载荷。
取消、进入后台、身份切换或授权变化会停止／丢弃相应未完成工作。
同一工具和参数重复调用会使用本轮缓存；继续重复会停止，避免无效循环。

创建后可以撤销本批。已有打卡、记录或草稿关联的目标会保留；有同步记录的项按归档规则处理，
不是无条件删除用户已经产生的数据。

## 本地执行，不等于全程离线

工具执行器运行在 App 内；模型请求通过自行部署的后端处理。
经授权的请求文字、规划偏好与工具结果可能发往所配置的模型服务。
规划工具不会自行读取日记／随手记正文、照片、另一身份的数据，也没有任意 SQL 或命令执行入口。
用户主动在请求中输入的文字则属于请求内容，请不要输入不希望发送的资料。

App 会保存会话和计划相关数据，因此不能把这一架构描述成「不存储任何内容」。
后端 Agent 配额账本只存运行与额度元数据，不存会话／工具正文；这不代表反向代理或模型服务
采用相同的日志与保留策略，自建时需要分别检查。

每轮最多 6 次模型调用、60 秒，并有 24,000 token 的记账上限。
它们是执行与记账保护，不是对供应商最终账单或所有故障下实际 token 用量的保证。

## 如何启用

1. 按[开发指南](development.md#optional-services)配置自己的后端、HTTPS 模型端点和设备凭据。
2. 在私有服务端配置中增加独立的 `agent_ledger_database` 路径；未配置时 Agent 端点不启用。
3. 在客户端配置自己的后端，完成 AI 授权，在「规划」中使用。AI 设置中可关闭 Agent，切回普通助手。

仓库不提供公共后端、密钥或免费模型额度。当前适配器的模型限制见开发指南，
不要将其理解为支持任意模型提供方。不要把真实服务配置、设备凭据或模型密钥提交到 Git。

## 从哪里读代码

| 部分 | 入口 |
| --- | --- |
| 严格工具协议与参数结构 | [agent_contract.dart](../packages/xingyuan_core/lib/src/agent_contract.dart) |
| App 多轮执行与生命周期 | [agent_conversation_runner.dart](../lib/features/assistant/data/agent_conversation_runner.dart) |
| 授权、本地工具与新鲜数据校验 | [agent_tool_executor.dart](../lib/features/assistant/data/agent_tool_executor.dart)、[local_agent_source.dart](../lib/features/assistant/data/local_agent_source.dart) |
| 空档计算与计划规则 | [agent_planning.dart](../lib/features/assistant/domain/agent_planning.dart) |
| 可见过程与用户确认 | [agent_run_details.dart](../lib/features/assistant/presentation/agent_run_details.dart)、[assistant_proposal_page.dart](../lib/features/assistant/presentation/assistant_proposal_page.dart) |
| 确认时校验、事务与撤销 | [local_proposal_store.dart](../lib/features/assistant/data/local_proposal_store.dart) |
| 服务端调用、历史关联与额度 | [agent_runner.dart](../server/lib/src/agent_runner.dart)、[agent_protocol.dart](../server/lib/src/agent_protocol.dart)、[agent_ledger.dart](../server/lib/src/agent_ledger.dart) |

## 已实现与仍需验证

已实现工具协议、多轮执行、本地空档计算与校验、过程记录、可编辑草稿及确认／撤销保护。
离线测试覆盖授权、数据变化、冲突、重复调用、取消和确认等边界。

README 的[截图测试](../test/readme_screenshots_test.dart)使用脚本化工具调用和合成安排，
验证查询结果会回到下一轮、五种工具实际执行、确认前不新增目标、确认后才创建。
它替换的是模型传输，不是工具执行器，也不是往数据库预先塞一个结果页面。

这证明可复现的代码路径，不证明真实模型能稳定选择正确工具、理解每一种表达或给出令人满意的计划。
模型质量、原生 iOS 交互、无障碍和实际使用验收应分别验证；不要用 CI 通过代替这些结论。
