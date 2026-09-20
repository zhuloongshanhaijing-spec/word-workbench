#!/bin/zsh
# Foreground launcher for the local cross-encoder runtime.
#
# It binds to 127.0.0.1 only and never logs unit text, headwords, or glosses.
# Use start.sh to run it in the background, stop.sh to stop it.
set -eu
here="${0:A:h}"
runtime="$here/runtime/llama-b10970/llama-server"
model="$here/.cache/bge-reranker-v2-m3-Q4_K_M.gguf"
port="${WWB_RERANKER_PORT:-11436}"

if [[ ! -x "$runtime" ]]; then
  print -u2 "缺少 llama.cpp 运行时。请先运行：zsh $here/install-runtime.sh"
  exit 1
fi
if [[ ! -f "$model" ]]; then
  print -u2 "缺少模型权重。请先运行：zsh $here/download-model.sh"
  exit 1
fi

mkdir -p "$here/.cache"
print $$ > "$here/.cache/llama-server.pid"

# --reranking enables the batch /rerank endpoint; --pooling rank matches the
# cross-encoder head. One process stays warm; a query never starts a process.
exec "$runtime" \
  -m "$model" \
  --host 127.0.0.1 \
  --port "$port" \
  --reranking \
  --pooling rank \
  -c 2048 \
  -np 4 \
  --no-webui
