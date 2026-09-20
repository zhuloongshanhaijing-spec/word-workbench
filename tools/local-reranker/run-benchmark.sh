#!/bin/zsh
# End-to-end benchmark runner.
#
#  1. builds the benchmark binary from the shipped sources;
#  2. starts the local reranker under /usr/bin/time so peak RSS is measured,
#     unless one is already running;
#  3. runs both engines over the checked-in fixture and writes the JSON;
#  4. records the real peak memory of the reranker and of the Ollama model.
#
# Usage: zsh tools/local-reranker/run-benchmark.sh [output.json]
set -eu
here="${0:A:h}"
workspace="${here:h:h}"
cache="$here/.cache"
port="${WWB_RERANKER_PORT:-11436}"
time_log="$cache/llama-time.log"
bench_bin="/tmp/wwb-semantic-benchmark"
module_cache="$workspace/work/build-cache"
mkdir -p "$workspace/benchmarks/semantic-ranking/results"
output="${1:-$workspace/benchmarks/semantic-ranking/results/BENCHMARK_RESULTS.json}"
cases="${2:-$workspace/benchmarks/semantic-ranking/cases.json}"

mkdir -p "$cache" "$module_cache"

print "编译基准程序……"
swiftc -module-cache-path "$module_cache" -parse-as-library \
  "$workspace/outputs/WordWorkbenchCore.swift" \
  "$workspace/outputs/OllamaSemanticRecommender.swift" \
  "$workspace/outputs/LocalSemanticReranker.swift" \
  "$workspace/outputs/SemanticEngineCoordinator.swift" \
  "$workspace/outputs/tests/SemanticBenchmarkCheck.swift" \
  -o "$bench_bin"

already_running=0
if curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
  print "复用已在运行的本地重排服务（无法测其峰值内存）。"
  already_running=1
else
  print "启动本地重排服务并记录峰值内存……"
  rm -f "$time_log"
  /usr/bin/time -l "$here/serve.sh" >"$cache/llama-server.log" 2>"$time_log" &
  for _ in {1..80}; do
    curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! curl -fsS -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    print -u2 "本地重排服务未就绪；日志：$cache/llama-server.log"
    exit 1
  fi
fi

print "运行基准（labeled + label_sparse）：$cases"
"$bench_bin" --cases "$cases" --output "$output" --mode both

# Peak memory of the Ollama embedding model while it is still resident.
ollama_peak_mb="$(
  /bin/sh -c 'ollama ps 2>/dev/null' | awk '/bge-m3/ {
    value=$3; unit=$4;
    if (unit ~ /GB/) printf "%.0f", value*1024; else if (unit ~ /MB/) printf "%.0f", value;
    exit
  }'
)"
if [[ -n "${ollama_peak_mb:-}" ]]; then
  "$bench_bin" --output "$output" --apply-peak "ollamaEmbedding=$ollama_peak_mb"
fi

if [[ "$already_running" == "0" ]]; then
  "$here/stop.sh" >/dev/null 2>&1 || true
  for _ in {1..40}; do
    grep -q "maximum resident set size" "$time_log" 2>/dev/null && break
    sleep 0.25
  done
  reranker_peak_mb="$(awk '/maximum resident set size/ {printf "%.0f", $1/1048576; exit}' "$time_log" 2>/dev/null || true)"
  if [[ -n "${reranker_peak_mb:-}" ]]; then
    "$bench_bin" --output "$output" --apply-peak "localReranker=$reranker_peak_mb"
  fi
fi

print "完成：$output"
