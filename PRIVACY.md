# 隐私与网络行为说明

WordWorkbench（每日录词工作台）是本地优先的 macOS 工具。本文件说明它在本机保存什么、通过什么网络地址通信、哪些内容会离开你的电脑。

## 本机保存的数据

| 数据 | 位置 | 说明 |
|---|---|---|
| 你的词书/词条/勾选 | `~/Library/Application Support/WordWorkbench/library-v3.json` | 应用数据库；不进 Git 仓库，开发者无法访问 |
| Open Dictionary 词库副本 | `~/Library/Application Support/WordWorkbench/Dictionary/` | 从应用包复制或由你确认下载；适用 CC BY-SA 4.0（见 [THIRD_PARTY_DATA.md](THIRD_PARTY_DATA.md)） |
| 可选 reranker 运行时与权重 | `tools/local-reranker/runtime/`（llama.cpp 运行时）与 `tools/local-reranker/.cache/`（权重、日志、pid），均在仓库内被 `.gitignore` 忽略 | 仅在你显式安装后存在；卸载命令见 `tools/local-reranker/uninstall.sh` |

## 网络行为（完整清单）

应用只与以下地址通信：

| 地址 | 方向 | 载荷 | 时机 |
|---|---|---|---|
| `http://127.0.0.1:8765`（AnkiConnect） | 本机回环 | 导入卡片的笔记字段 | 你点击"导入 Anki"时；AnkiConnect 只应监听回环地址 |
| `http://127.0.0.1:11434`（Ollama，可选） | 本机回环 | Unit 的学科/主题/说明文本和已从本地词库读取的候选义项 | 语义推荐时；模型只返回相关性分数 |
| `http://127.0.0.1:11436`（本地 reranker，可选） | 本机回环 | 同上 | 语义排序时：自动链中排在 Ollama 之后，或你把本地重排设为主引擎时在先；设置中“检测本地重排服务”按钮也会访问 `/health` |
| `https://api.github.com`（Open Dictionary Release 元数据） | 出站 HTTPS | 仅请求官方 Release 元数据，**不携带任何你的数据** | 启动时自动检查词库更新，也可在设置中手动点“检查更新” |
| GitHub Releases 下载 | 出站 HTTPS | 下载 `distribution.sqlite.gz`（约 217 MB） | 仅在你于设置中确认更新后 |

**不会发生的事**：不上传你的词库、词条、勾选记录或 Anki 数据；不调用云端生成式 AI；不把模型分数写进 Anki 卡片；不含遥测、分析或广告 SDK；不保存 AnkiWeb 账号、密码、令牌或任何第三方 API 密钥（AnkiWeb 同步由 Anki 自己完成）。

## 模型是可选的

- 默认推荐引擎是本机 Ollama 的 `bge-m3`（约 1.2 GB），在应用“设置”的“回退 1：Ollama bge-m3（可选）”分组中**手动**下载；不安装也能正常查词、审核、导入 Anki（回退到透明的词典标签规则）。
- 候选本地 cross-encoder（`bge-reranker-v2-m3`，约 418 MiB + llama.cpp 运行时）同样只经显式脚本安装：`zsh tools/local-reranker/install-runtime.sh && zsh tools/local-reranker/download-model.sh`；卸载：`zsh tools/local-reranker/uninstall.sh`。
- 任何引擎都只计算"Unit 语境—候选义项"的相关性分数，不生成、翻译或改写词典释义、例句、搭配。

## 词典数据权利

Open Dictionary 数据是 English Wiktionary（经 Wiktextract 抽取、Open Dictionary 整理）的衍生内容，适用 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)。若你导出、公开或再分发包含其词条/例句的内容，必须遵守该数据许可及署名要求；它与本项目源码许可是两回事。

## 未签名 macOS 分发的限制

正式 Release 的 `.app` 目前使用临时（ad-hoc）签名，未做 Apple Developer ID 公证。首次打开时 macOS 可能拦截：请在 Finder 中右键 App 选"打开"并确认一次，或在"系统设置 → 隐私与安全性"中允许。不要为此关闭系统安全功能。

## 安全反馈

发现与隐私或安全相关的问题，请按 [SECURITY.md](SECURITY.md) 的渠道私下反馈，不要在公开 Issue 中粘贴词库、日志或截图中的个人数据。
