# 成熟开源项目的采用边界

本项目采用成熟项目的**架构模式**和公开数据契约，不复制不兼容许可证的源代码。

| 项目 | 可借鉴内容 | 本项目采用方式 | 不采用内容 |
|---|---|---|---|
| `ahpxex/open-dictionary`（代码 MIT；数据 CC BY-SA 4.0） | `distribution_entry_v5` 的词性→义项→例句结构；义项优先级；SQLite 离线工件与校验和 | `OpenDictionarySource` 解码到本项目中立的 `SourceEntry`；后续做用户明确确认后的下载、SHA-256 校验和本地查询 | 不把词库数据混入源码仓库；不称为出版词典；不直接复用其生成管线 |
| `ahpxex/Aictionary`（MIT） | 本地 SQLite 首次下载、校验、离线查词；AnkiConnect 导出；词义优先级折叠 | 借鉴模块边界：`dictionary package → normalized entry → visual review → Anki export` | 不复制 Tauri/React 代码；本项目继续保持原生 SwiftUI |
| `raine/anki-llm`（MIT） | 批量任务的预览、可恢复队列、单条重试、人工编辑后导入 | 将 AI 队列和审核分为独立阶段，失败不阻塞其他条目 | 不引入 CLI/TUI 或其 Python 实现 |
| AnkiConnect（AGPL） | 官方 HTTP 动作模型和幂等更新思路 | 只调用公开 API；保留稳定 UUID、更新已有 note 而非重复添加 | 不复制 AGPL 源码到本项目 |

## 采用原则

1. 数据许可和代码许可分开显示；用户下载 Open Dictionary 前必须看到 CC BY-SA 4.0 提示。
2. 所有词源先转换为 `SourceEntry`，再进入 Unit 排序与可视审核；UI 不依赖某个供应商的原始 HTML。
3. AI 只能处理规范化字段，不能弥补没有来源的释义、搭配或例句。
4. 任何引入的开源代码都必须在许可证兼容、归属和安全审查后才会复制；目前没有复制外部项目代码。
