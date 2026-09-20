#!/bin/zsh
# Explicit, checksum-verified download of the llama.cpp runtime.
#
# Dependency: llama.cpp (MIT). Runtime on disk after extraction: ~27 MB.
# This is a developer tool; the app itself never downloads it automatically.
set -eu
here="${0:A:h}"
version="b10970"
url="https://github.com/ggml-org/llama.cpp/releases/download/${version}/llama-${version}-bin-macos-arm64.tar.gz"
sha256="7fa278a70b90afae3c3e5dd33553d4d11ebfde62725a03ff2fe6f0d3d1e29b59"
archive="$here/.cache/llama-macos-arm64.tar.gz"
destination="$here/runtime/llama-$version"

if [[ -x "$destination/llama-server" ]]; then
  print "运行时已存在：$destination/llama-server"
  exit 0
fi

mkdir -p "$here/.cache" "$here/runtime"
print "下载 llama.cpp $version（约 11 MB）……"
curl -fL -C - --retry 3 -o "$archive" "$url"

actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual" != "$sha256" ]]; then
  print -u2 "SHA-256 校验失败：期望 $sha256，实际 $actual。未安装。"
  exit 1
fi

tar -xzf "$archive" -C "$here/runtime"
if [[ ! -x "$destination/llama-server" ]]; then
  print -u2 "解压后未找到 $destination/llama-server。请检查 release 结构。"
  exit 1
fi
print "已安装：$destination/llama-server"
print "运行时占用：$(du -sh "$destination" | awk '{print $1}')"
