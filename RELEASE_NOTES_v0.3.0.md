# 每日录词工作台 v0.3.0

## 这是什么

面向 macOS 的本地优先英语词卡录入工具：键盘录入课程词汇，审核结构化中文义项和例句，再写入 Anki Deck。Anki/AnkiWeb/AnkiDroid 继续负责复习调度与跨设备同步。

## 本版新增

- 重新设计的工作台：词书侧栏、录入收集箱、审核模式与 Anki 卡片预览。
- Deck 内 Unit 的课程语境排序；Unit 不会创建 Anki 子 Deck。
- Open Dictionary 已内置在 macOS 应用包中，首次启动自动复制到应用专属目录。
- 启动时自动检查 Open Dictionary 官方 Release 元数据；更新需用户确认，并会校验文件大小、SHA-256、解压结果及 SQLite 查询后才替换旧词库。
- 更清晰的拼写恢复、导入状态和撤销删除交互。

## 安装

1. 下载 `每日录词工作台-0.3.0-macos.zip` 并解压。
2. 将「每日录词工作台.app」拖入“应用程序”。
3. 首次启动后，在设置中确认本地词库状态；安装并启用 AnkiConnect 后即可导入 Anki。

当前版本未使用 Apple Developer ID 公证。若 macOS 拦截，请在 Finder 中右键 App 选择“打开”，再确认一次；不要关闭系统安全功能。

## 数据许可

该应用包包含 Open Dictionary 的 `distribution.sqlite` 数据。它是 Wiktionary 衍生内容，适用 CC BY-SA 4.0；完整署名、许可和更新策略见 App 包内及仓库中的 `THIRD_PARTY_DATA.md`。本项目代码的许可条款以仓库 [LICENSE](LICENSE) 文件与 [README.md](README.md) 的 License 节为准。

## 已知限制

- 只支持 macOS 13 或更高版本。
- OCR、真人音频、反向拼写卡和词典网页抓取不在本版本中。
- 自动更新只更新 Open Dictionary 数据，不自动更新应用程序代码。
