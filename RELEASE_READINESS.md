# 发布就绪检查表（RELEASE READINESS）

三个阶段：**A. 推送前**（本机，完成才可 push）、**B. 推送后 / Release 前**（GitHub 上）、**C. Release 后**。每一项都要留真实回执（命令 + 退出码 + 时间）；没有实际运行过的项标 `UNVERIFIED`，不得当作已通过。

## A. 推送前（本地隐私审查 + 验证）

### A1. 内容扫描（必须有记录）

```zsh
# 1) 禁止文件类型
find . -path ./.git -prune -o -type f \( -name '*.sqlite*' -o -name '*.gguf' \
  -o -name '*.apkg' -o -name '*.anki2*' -o -name '*.app' -o -name '.env*' \
  -o -name '*.dSYM' -o -name '.DS_Store' \) -print          # 期望：空

# 2) 本机路径 / 凭据样式（第二个模式覆盖 JSON 转义形式）
# 引号拆分仅为避免本检查说明本身命中；shell 实际传给 grep 的模式不变。
grep -rn -e '/'"Users/" -e '\/'"Users"'\/' -e 'BEGIN .*PRIVATE KEY' \
  -e 'api[_-]\?[kK]ey' -e 'password' --include='*' . | grep -v '^Binary'   # 期望：无命中

# 3) 用户名（词边界匹配，避免误报 "author" 等）
grep -rnw -e 'thor' --include='*' . | grep -v '^Binary'                     # 期望：无命中

# 4) 暂存清单（在 git 仓库中）
git add -A && git status --porcelain | sort
```

暂存清单中不得出现：`*.app`、`*.sqlite*`、`*.gguf`、`dist/`、`work/`、`.harness-local/`、`library-*.json`、`*.anki2*`、`*.apkg`、`.env*`、`示例词卡.csv`、`CHARTER.md`、`当前状态.md`、`DEEPSEEK_WORKBENCH.md`。

### A2. 构建 / 测试（真实回执）

```zsh
zsh tools/run-checks.sh                 # 离线检查套件（全部 PASS）
zsh tools/run-checks.sh --db <本地 distribution.sqlite>   # 真实词库契约（数据留在本机）
zsh tools/run-checks.sh --build         # 或单独 --build：完整 App 构建
codesign --verify --deep --strict outputs/每日录词工作台.app   # 构建产物签名核验
```

可选（有服务时）：`zsh tools/local-reranker/run-benchmark.sh`、`OllamaSemanticLiveCheck`、`IntegratedFlowCheck`（需 AnkiConnect，否则按 `PASS_WITH_LIMITS` 记录）。

### A3. 文档一致性

- [ ] README 与 RELEASE_NOTES_v0.4.0 描述的功能、端口（8765/11434/11436）、默认模型、回退链与代码一致。
- [ ] README「数据、隐私与词典权利」+ [PRIVACY.md](PRIVACY.md)：本机/网络行为、AnkiConnect 回环边界、CC BY-SA 4.0、模型可选与卸载、未签名分发限制，全部在文档中可找到。
- [ ] [THIRD_PARTY_DATA.md](THIRD_PARTY_DATA.md) 署名块存在；`outputs/Info.plist` 版本 = `0.4.0` = tag 名。
- [ ] 许可证状态：`LICENSE` 为未经改写的 PolyForm Noncommercial 1.0.0 文本，README 明确标示 `source-available`，不把本项目称作 OSI 开源。

### A4. 旧版保留方案确认

- [ ] `git tag -a v0.1.0-legacy ... 2c5565f` 已创建且未推送历史改写（无 `--force`）。
- [ ] 仓库设置中 **Archive repository 未开启**（保持只读 = 冻结整个仓库，禁止）。

## B. 推送后、Release 前（GitHub）

- [ ] `git push origin main v0.1.0-legacy v0.4.0` 成功；`git ls-remote --tags origin` 两个 tag 都在。
- [ ] `main` 的历史包含 `2c5565f`（`git log --oneline | grep 2c5565f` 或网页提交历史可见）。
- [ ] 构建 Release 附件：`每日录词工作台-0.4.0-macos.zip`（含词典，需附 `THIRD_PARTY_DATA.md`）、`WordWorkbench-0.4.0-source.zip`（不含词典）、`SHA256SUMS.txt`（`shasum -a 256 * > SHA256SUMS.txt`）。
- [ ] About 区域：主题词不含 "open source"，写 `source-available`（除非许可证已定为 OSI）。
- [ ] Security 标签页可创建私有 Advisory（[SECURITY.md](SECURITY.md) 的渠道可用）。

## C. Release 后

- [ ] v0.1.0-legacy Release 标题/说明明确“legacy 原型快照，已被 v0.4.0 取代”。
- [ ] v0.4.0 Release 附件 SHA-256 与 SHA256SUMS.txt 一致；含词典的 zip 解压后可见 THIRD_PARTY_DATA.md。
- [ ] 下载附件在一台干净 Mac 上做首次运行冒烟：打开 → 右键放行（未公证）→ 查一个词 → 预览卡片背面。
- [ ] 若 Release 出现问题：**修复向前**（新 commit / 新 tag），不改写已发布历史。

## 当前回执（2026-09-19，维护者机器）

最新一次验证记录见仓库外的 `OPEN_SOURCE_AUDIT.md`（维护者交接文档）与本仓库 `benchmarks/semantic-ranking/results/` 的指标说明。各项结论以 `PASS` / `PASS_WITH_LIMITS` / `UNVERIFIED` / `BLOCKED` 标注；**许可证决策为 `BLOCKED_ON_MAINTAINER_LICENSE_CHOICE`**。
