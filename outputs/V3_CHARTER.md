# WordWorkbench v3 执行章程

## 用户结果

用户在 Mac 键盘输入课程单词；同一本词书对应一个 Anki Deck，仍能跨单元混合复习。工作台在该 Deck 内创建仅供录入和编辑使用的“单元”，每个单元拥有独立主题、学科和义项排序规则。用户审核可视化词卡板块后，一次性导入同一个 Anki Deck。

## v3 产品边界

- Anki Deck 是唯一的 Anki 复习单位；工作台“单元”绝不创建 Anki 子 Deck。
- 单元是录入语境单位，例如 Biology、Environment、Humanities、Emotion；同一 Deck 内不同单元可用不同的专业义优先规则。
- 用户不审核词典来源、领域标签或 HTML。用户审核的最小单位是“词性组下的一条义项及其绑定例句”。
- 用户的审核目标是决定是否展示该义项，不是判断词典事实真伪。
- 卡片编辑界面必须渲染为可勾选的视觉板块；HTML 只在导出时由程序生成。
- AI 不得创造词义、英文例句或搭配。没有可靠搭配时不显示搭配区。
- 本机 Ollama embedding 模型只返回 Unit 语境与已存在候选义项的相关性分数；该分数只能影响排序、推荐标识和默认勾选，不能改变词典事实。
- Anki 继续独立处理调度、复习和 AnkiWeb/AnkiDroid 同步。

## 数据与隐私

- Cambridge 于 2026-09-09 书面确认其 API 当前不可用；它不再是候选主词源。
- Oxford Dictionaries API 的注册目前出现“无法创建账户”错误；即使修复，普通计划也不允许缓存/离线保存其内容，故不再阻塞 v3，也不能在取得书面许可前用于导出 Anki 卡。
- Collins API 是权威英语词典候选。用户已提交个人非商业申请，正等待回复；其公开申请表未列英汉数据，仍必须书面确认可提供的中英方向与 Anki 保存权。
- 任何供应商的 key 只能存于 macOS Keychain；绝不写进源代码、Git、日志或提示词。
- 在收到书面许可前，不实现第三方词典内容的长期缓存、公开分发或 AI 改写；只构建适配器接口与测试夹具。
- Open Dictionary 是 v3 当前实际的本地词源；界面必须标明其是 Wiktionary 衍生的开源学习者词典，不得标称为 Oxford、Cambridge 或官方认证词典。其 CC BY-SA 数据许可必须与本项目代码许可（见仓库 README 的 License 节，决策待定）分离，不能因“开源”而默认可再分发。
- Apple Dictionary 不再是 v3 的主词源。旧版本功能保留为可回退的本地原型，不能决定 v3 数据结构。

## 输入与输出契约

### 单元档案

```json
{
  "name": "Genetics",
  "subject": "Biology",
  "topics": ["genetics", "microbiology"],
  "preference": "course-terms-first"
}
```

### 规范化义项

```json
{
  "id": "stable-local-id",
  "partOfSpeech": "noun",
  "gloss": "品系；菌株",
  "examples": [{"english": "...", "chinese": "..."}],
  "collocations": [{"english": "...", "chinese": "..."}],
  "selected": true,
  "internalProvenance": "not shown in review UI"
}
```

`internalProvenance` 必须存在，供重试、合规和故障诊断使用，但不会显示在用户审核卡或 Anki 卡背中。

## 本机语义推荐政策

默认模型为 Ollama 管理的 `bge-m3`；模型不可用时按序回退到可选的本地 cross-encoder 重排（`bge-reranker-v2-m3`，需显式安装），再退回词典标签规则。输入为 Unit 的学科、主题、说明，以及 Open Dictionary 已规范化的词性、义项、例句与领域标签。

1. 模型只输出向量相似度或相关性分数，不输出释义文本、JSON 卡片或自然语言回答。
2. 程序按当前引擎的校准相关性分数排序；领域标签与词库优先级不参与引擎分数加权，只用于透明的词典标签规则回退与推荐理由展示。
3. 只有分数达到保守阈值（置信下限，且对第二名保持足够领先幅度）的义项默认勾选；其余全部保留给用户审核。
4. 每个推荐项必须显示可解释的理由；用户可随时修改勾选，或在修改 Unit 后重新推荐。
5. 不向云端发送 Unit、单词、词典内容或 Anki 数据；仅调用 `127.0.0.1` 上的 Ollama。

## 交付阶段与验收

### P0：当前本地词源（已实施）

用户主动安装 Open Dictionary 的 `distribution.sqlite`；程序只读查询其结构化字段，并将领域标签用于 Unit 内的显示排序。公开代码不带该数据包。

**验收**：`strain` 在 `biology / microbiology` Unit 中优先展示“品系；菌株”；未匹配的通用义项仍可由用户保留或取消。

### P1：内部单元与审核数据模型（已实施）

使用独立 v3 本地库，创建 `DeckProfile -> Unit -> Entry -> PartOfSpeech -> Sense` 模型；不会覆盖旧 Apple 原型库。

**验收**：一个 Deck 可有 Biology 与 Environment 两个单元；进入 Anki 后所有选中卡仍在一个 Deck。

### P2：可视化审核器（已实施基础版）

按单词、词性、义项、绑定例句、搭配渲染；支持折叠、勾选义项、删除搭配、重新整理一个词性组。禁止直接编辑 HTML。

**验收**：`organism` 的英文定义不会出现在搭配区域；用户可一键取消不相关义项。

### P3：词源适配器（Open Dictionary 已实施）

实现 `DictionarySource` 协议、离线测试夹具和 Open Dictionary SQLite 适配器。其他供应商只在授权完成后启用。

**验收**：`strain` 在 Genetics 单元中能将“品系/菌株”排为推荐项；无来源搭配不显示。

### P4：本机语义推荐与 Anki 导出（已实施基础版）

程序生成 Anki HTML。导出保留稳定 ID，并给选中词条打 Unit tag，但不改变 Deck。Ollama 的 `bge-m3` 仅做本机语义评分；模型不可用时回退至词典标签规则。

**验收**：重复导入不创建重复笔记；同 Deck 内跨单元卡可正常混合复习。

### P5：真实材料验收（待用户安装本地数据包与 AnkiConnect）

用至少 20 个真实 Biology/TOEFL 词测试输入、排序、审核、导入和手机同步；记录错误类别，不宣称超过证据的正确率。

## 非目标

- 不抓取 Cambridge/Oxford 网页。
- 不公开分发任何未获许可的词典内容、例句或音频。
- 不改变 Anki 间隔重复算法。
- 不在 v3 首版加入 OCR、音频或自动反向拼写卡。
