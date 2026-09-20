# 国际词典供应商筛选与申请手册

更新日期：2026-09-10。此文件是采购/授权决策记录，不包含任何密钥。

## 结论

本产品不是普通网页查词，而是“查词后保存为 Anki 卡”。因此必须同时满足四项：权威来源、可机读的词性/义项/例句、英译简体中文、以及明确允许保存到个人 Anki 的权利。没有供应商书面确认时，不能把 API 输出写进永久词库或 Anki。

| 候选 | 质量与结构 | 适配度 | 当前结论 |
|---|---|---|---|
| Oxford Dictionaries API | 国际权威；支持 English → Simplified Chinese 翻译、词性、例句、标签 | 结构最接近目标 | **首要询价对象**。普通 API 明确不允许缓存/离线；须询问个人 Anki 保存的授权与价格。 |
| Collins Dictionary API | 国际权威；定义、例句、短语、音频；个人非商业许可公开可申请 | 英语原文质量强 | **第二询价对象**。公开表单未列英汉字典，须先确认能否提供 English → Simplified Chinese。 |
| Cambridge Dictionary API | 原本最匹配 | 当前没有服务 | **排除**：Cambridge Tech Support 于 2026-09-09 书面称 API 暂不可用、不能提供 access/trial key。 |
| Open Dictionary | Wiktionary 衍生的开源学习者词典；有简中义项、词性、优先级和双语例句 | 可本地 SQLite 离线使用 | **v3 当前实际词源**，不是官方/传统出版词典；数据 CC BY-SA 4.0，必须署名与同许可再分发。 |
| Merriam-Webster API | 权威英语、学生/医学词典 | 无中文义项 | 不作为主词源；可未来仅作英文拼写/专业词补充。 |
| 机器翻译 API | 可提供中文翻译 | 不是词典，不提供权威义项边界 | 不能单独作为主词源；只可在获准的英文词典内容基础上作为翻译辅助，且需单列为机器翻译。 |

## 申请顺序

Collins 申请已提交，等待邮件回复；Oxford 注册出现“无法创建账户”错误，而且其公开缓存限制使它不适合作为当前阻塞项。不要购买付费计划或发送任何 API 密钥给本项目、GitHub 或聊天记录。

### A. Oxford Dictionaries API

1. 打开 <https://developer.oxforddictionaries.com/>，注册个人账号。
2. 可申请 Sandbox，只用于检查响应结构：它只有 500 次调用，且英语试用仅能查字母 `a` 开头的词，**不能用于本项目的真实词表**。
3. 不要把 Sandbox key 放进本机应用。先通过 <https://developer.oxforddictionaries.com/contact-us> 发送下列询问。
4. 若对方说普通 Lite/Growing 计划可用，仍要追问“将结果保存为个人 Anki 卡是否构成 caching/offline”。Oxford FAQ 当前写明，缓存或离线保存只允许 Enterprise；其 Enterprise 页面标注商业许可起价为每语言每年 GBP 5,000，个人项目通常不合适。

邮件/表单正文：

```text
Subject: Licensing enquiry — personal non-commercial macOS vocabulary-to-Anki tool

Hello Oxford Dictionaries API team,

I am an individual student building a personal, non-commercial macOS tool. I type English course vocabulary, review structured senses, and export selected cards to my own private Anki collection for spaced repetition. There is no resale, advertising, shared account, public dictionary website, or redistribution of a dictionary dataset.

I need English to Simplified Chinese translations together with part of speech, sense-level labels, and example sentences where available.

Before I integrate the API, please confirm in writing:
1. Which plan and endpoints provide English -> Simplified Chinese plus the required lexical fields?
2. Whether selected API results may be retained as private Anki cards for one user, including offline review on that user's Mac and Android device.
3. Whether this is considered caching/offline use, and the applicable licence and price.
4. Required attribution and restrictions on using a local AI only to rank and format, not create, source facts.
5. Whether a native macOS client may make requests directly with a user-owned credential, or a server proxy is required.

Thank you.
```

### B. Collins Dictionary API

1. 先完整阅读 <https://blog.collinsdictionary.com/terms-conditions-collins-api/>。
2. 打开 <https://blog.collinsdictionary.com/collins-api-apply-for-a-key/>，填写真实姓名、邮箱、国家，选择 `Non-commercial`。
3. 当前公开词典清单未出现 English–Chinese；在 `Message` 中粘贴下面文字，要求先确认数据集，而不是假定页面上的 `Chinese` 网站栏目等于 API 许可。
4. 申请表条款写明：个人非商业可申请，但不得下载、存储或缓存材料以避免再次 API 请求；因此同样必须取得“个人 Anki 卡保存”例外的书面答复。

表单 Message：

```text
I am an individual student developing a personal, non-commercial macOS vocabulary entry tool for my own Anki review. I require English-to-Simplified-Chinese senses, part of speech, and source examples/phrases where available.

Your public API application form does not list an English-Chinese dictionary. Can you confirm whether such a bilingual dataset is available through the API?

Before I use any key, please confirm whether I may retain only the selected lookup results as private Anki flashcards for one user’s offline study, and state the required attribution, licence, and any restriction on local AI formatting/ranking of returned fields. I will not redistribute data or keys.
```

## 不依赖线上供应商、现在即可使用的部分

- `Deck → Unit → Entry → Part of speech → Sense` 的本地数据迁移。
- 可视化审核器：勾选义项、删除搭配、标记错误词性组、编辑显示文本；不暴露 HTML。
- 供应商中立的 `DictionarySource` 适配器协议和离线 JSON 测试夹具。
- 输入错误的拼写候选、字符差异高亮、手动修改/删除。
- 本地 Ollama 队列、超时、失败续跑；它只处理已规范化字段，不从原文猜造搭配或例句。
- 生成 Anki HTML、稳定 ID 更新、AnkiConnect 重试安全性、Unit tag 和真实 Anki 导入验收。
- Open Dictionary SQLite 解码适配器、离线测试夹具与 Unit 领域排序；用户自行下载/选择数据包后即可实际查词。

## 接入门槛

收到供应商回复后，只有同时满足下列条件才会接入：

1. 明确提供 English → Simplified Chinese，且响应能保留词性和义项边界；
2. 明确允许本工具的私人 Anki 保存、跨 Mac/Android 离线复习；
3. 条款允许本地展示所需的例句/短语，并给出署名要求；
4. 用户自己取得并保管凭据；密钥只进入 macOS Keychain；
5. 用 `organism`、`strain`、专业术语和拼错词完成真实小样验收。

未通过任何一项时，适配器保持禁用，项目不通过网页抓取绕开供应商规则。
