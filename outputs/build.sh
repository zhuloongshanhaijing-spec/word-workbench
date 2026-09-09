#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p '每日录词工作台.app/Contents/MacOS' ../work/build-cache
task_cache="${PWD:h}/work/build-cache"
swiftc -parse-as-library -O -module-cache-path "$task_cache" WordWorkbench.swift -o '每日录词工作台.app/Contents/MacOS/WordWorkbench' -framework SwiftUI -framework AppKit -framework CoreServices
cp Info.plist '每日录词工作台.app/Contents/Info.plist'
codesign --force --sign - '每日录词工作台.app'
