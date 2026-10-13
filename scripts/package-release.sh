#!/bin/zsh
set -euo pipefail

if [[ $# -ne 3 ]]; then
  print -u2 "usage: $0 <signed-app> <output-directory> <version>"
  exit 64
fi

app_path="${1:A}"
output_dir="${2:A}"
version="$3"
app_name="${app_path:t}"

if [[ ! -d "$app_path" || "$app_name" != *.app ]]; then
  print -u2 "expected a signed .app bundle: $app_path"
  exit 66
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
actual_version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
if [[ "$actual_version" != "$version" ]]; then
  print -u2 "version mismatch: app is $actual_version, requested $version"
  exit 65
fi

mkdir -p "$output_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/magic-switch-package.XXXXXX")"
mount_dir="$work_dir/mount"
mounted=false

cleanup() {
  if [[ "$mounted" == true ]]; then
    hdiutil detach "$mount_dir" -quiet || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

archive_base="Magic-Switch-$version-universal"
zip_path="$output_dir/$archive_base.zip"
dmg_path="$output_dir/$archive_base.dmg"
rm -f "$zip_path" "$dmg_path" "$output_dir/$archive_base.sha256"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$zip_path"
mkdir -p "$work_dir/unzipped"
ditto -x -k "$zip_path" "$work_dir/unzipped"
codesign --verify --deep --strict --verbose=2 "$work_dir/unzipped/$app_name"

mkdir -p "$work_dir/dmg"
ditto "$app_path" "$work_dir/dmg/$app_name"
ln -s /Applications "$work_dir/dmg/Applications"
hdiutil create -quiet -volname "Magic Switch $version" -srcfolder "$work_dir/dmg" \
  -format UDZO "$dmg_path"
if [[ -n "${DMG_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$dmg_path"
  codesign --verify --strict --verbose=2 "$dmg_path"
fi

mkdir -p "$mount_dir"
hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$mount_dir" -quiet
mounted=true
codesign --verify --deep --strict --verbose=2 "$mount_dir/$app_name"
hdiutil detach "$mount_dir" -quiet
mounted=false

(
  cd "$output_dir"
  shasum -a 256 "$archive_base.zip" "$archive_base.dmg" > "$archive_base.sha256"
)

print "Created and verified:"
print "  $zip_path"
print "  $dmg_path"
print "  $output_dir/$archive_base.sha256"
