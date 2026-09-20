# 安全反馈 / Security Policy

## 支持版本

| 版本 | 状态 |
|---|---|
| v0.4.0 | 当前版本 |
| v0.1.0-legacy | 仅历史追溯，不再维护 |

## 反馈渠道

优先使用 **GitHub Security Advisories**（仓库 Security 标签页 → Report a vulnerability），它对维护者之外的任何人不可见。

如不可用，请开启一个**不含敏感细节**的公开 Issue，仅写"存在安全问题，请提供私下联系渠道"，由维护者跟进。请勿在公开 Issue、PR、截图或日志中包含：个人词库内容、Anki collection、账号信息、API 密钥或令牌。

## 范围

欢迎反馈（包括但不限于）：

- 应用对 AnkiConnect（`127.0.0.1:8765`）、Ollama（`127.0.0.1:11434`）、本地 reranker（`127.0.0.1:11436`）回环通信的滥用风险；
- 词库更新链路（GitHub 元数据检查、SHA-256/大小校验、解压与 SQLite 验证）的完整性缺陷；
- 任何意外的数据外发路径（本项目的设计目标是不把用户数据送出本机）；
- 构建脚本或文档中的供应链问题。

## 不在范围

- 未安装 AnkiConnect/Anki 本身的问题；
- 用户自行修改词典数据或模型权重引入的问题；
- 需要 Apple Developer 账号才能解决的公证/签名告警（已知限制，见 [PRIVACY.md](PRIVACY.md)）。
