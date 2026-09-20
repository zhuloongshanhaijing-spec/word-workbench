#!/bin/zsh
# Offline check suite for WordWorkbench.
#
# Compiles and runs the shipped contract / fallback / recommendation / fixture
# checks. Everything here runs offline: no Ollama, no reranker service, no
# AnkiConnect, no network. Live checks are intentionally separate
# (outputs/tests/OllamaSemanticLiveCheck.swift, tools/local-reranker/run-benchmark.sh).
#
# Usage:
#   zsh tools/run-checks.sh                     # offline suite
#   zsh tools/run-checks.sh --db PATH.sqlite    # + real-dictionary contract check
#                                               #   (PATH = a local distribution.sqlite; CC BY-SA data
#                                               #    stays local and is never committed)
#   zsh tools/run-checks.sh --build             # + full app build via outputs/build.sh
#
# Output: per-check PASS/FAIL lines + summary; exit 0 only if all requested checks pass.

set -u
here="${0:A:h}"
repo="${here:h}"
build="$repo/work/checks"
mkdir -p "$build" "$repo/work/build-cache"
module_cache="$repo/work/build-cache"

core_sources=(
  "$repo/outputs/WordWorkbenchCore.swift"
  "$repo/outputs/OpenDictionaryAdapter.swift"
  "$repo/outputs/OpenDictionaryLifecycle.swift"
  "$repo/outputs/OllamaSemanticRecommender.swift"
  "$repo/outputs/LocalSemanticReranker.swift"
  "$repo/outputs/SemanticEngineCoordinator.swift"
)

pass=0
fail=0
failed_names=""

compile_check() {   # $1=name, rest=swift sources
  local name="$1"; shift
  local bin="$build/$name"
  print -- "-- $name (compile)"
  if ! swiftc -module-cache-path "$module_cache" -parse-as-library "$@" -o "$bin"; then
    return 1
  fi
  return 0
}

run_check() {       # $1=name, rest=run args
  local name="$1"; shift
  local bin="$build/$name"
  print -- "-- $name (run)"
  if (cd "$repo" && "$bin" "$@"); then
    print "PASS $name"; pass=$((pass+1)); return 0
  else
    print "FAIL $name"; fail=$((fail+1)); failed_names="$failed_names $name"; return 1
  fi
}

note_fail() {
  local name="$1"
  print "FAIL $name (compile)"; fail=$((fail+1)); failed_names="$failed_names $name"
}

tests="$repo/outputs/tests"

db_arg=""
do_build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) shift; db_arg="${1:-}"; shift ;;
    --build) do_build=1; shift ;;
    *) print "unknown option: $1" >&2; exit 64 ;;
  esac
done

# 1. Open Dictionary adapter over the synthetic JSON fixture
if compile_check adapter "$tests/OpenDictionaryAdapterCheck.swift" "${core_sources[@]}"; then
  run_check adapter outputs/fixtures/open_dictionary_strain.json
else
  note_fail adapter
fi

# 2. Release-metadata lifecycle check over the synthetic fixture
if compile_check lifecycle "$tests/OpenDictionaryLifecycleCheck.swift" "${core_sources[@]}"; then
  run_check lifecycle outputs/fixtures/open_dictionary_release.json
else
  note_fail lifecycle
fi

# 3. Rule-based recommendation ordering
if compile_check recommendation "$tests/SemanticRecommendationCheck.swift" "${core_sources[@]}"; then
  run_check recommendation
else
  note_fail recommendation
fi

# 4. Fallback chain + legacy library decode + selection preservation
if compile_check fallback "$tests/SemanticFallbackCheck.swift" "${core_sources[@]}"; then
  run_check fallback
else
  note_fail fallback
fi

# 5. Reranker protocol contract (stub transport; fully offline)
if compile_check reranker-contract "$tests/RerankerContractCheck.swift" "${core_sources[@]}"; then
  run_check reranker-contract
else
  note_fail reranker-contract
fi

# Optional: real-dictionary contract check against a local distribution.sqlite
if [[ -n "$db_arg" ]]; then
  if compile_check real-dictionary "$repo/benchmarks/semantic-ranking/RealDictionaryContractCheck.swift" "${core_sources[@]}"; then
    run_check real-dictionary "$db_arg"
  else
    note_fail real-dictionary
  fi
else
  print "SKIP real-dictionary (pass --db /path/to/distribution.sqlite to enable)"
fi

# Optional: full app build
if [[ "$do_build" == "1" ]]; then
  print -- "-- app-build"
  if (cd "$repo/outputs" && zsh build.sh >/dev/null); then
    print "PASS app-build"; pass=$((pass+1))
  else
    print "FAIL app-build"; fail=$((fail+1)); failed_names="$failed_names app-build"
  fi
fi

print ""
print "SUMMARY: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
  print "failed:$failed_names"
  exit 1
fi
exit 0
