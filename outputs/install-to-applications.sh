#!/bin/zsh
# Build and install the app as a normal macOS application. Run this script from
# Terminal; macOS may ask for an administrator password to write /Applications.
set -eu
cd "${0:A:h}"
zsh build.sh

app_source="${PWD}/每日录词工作台.app"
app_target="/Applications/每日录词工作台.app"

ditto "$app_source" "$app_target"

# Register now rather than waiting for Spotlight's next indexing pass.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
  "$lsregister" -f "$app_target"
fi

open -a "每日录词工作台"
print "Installed: $app_target"
