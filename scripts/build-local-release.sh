#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 ]]; then
  print -u2 "usage: $0 <output-directory> <version>"
  exit 64
fi

: "${XCODE_AGENT_SESSION_ROOT:?run through xcode-agent-session.sh}"
: "${XCODE_DERIVED_DATA_PATH:?run through xcode-agent-session.sh}"
: "${MAGIC_SWITCH_SIGN_IDENTITY:?set the Developer ID Application identity}"

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
output_dir="${1:A}"
version="$2"
archive_path="$XCODE_AGENT_SESSION_ROOT/Magic Switch.xcarchive"
app_path="$archive_path/Products/Applications/Magic Switch.app"
team_id="${MAGIC_SWITCH_TEAM_ID:-H2FNY8B779}"

cd "$repo_root"
xcodebuild clean archive \
  -project "Magic Switch.xcodeproj" \
  -scheme "Magic Switch" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$XCODE_DERIVED_DATA_PATH" \
  -archivePath "$archive_path" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGN_IDENTITY="$MAGIC_SWITCH_SIGN_IDENTITY" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

codesign --verify --deep --strict --verbose=2 "$app_path"
details="$(codesign -dvv "$app_path" 2>&1)"
grep -q '^Identifier=org.fischr.magic-switch$' <<< "$details"
grep -q "^TeamIdentifier=$team_id$" <<< "$details"
grep -q '^Timestamp=' <<< "$details"
[[ "$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)" == "$version" ]]
[[ "$(lipo -archs "$app_path/Contents/MacOS/Magic Switch")" == "x86_64 arm64" ]]

DMG_SIGN_IDENTITY="$MAGIC_SWITCH_SIGN_IDENTITY" \
  "$script_dir/package-release.sh" "$app_path" "$output_dir" "$version"
ditto "$repo_root/docs/INSTALLATION.md" "$output_dir/INSTALLATION.md"
