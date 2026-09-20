#!/bin/zsh
# Remove the runtime and model weights. Nothing in the app's library, the
# Open Dictionary database, or Anki is touched. Pass --yes to skip the prompt.
set -eu
here="${0:A:h}"
if [[ "${1:-}" != "--yes" ]]; then
  print "将删除 $(du -sh "$here/runtime" "$here/.cache" 2>/dev/null | awk '{print $2" ("$1")"}' | tr '\n' ' ')"
  read -q "reply?确认删除本地重排运行时与模型？[y/N] " || { print "\n已取消。"; exit 0 }
  print ""
fi
"$here/stop.sh" >/dev/null 2>&1 || true
rm -rf "$here/runtime" "$here/.cache"
print "已移除本地重排运行时与模型。应用会自动退回 Ollama 或词典标签规则。"
