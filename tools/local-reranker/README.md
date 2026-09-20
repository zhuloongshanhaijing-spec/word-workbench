# 本地义项重排运行时（可选）

这套脚本提供一个**可选**的本地 cross-encoder 重排服务，用于按 Unit 语境给 Open
Dictionary 已有义项排序。它只是候选主引擎：应用在没有任何模型、服务或网络时
仍然可以查词、审核和导入。

服务只在 `127.0.0.1` 上监听，不记录单词、义项或 Unit 文本。

## 组件与许可

| 组件 | 版本 | 大小 | SHA-256 | 许可 |
|---|---|---|---|---|
| `bge-reranker-v2-m3-Q4_K_M.gguf` | BAAI/bge-reranker-v2-m3，GGUF 量化由 gpustack 提供 | 438,376,864 字节（约 418 MiB） | `e186a244ed455b4ab66ec64339ce7427a6ae13f5c0b5e544de96e50f0f8b3673` | Apache-2.0 |
| llama.cpp 运行时 | `b10970`（commit `bfdc32183`），macOS arm64 | 约 11.1 MB（解压后更大） | 归档 `7fa278a70b90afae3c3e5dd33553d4d11ebfde62725a03ff2fe6f0d3d1e29b59` | MIT |

两者都下载到被 `.gitignore` 忽略的 `tools/local-reranker/.cache/` 与
`tools/local-reranker/runtime/`，**不会进入 Git 交付**。

## 脚本

| 脚本 | 作用 |
|---|---|
| `install-runtime.sh` | 下载并校验 llama.cpp 运行时归档 |
| `download-model.sh` | 下载并校验 GGUF 权重（约 418 MiB，显式操作） |
| `serve.sh` | 前台启动服务（`start.sh` 会调用它） |
| `start.sh` | 后台启动并等待 `/health` 就绪 |
| `status.sh` | 打印健康状态、运行时版本与模型路径 |
| `stop.sh` | 停止服务 |
| `run-benchmark.sh [结果.json] [用例.json]` | 编译并运行基准，测量质量、延迟、内存和磁盘 |
| `uninstall.sh` | 删除运行时与权重缓存 |

## 使用

```zsh
# 在本仓库根目录执行
zsh tools/local-reranker/install-runtime.sh   # 显式安装运行时
zsh tools/local-reranker/download-model.sh    # 显式下载权重
zsh tools/local-reranker/start.sh             # 启动，监听 127.0.0.1:11436
zsh tools/local-reranker/status.sh            # 查看状态
zsh tools/local-reranker/stop.sh              # 停止
zsh tools/local-reranker/uninstall.sh         # 卸载
```

应用**不会**自动下载运行时或权重；设置界面只显示状态和手动命令。

如需开机自启，可把 `com.wordworkbench.reranker.plist` 中的 `__REPO_ROOT__`
替换为本仓库绝对路径后安装：

```zsh
sed "s|__REPO_ROOT__|$(pwd)|g" tools/local-reranker/com.wordworkbench.reranker.plist \
  > ~/Library/LaunchAgents/com.wordworkbench.reranker.plist
launchctl load ~/Library/LaunchAgents/com.wordworkbench.reranker.plist
```

## 基准

```zsh
# 合成契约样例（用于协议/回退验证，并用于选择阈值校准）
mkdir -p .harness-local   # 生成/输出脚本不会自建该目录
zsh tools/local-reranker/run-benchmark.sh \
  .harness-local/BENCHMARK_RESULTS.contract_fixture.json \
  benchmarks/semantic-ranking/cases.json

# 真实留出集（用于主引擎晋级判断）
mkdir -p .harness-local/heldout
/usr/bin/python3 benchmarks/semantic-ranking/generate_heldout_cases.py \
  --database .harness-local/open-dictionary/distribution.sqlite \
  --output .harness-local/heldout/heldout_cases.json
zsh tools/local-reranker/run-benchmark.sh \
  .harness-local/BENCHMARK_RESULTS.heldout.json \
  .harness-local/heldout/heldout_cases.json
```

阈值只在合成契约样例上校准；晋级判断只看真实留出集。

## 当前晋级结论：CANDIDATE

在真实留出集（24 例、22 词、6 个学科，全部来自本地 Open Dictionary v2.0）上：

| 模式 | 引擎 | top-1 | MRR | abstain 精度 | warm p95 |
|---|---|---|---|---|---|
| label_sparse | bge-reranker-v2-m3 | 0.750 | 0.843 | 0.571 | 293 ms |
| label_sparse | bge-m3 (Ollama) | **0.800** | **0.870** | 0.444 | 578 ms |
| labeled | bge-reranker-v2-m3 | 0.800 | 0.867 | 0.667 | — |
| labeled | bge-m3 (Ollama) | **0.900** | **0.910** | **0.800** | — |

本地重排在留出集上并未优于 Ollama bge-m3，因此按合同**不晋级**：默认链保持
`Ollama bge-m3 → 本地重排 → 词典标签规则`，本地重排保留为可评测候选。
完整指标、失败用例和判定规则见 `benchmarks/semantic-ranking/results/heldout.benchmark.json`。
