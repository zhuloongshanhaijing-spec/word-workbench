#!/bin/zsh
# Report whether the local reranker is reachable, and its runtime/model identity.
set -eu
here="${0:A:h}"
port="${WWB_RERANKER_PORT:-11436}"

if ! curl -fsS -m 3 "http://127.0.0.1:$port/health" 2>/dev/null; then
  print "未检测到本地重排服务（http://127.0.0.1:$port）。"
  exit 1
fi
print ""
print "健康检查通过：http://127.0.0.1:$port"
curl -fsS -m 3 "http://127.0.0.1:$port/props" | /usr/bin/python3 -c '
import json, sys
props = json.load(sys.stdin)
print("运行时:", props.get("build_info", "unknown"))
print("模型:", props.get("model_path", "unknown"))
print("量化:", props.get("model_ftype", "unknown"))
'
