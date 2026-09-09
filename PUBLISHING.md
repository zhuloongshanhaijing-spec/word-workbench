# 发布到 GitHub

此目录已经排除本机构建产物、缓存和词库数据。连接 GitHub 后，在项目根目录执行：

```zsh
git init
git add .
git status
git commit -m "Initial open-source release"
gh repo create word-workbench --public --source=. --remote=origin --push
```

如果不用 GitHub CLI，请先在 GitHub 网站创建一个**空仓库**（不要初始化 README、LICENSE 或 `.gitignore`），再执行：

```zsh
git init
git add .
git status
git commit -m "Initial open-source release"
git branch -M main
git remote add origin https://github.com/YOUR_ACCOUNT/word-workbench.git
git push -u origin main
```

在 `git add .` 后务必先运行 `git status`，确认暂存区只有源码、文档、许可证与配置；特别确认没有 `每日录词工作台.app`、`work/`、`library-v2.json`、`.anki2`、`.apkg`、`.env` 或真实词典内容。

建议仓库名称：`word-workbench`。建议首个 GitHub Release 仅附源码，不附带预编译 App；若未来分发应用，请另行处理 macOS 代码签名与公证。
