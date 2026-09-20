# 每日录词工作台 / WordWorkbench

一个面向 macOS 的本地优先英语词卡录入工具：用键盘输入课程词汇，从 Open Dictionary SQLite 词库取得结构化中文义项和双语例句，形成可视化、可编辑的卡片预览，并通过 AnkiConnect 写入 Anki Deck。Anki / AnkiWeb / AnkiDroid 负责后续复习与同步。

> 项目仍处于原型阶段。请先用少量词测试本地词库、AnkiConnect 与 Anki 导入，再录入整本词书。

## 能做什么

- 直接新建或打开一个 Anki Deck；不同 Deck 中的相同拼写是独立笔记和独立复习进度。
- 从本地 Open Dictionary 查询词性、简中义项、来源自带的双语例句与 `core/common/rare` 优先级；不再依赖 Apple Dictionary。
- 在一个 Anki Deck 内新建 Unit（章节/主题/可选说明），例如“生物 / 细胞膜、代谢 / 细胞膜的组成和跨膜运输”；Unit 不创建 Anki 子 Deck，也不改变 Anki 复习算法。
- 按 Unit 语境（学科、主题、说明）给该词的全部义项排序，并且只默认勾选高置信义项；语境不足时全部默认关闭。默认主引擎是本机 [Ollama](https://ollama.com/) 的 `bge-m3`；它不可用时回退到可选的本地 cross-encoder（`bge-reranker-v2-m3`，见 `tools/local-reranker/`），最后回退到透明的词典标签规则。任何引擎都只计算相关性分数，不生成或改写释义、例句、搭配。
- 在独立真实留出集上，本地 cross-encoder 并未优于 `bge-m3`，因此按验收规则保留为候选（`CANDIDATE`），默认链仍是 `bge-m3 → 本地重排 → 词典标签规则`。评测数据、失败用例和判定规则见 `benchmarks/semantic-ranking/results/`。
- 以可视化区块审核词性、义项、绑定例句与搭配：可取消不相关义项、编辑文字、删除不恰当搭配或整词，然后再导入。
- Open Dictionary 未收录时给出本机拼写候选；用户可更正后重查或暂不录入。
- 自动创建或更新本机 Anki 卡片。更新按稳定 UUID 定位，不会因重试产生重复卡。
- 正式 macOS 发布包可内置 Open Dictionary；应用启动时自动检查官方 Release 的更新元数据。更新包仅在用户确认后下载，并依次校验大小、SHA-256、解压结果和 SQLite 查询，失败时保留旧词库。

当前不包含：OCR、音频、反向拼写卡、云端词典抓取、词典内容再分发，或对 Anki 的复习算法作改动。

## 运行要求

- macOS，已安装 Xcode Command Line Tools（提供 `swiftc`）
- [Anki](https://apps.ankiweb.net/) 与 [AnkiConnect](https://ankiweb.net/shared/info/2055492159) 插件
- 可选：[Ollama](https://ollama.com/)；在应用“设置”的“回退 1：Ollama bge-m3（可选）”分组中下载 `bge-m3`（约 1.2GB）。未安装模型时应用自动退回离线的词典标签推荐。
- 可选：本地 cross-encoder 重排（`bge-reranker-v2-m3`）。它是**候选**主引擎，需要显式安装约 418 MiB 权重与 llama.cpp 运行时：`zsh tools/local-reranker/install-runtime.sh && zsh tools/local-reranker/download-model.sh`，详见 `tools/local-reranker/README.md`。应用不会自动下载。
- 正式 Release 若包含内置词库，首次启动会自动复制到 `~/Library/Application Support/WordWorkbench/Dictionary/`。开发者构建或未内置数据的包，可在“设置”中选择已有 SQLite，或从 [Open Dictionary Releases](https://github.com/ahpxex/open-dictionary/releases) 下载。

AnkiConnect 只应监听本机回环地址。此程序默认请求 `http://127.0.0.1:8765`；当前运行版本不会将单词或词典材料上传至互联网。

## 构建与运行

```zsh
cd outputs
zsh build.sh
open "每日录词工作台.app"
```

第一次导入前：启动 Anki，在 **Tools → Add-ons** 中安装并启用 AnkiConnect。应用会在导入时尝试打开 Anki；若 AnkiConnect 尚未准备好，可稍候重试。导入完成后，使用 Anki 自己的同步功能登录 AnkiWeb；Android 上的 AnkiDroid 登录同一账户后同步。

## 使用流程

1. 若 Release 含内置词库，直接新建词书；否则在“设置”中选择 `distribution.sqlite`。
2. 可选：在“设置”的“回退 1：Ollama bge-m3（可选）”分组中检测 Ollama 并下载 `bge-m3`。模型下载后只在本机运行。
3. 新建一个 Deck，例如 `Biology Vocabulary`，再在其内新建 Unit，例如 `Chapter 1 / 生物 / 细胞膜, 代谢 / 细胞膜的组成和跨膜运输`。
4. 键入当天词汇并查询；高相关义项会显示“推荐”并默认勾选。所有候选仍会保留，低置信度项默认不勾选。
5. 在可视化预览中查看推荐理由，取消不相关义项，或手动勾选被遗漏的义项。
6. 修改 Unit 主题后，点击“重新推荐本 Unit”重新计算本 Unit 内已有词条。
7. 点击“导入 Anki”。在 Anki 中审看首批卡片后，再用 AnkiWeb 同步到 AnkiDroid。

卡片正面是英文词；背面为 HTML 排版的中文义项、搭配和双语例句。Anki 的复习周期与跨设备进度由 Anki / AnkiWeb / AnkiDroid 自己管理。

## 数据、隐私与词典权利

- 应用库保存在 `~/Library/Application Support/WordWorkbench/library-v3.json`，不在仓库中。
- 本仓库只包含本项目源码，不包含 Open Dictionary 的任何数据文件。正式 `.app` 若内置该词库，其数据是 Wiktionary 衍生内容，适用 CC BY-SA 4.0；导出、公开或再分发包含其词条/例句的内容前，必须遵守该数据许可及署名要求。详见 [THIRD_PARTY_DATA.md](THIRD_PARTY_DATA.md)。
- 网络与隐私边界（本机行为、回环端口、更新检查）单列于 [PRIVACY.md](PRIVACY.md)。
- Collins、Oxford 等线上权威词典只保留供应商中立接口；在取得书面授权并确认缓存/制卡权利前，不下载、不缓存、不写入其内容。
- 本工具不会替你登录 AnkiWeb，也不应保存任何账号、密码、令牌或第三方 API 密钥。
- Ollama 仅通过 `http://127.0.0.1:11434` 在本机通信；发送给它的是 Unit 文本和已从本地词库读取的候选义项。应用不调用云端生成式 AI，也不将模型分数写进 Anki 卡片。

## 仓库结构

- `outputs/WordWorkbenchV3.swift`：当前 SwiftUI 应用源码
- `outputs/OpenDictionaryAdapter.swift`：本地 Open Dictionary SQLite 解码适配器；按发布契约用 `(pos, etymology_id, sense_id)` 生成稳定义项身份
- `outputs/WordWorkbenchCore.swift`：领域排序、卡片模型与 Anki 导入核心
- `outputs/OllamaSemanticRecommender.swift`：Ollama 本地 embedding 调用、语义评分与故障回退桥接
- `outputs/LocalSemanticReranker.swift`：本地 cross-encoder 重排客户端（127.0.0.1:11436）
- `outputs/SemanticEngineCoordinator.swift`：`sourceSenseID` 严格校验、超时、有序回退、保守预选与晋级判定
- `outputs/build.sh`：无第三方 Swift 依赖的构建脚本
- `outputs/Info.plist`：应用元数据
- `outputs/OpenDictionaryLifecycle.swift`：词库发布元数据检查与用户确认后的校验下载
- `outputs/tests/`：离线可运行的契约/回退/推荐检查程序（入口见 `tools/run-checks.sh`）
- `outputs/WordWorkbench.swift` + `V2_DESIGN.md`：旧 Apple Dictionary 原型的历史源码与设计记录，不参与当前构建
- `outputs/V3_CHARTER.md`：当前产品边界与验收标准
- `benchmarks/semantic-ranking/`：合成契约样例、真实留出集生成脚本、基准程序与最近一次指标（`results/`）
- `tools/local-reranker/`：可复现的本地重排运行时脚本（模型与运行时均被忽略，不进入交付）
- `tools/run-checks.sh`：一条命令跑完离线检查套件
- `CONTRIBUTING.md` / `PRIVACY.md` / `SECURITY.md` / `PUBLISHING.md`：贡献规则、隐私说明、安全反馈与发布步骤

## 语义排序的验证方式

- `benchmarks/semantic-ranking/cases.json`：30 条**合成契约样例**，只验证协议、ID 对齐与回退，并且是选择阈值唯一允许校准的数据。
- 真实留出集：由 `benchmarks/semantic-ranking/generate_heldout_cases.py` 从本地 Open Dictionary v2.0 记录导出（24 例、22 词、6 个学科，含日常/专业义冲突、词性冲突与应弃权样例）。它不参与阈值校准，最终指标只从它报告。
- 生成文件含 CC BY-SA 4.0 词典文本，写入被忽略的 `.harness-local/`，不提交到本仓库。
- 最近一次维护者机器上测得的指标（已去除本机路径）提交在 `benchmarks/semantic-ranking/results/`：`heldout.benchmark.json` 为留出集判定依据，`contract-fixture.benchmark.json` 为契约样例。
- 离线检查套件（协议、ID 对齐、回退、夹具解码）可用 `zsh tools/run-checks.sh` 复跑。
- 留出集复现命令（在本仓库根目录、已自备 `distribution.sqlite` 时）：

```zsh
mkdir -p .harness-local/heldout        # 生成脚本与基准程序不会自建输出目录
/usr/bin/python3 benchmarks/semantic-ranking/generate_heldout_cases.py \
  --database .harness-local/open-dictionary/distribution.sqlite \
  --output .harness-local/heldout/heldout_cases.json
zsh tools/local-reranker/run-benchmark.sh \
  .harness-local/heldout/BENCHMARK_RESULTS.json \
  .harness-local/heldout/heldout_cases.json
```

## 贡献与发布

欢迎提交 Bug 报告和可复现的改动。请不要在 Issue、截图、日志或 Pull Request 中上传个人词库、Anki collection、账号信息、API 密钥，或受版权保护的整段词典内容。安全问题的私下反馈渠道见 [SECURITY.md](SECURITY.md)。

发布到 GitHub 的步骤（含旧版 `v0.1.0-legacy` 标记方案）见 [PUBLISHING.md](PUBLISHING.md)。

## License

本项目以 [PolyForm Noncommercial 1.0.0](LICENSE) 发布，是 **source-available** 软件，而不是 OSI 定义的开源软件。个人学习、研究、实验、兴趣项目及其他非商业用途可以依许可证使用、修改和分发；商业部署、收费产品、面向客户的服务、付费集成或其他营利用途，须先与维护者协商并取得单独的书面商业许可。

如需商业许可，请在 GitHub 以不含敏感材料的方式提出 `commercial licensing` 联系请求；维护者会提供后续私下联系渠道。公开源码不等于取得商业使用授权。

无论使用场景如何：

- 第三方 Open Dictionary 数据始终独立适用其 [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) 条款，不被本项目许可证覆盖、收归或改写；
- 本项目不拥有也不声称拥有 Anki、AnkiConnect、Ollama、模型权重或其商标的权利。
