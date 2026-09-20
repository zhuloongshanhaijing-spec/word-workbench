#!/bin/zsh
# Stop the background reranker. It never touches the app's library or Anki data.
set -eu
here="${0:A:h}"
pidfile="$here/.cache/llama-server.pid"
if [[ ! -f "$pidfile" ]]; then
  print "没有记录的本地重排服务。"
  exit 0
fi
pid="$(cat "$pidfile")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  for _ in {1..40}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
fi
rm -f "$pidfile"
print "本地重排服务已停止。"
