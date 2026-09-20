# 更新 GitHub 上的 word-workbench 仓库（v0.4.0）

现有公开仓库已包含旧版提交（`2c5565f`）。本方案把它保留为可追溯历史：**给旧提交打 legacy tag、发布 v0.4.0 新版本**。不使用 GitHub 的 Archive repository（那会让整个仓库只读、无法再更新），也**绝不改写或 force-push 公开历史**。

推送前请先完成 [RELEASE_READINESS.md](RELEASE_READINESS.md) 中"推送前"检查表。当前代码以 PolyForm Noncommercial 1.0.0 source-available 条款发布；发布前仍须由维护者确认公开署名与商业联系入口。

## 0. 前置检查

```zsh
git clone https://github.com/<YOUR_ACCOUNT>/word-workbench.git
cd word-workbench
git log --oneline -5          # 确认 2c5565f 在历史中
git cat-file -t 2c5565f       # 应输出 commit
```

## 1. 标记旧版（不改写历史）

```zsh
git tag -a v0.1.0-legacy -m "Legacy prototype snapshot (Apple Dictionary era).
Superseded by v0.4.0; kept for traceability. Do not build from this tag." 2c5565f
git tag -l                   # 确认 tag 已创建、仍指向 2c5565f
```

> tag 只是在现有提交上加指针，不移动 `main`、不改动任何历史提交，可随时在推送前用 `git tag -d v0.1.0-legacy` 撤销。推送后的 tag 属于公开历史，不应删除或重指。

## 2. 合入当前版本

```zsh
# 在克隆目录内，用候选树内容覆盖工作区（候选树不含模型/SQLite 数据；
# work/、*.app 等本地产物即使随 rsync 带入，也会被 .gitignore 忽略，下方 git status 仍需逐行核对）
rsync -a --delete --exclude='.git' /path/to/WordWorkbench-public-candidate/ ./

git add -A
git status                    # 逐行核对暂存清单：只应有源码、文档、脚本、fixtures
git diff --cached --stat
git commit -m "Release v0.4.0: local semantic sense recommendation with Open Dictionary"
```

暂存清单中**不得出现**：`*.app`、`*.sqlite`、`*.gguf`、`dist/`、`work/`、`.harness-local/`、`library-v*.json`、`*.anki2`、`*.apkg`、`.env*`、`示例词卡.csv`。

## 3. 标记新版并推送

```zsh
git tag -a v0.4.0 -m "WordWorkbench v0.4.0" 
git push origin main
git push origin v0.1.0-legacy v0.4.0
```

如遇推送被拒（远端有新提交），用 `git pull --rebase origin main` 前移本地提交；**不要用 `--force`**。

## 4. 创建两个 GitHub Release

**v0.1.0-legacy**（标记旧版，不需附件）：
- Target tag: `v0.1.0-legacy`；标题：`v0.1.0-legacy (legacy prototype)`
- 说明：这是早期原型快照（Apple Dictionary 词源时代），已被 v0.4.0 取代，仅作历史追溯，不建议构建使用。

**v0.4.0**（当前版本）：
- Target tag: `v0.4.0`；说明使用 `RELEASE_NOTES_v0.4.0.md` 的内容。
- 附件（构建后放入 `dist/`，`dist/` 不进 Git）：
  - `每日录词工作台-0.4.0-macos.zip`：含完整 Open Dictionary 的 macOS 应用包；
  - `WordWorkbench-0.4.0-source.zip`：不含任何词典数据的源码包；
  - `SHA256SUMS.txt`：以上附件的校验和。
- 含词典数据的附件必须随包附带 `THIRD_PARTY_DATA.md`（CC BY-SA 4.0 署名与 ShareAlike 义务见该文件）。

## 5. 仓库设置（可选但建议）

- 不要 Archive repository。
- 在 About 中标注 `source-available`（许可证定稿前不要写 "open source"）。
- 开启 GitHub Security Advisories，作为 [SECURITY.md](SECURITY.md) 的私下反馈渠道。

## 未签名 macOS 分发限制

当前 App 使用本机临时签名（ad-hoc），未经过 Apple Developer ID 公证。外部用户下载后，macOS 可能要求在 Finder 中右键"打开"一次，或在系统设置中明确允许。要获得无警告的分发体验，需要 Apple Developer 账号完成 Developer ID 签名与 notarization——见 [RELEASE_READINESS.md](RELEASE_READINESS.md) 的后续项。
