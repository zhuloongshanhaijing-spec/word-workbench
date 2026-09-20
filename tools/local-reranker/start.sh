#!/bin/zsh
# Start the local reranker in the background and wait until /health is ready.
set -eu
here="${0:A:h}"
cache="$here/.cache"
port="${WWB_RERANKER_PORT:-11436}"
mkdir -p "$cache"

if [[ -f "$cache/llama-server.pid" ]] && kill -0 "$(cat "$cache/llama-server.pid")" 2>/dev/null; then
  print "本地重排服务已在运行（pid $(cat "$cache/llama-server.pid")，端口 $port）。"
  exit 0
fi

"$here/serve.sh" >"$cache/llama-server.log" 2>&1 &
for _ in {1..60}; do
  if curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    print "本地重排服务已就绪：http://127.0.0.1:$port（pid $(cat "$cache/llama-server.pid")）。"
    exit 0
  fi
  sleep 0.5
done

print -u2 "本地重排服务未在 30 秒内就绪；日志：$cache/llama-server.log"
exit 1
