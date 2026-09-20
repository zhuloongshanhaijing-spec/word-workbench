#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p '每日录词工作台.app/Contents/MacOS' '每日录词工作台.app/Contents/Resources/Dictionary' ../work/build-cache
task_cache="${PWD:h}/work/build-cache"
swiftc -parse-as-library -O -module-cache-path "$task_cache" WordWorkbenchV3.swift WordWorkbenchCore.swift OpenDictionaryAdapter.swift OpenDictionaryLifecycle.swift OllamaSemanticRecommender.swift LocalSemanticReranker.swift SemanticEngineCoordinator.swift -o '每日录词工作台.app/Contents/MacOS/WordWorkbench' -framework SwiftUI -framework AppKit -framework CoreServices -framework ScreenCaptureKit -lsqlite3
cp Info.plist '每日录词工作台.app/Contents/Info.plist'
cp ../THIRD_PARTY_DATA.md '每日录词工作台.app/Contents/Resources/THIRD_PARTY_DATA.md'

# Release builders place the separately licensed data here. It is deliberately
# ignored by Git: code is MIT, while Open Dictionary data is CC BY-SA 4.0.
bundled_dictionary="${PWD:h}/data/open-dictionary-v2/distribution.sqlite"
if [[ -f "$bundled_dictionary" ]]; then
  cp "$bundled_dictionary" '每日录词工作台.app/Contents/Resources/Dictionary/distribution.sqlite'
else
  rm -f '每日录词工作台.app/Contents/Resources/Dictionary/distribution.sqlite'
  print "Note: no bundled Open Dictionary database found; first-run update download remains available."
fi
codesign --force --sign - '每日录词工作台.app'
