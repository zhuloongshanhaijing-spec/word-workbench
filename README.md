# 每日录词工作台 / WordWorkbench

一个面向 macOS 的本地优先英语词卡录入工具：用键盘输入课程词汇，从本机 Apple Dictionary 取得原始资料，经本机 Ollama 整理为可编辑的中文卡背，并通过 AnkiConnect 写入 Anki Deck。Anki / AnkiWeb / AnkiDroid 负责后续复习与同步。

> 项目仍处于原型阶段。请先用少量词测试自己的词典、Ollama 与 Anki 环境，再录入整本词书。

## 能做什么

- 直接新建或打开一个 Anki Deck；不同 Deck 中的相同拼写是独立笔记和独立复习进度。
- 输入英文词并查询本机 Apple Dictionary；拼写错误时显示经词典核验的候选及差异高亮。
- 批量使用本机模型整理词性、中文义项、搭配与双语例句；最终卡背始终可人工编辑。
- 默认质量模式使用 `qwen3:8b`，不截断正文，只移除 `DERIVATIVES` 和 `ORIGIN` 等不用于制卡的段落；快速模式使用 `qwen2.5:3b`，输入最多 9,000 字符。
- 每个词最长等待 55 秒；单词失败会标记并继续处理后续词；界面显示当前队列、完成数与耗时。
- 自动创建或更新本机 Anki 卡片。更新按稳定 UUID 定位，不会因重试产生重复卡。

当前不包含：OCR、音频、反向拼写卡、云端词典抓取、词典内容再分发，或对 Anki 的复习算法作改动。

## 运行要求

- macOS，已安装 Xcode Command Line Tools（提供 `swiftc`）
- [Anki](https://apps.ankiweb.net/) 与 [AnkiConnect](https://ankiweb.net/shared/info/2055492159) 插件
- [Ollama](https://ollama.com/)；默认模型为 `qwen3:8b`，快速模式需 `qwen2.5:3b`
- 在“词典”应用或 macOS Dictionary 设置中启用你可合法使用的英文词典

AnkiConnect 只应监听本机回环地址。此程序默认请求 `http://127.0.0.1:8765`，不会把词典原文或单词发送到互联网；Ollama 默认请求 `http://127.0.0.1:11434`。

## 构建与运行

```zsh
cd outputs
zsh build.sh
open "每日录词工作台.app"
```

第一次导入前：启动 Anki，在 **Tools → Add-ons** 中安装并启用 AnkiConnect。应用会在导入时尝试打开 Anki；若 AnkiConnect 尚未准备好，可稍候重试。导入完成后，使用 Anki 自己的同步功能登录 AnkiWeb；Android 上的 AnkiDroid 登录同一账户后同步。

## 使用流程

1. 新建一个 Deck，例如 `Biology Chapter 1`。
2. 输入当天词汇，查不到时从核验后的候选中选择，或添加空白手工词条。
3. 全部输入后点击“批量 AI 整理待处理词”。
4. 逐条查看并编辑“最终卡背”。词典原文会保留供核对。
5. 点击“确认并导入 Anki”。在 Anki 中审看首批卡片后，再开始日常同步和复习。

卡片正面是英文词；背面为 HTML 排版的中文义项、搭配和双语例句。Anki 的复习周期与跨设备进度由 Anki / AnkiWeb / AnkiDroid 自己管理。

## 数据、隐私与词典权利

- 应用库保存在 `~/Library/Application Support/WordWorkbench/library-v2.json`，并保留上一个有效快照 `library-v2.backup.json`。这两个文件不在仓库中。
- 本仓库只发布源代码，不发布 Apple Dictionary、Oxford、Cambridge 或其他词典的词条、例句、音频或派生数据。
- 使用本机词典不等于获得再发布词典内容的权利。若你导出、共享或公开词库，请自行确认所用词典、例句与音频的授权条件。
- 本工具不会替你登录 AnkiWeb，也不应保存任何账号、密码、令牌或第三方 API 密钥。

## 仓库结构

- `outputs/WordWorkbench.swift`：SwiftUI 应用源码
- `outputs/build.sh`：无第三方 Swift 依赖的构建脚本
- `outputs/Info.plist`：应用元数据
- `outputs/V2_DESIGN.md`：已确认的产品边界与验收标准
- `CONTRIBUTING.md`：提交问题或改动前的检查规则

## 贡献与发布

欢迎提交 Bug 报告和可复现的改动。请不要在 Issue、截图、日志或 Pull Request 中上传个人词库、Anki collection、账号信息、API 密钥，或受版权保护的整段词典内容。

发布到 GitHub 的步骤见 [PUBLISHING.md](PUBLISHING.md)。

## License

代码以 [MIT License](LICENSE) 发布；这不授予任何第三方词典内容的再发布许可。
