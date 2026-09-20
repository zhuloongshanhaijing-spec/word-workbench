# 贡献指南

## 提交前检查

1. 不要提交 `每日录词工作台.app`、`work/`、`dist/`、Anki collection、导出的词库、词典原文（`*.sqlite`/`*.gguf` 一律不进仓库）、截图中的个人数据或任何密钥。
2. 运行离线检查套件（含协议、回退、推荐与夹具解码）：

   ```zsh
   zsh tools/run-checks.sh          # 离线检查
   zsh tools/run-checks.sh --build  # 离线检查 + 完整 App 构建
   ```

3. 用一个普通测试词验证：查询、手动编辑卡背、批量整理、导入 Anki。不要在公开 Issue 中粘贴完整词典返回内容。
4. 如改动 AnkiConnect 调用，请确保只使用 `127.0.0.1`，并说明如何安全重试失败的导入。
5. 安全或隐私相关问题请走 [SECURITY.md](SECURITY.md) 的私下渠道，不要开公开 Issue。

## 设计原则

- 词典原文是本地核对材料，不是本项目要收集或再分发的数据集。
- AI 输出是候选，不应绕过人工编辑，也不应凭空添加搭配或例句。
- Anki 的调度数据由 Anki 管理；不要直接修改其 collection 数据库。
- 新功能优先在一个小 Deck 中完成端到端测试。
- Open Dictionary 数据（CC BY-SA 4.0）与本项目代码许可互相独立；不要把数据文件、导出或评测生成物提交进仓库，生成物写到被忽略的 `.harness-local/`。

## 许可证状态

仓库许可证尚在最终决策中（方向为个人非商业 source-available，见 [README.md](README.md) 的 License 节）。提交贡献前请知悉：你的改动将按仓库**最终选定**的许可证分发；如对此有疑问，请先在 Issue 中讨论而不是直接提交。
