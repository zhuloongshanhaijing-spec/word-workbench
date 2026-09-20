#!/bin/zsh
# Explicit, checksum-verified download of the bge-reranker-v2-m3 GGUF weights.
#
# Model: BAAI/bge-reranker-v2-m3 (Apache-2.0), GGUF quantization by
# gpustack/bge-reranker-v2-m3-GGUF (Apache-2.0).
# Download: 438,376,864 bytes (~418 MiB). Runtime on disk: the same file.
# The app never downloads this silently; this script is a manual step.
set -eu
here="${0:A:h}"
url="https://huggingface.co/gpustack/bge-reranker-v2-m3-GGUF/resolve/main/bge-reranker-v2-m3-Q4_K_M.gguf"
sha256="e186a244ed455b4ab66ec64339ce7427a6ae13f5c0b5e544de96e50f0f8b3673"
size="438376864"
destination="$here/.cache/bge-reranker-v2-m3-Q4_K_M.gguf"
partial="$destination.part"

mkdir -p "$here/.cache"
if [[ -f "$destination" ]] && [[ "$(stat -f %z "$destination")" == "$size" ]] \
   && [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$sha256" ]]; then
  print "模型已存在且校验通过：$destination"
  exit 0
fi

print "下载 bge-reranker-v2-m3 Q4_K_M（约 418 MiB）……"
# -C - resumes a partial download; the checksum gate below makes retries safe.
curl -fL -C - --retry 3 -o "$partial" "$url"

actual_size="$(stat -f %z "$partial")"
if [[ "$actual_size" != "$size" ]]; then
  print -u2 "大小校验失败：期望 $size 字节，实际 $actual_size。保留 $partial 以便断点续传。"
  exit 1
fi
actual_sha="$(shasum -a 256 "$partial" | awk '{print $1}')"
if [[ "$actual_sha" != "$sha256" ]]; then
  print -u2 "SHA-256 校验失败：期望 $sha256，实际 $actual_sha。未安装。"
  exit 1
fi
mv "$partial" "$destination"
print "已安装：$destination"
