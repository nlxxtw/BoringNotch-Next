#!/usr/bin/env bash
# CI / local test package. Builds without a Developer account, then ad-hoc signs.
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
readonly CONFIGURATION="${CONFIGURATION:-Release}"
readonly DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
readonly SKIP_APP_ICON="${SKIP_APP_ICON:-1}"
readonly BUILD_ARCHS="${BUILD_ARCHS:-arm64}"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

emit_real_errors() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 0
  grep -E 'error:|fatal error:|BUILD FAILED|Undefined symbols|ld: |requires a development team' "$log_file" \
    | grep -Ev 'CODE_SIGN_(IDENTITY|STYLE|ING_)|OTHER_CODE_SIGN' \
    | head -n 50 \
    | while IFS= read -r line; do
        printf '::error::%s\n' "$line"
      done || true
  printf '----- last 100 log lines -----\n' >&2
  tail -n 100 "$log_file" >&2 || true
}

export DEVELOPER_DIR
readonly XCODEBUILD="${DEVELOPER_DIR}/usr/bin/xcodebuild"
[[ -x "$XCODEBUILD" ]] || fail "xcodebuild not found at $XCODEBUILD (set DEVELOPER_DIR)"

mkdir -p "$DIST_DIR"
readonly PACKAGE_LOG="$DIST_DIR/package.log"
: > "$PACKAGE_LOG"
exec > >(tee -a "$PACKAGE_LOG") 2>&1

# Private lyrics endpoint file is gitignored; ensure a stub exists for compile.
readonly LYRICS_CONFIG="$PROJECT_DIR/NotchTriage/LyricsAPIConfig.swift"
readonly LYRICS_EXAMPLE="$PROJECT_DIR/NotchTriage/LyricsAPIConfig.swift.example"
if [[ ! -f "$LYRICS_CONFIG" ]]; then
  if [[ -n "${MUSIC_DL_BASE_URL:-}" ]]; then
    printf 'import Foundation\n\nenum LyricsAPIConfig {\n    static let musicDLBaseURLString: String? = "%s"\n\n    static var musicDLBaseURL: URL? {\n        guard let raw = musicDLBaseURLString?.trimmingCharacters(in: .whitespacesAndNewlines),\n              !raw.isEmpty,\n              let url = URL(string: raw) else { return nil }\n        return url\n    }\n}\n' \
      "${MUSIC_DL_BASE_URL//\\/\\\\}" > "$LYRICS_CONFIG"
  elif [[ -f "$LYRICS_EXAMPLE" ]]; then
    cp "$LYRICS_EXAMPLE" "$LYRICS_CONFIG"
  else
    fail "missing NotchTriage/LyricsAPIConfig.swift (copy from .example or set MUSIC_DL_BASE_URL)"
  fi
fi

readonly TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/notch-triage-ci.XXXXXX")"
ICON_BACKUP=""

restore_icon() {
  if [[ -n "${ICON_BACKUP:-}" && -d "$ICON_BACKUP" ]]; then
    mv "$ICON_BACKUP" "$PROJECT_DIR/NotchTriage/AppIcon.icon" || true
    ICON_BACKUP=""
  fi
}

cleanup() {
  restore_icon
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

readonly DERIVED_DATA_PATH="$TEMP_ROOT/DerivedData"
readonly STAGING_DIR="$TEMP_ROOT/dmg-root"
readonly LOG_PATH="$DIST_DIR/xcodebuild.log"
mkdir -p "$STAGING_DIR"

printf 'Xcode: '; "$XCODEBUILD" -version | tr '\n' ' '; printf '\n'
"$XCODEBUILD" -list -project "$PROJECT_DIR/NotchTriage.xcodeproj" || true

# Icon Composer (.icon) can crash actool on some CI Xcodes. Move it aside and
# keep ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon so Assets.xcassets/AppIcon.appiconset
# still ships a Finder/install icon.
if [[ "$SKIP_APP_ICON" == "1" ]]; then
  printf 'Skipping AppIcon.icon (actool); using AppIcon.appiconset for Finder icon.\n'
  if [[ -d "$PROJECT_DIR/NotchTriage/AppIcon.icon" ]]; then
    ICON_BACKUP="$TEMP_ROOT/AppIcon.icon"
    mv "$PROJECT_DIR/NotchTriage/AppIcon.icon" "$ICON_BACKUP"
  fi
fi

printf 'Building NotchTriage (%s) archs=%s without Developer signing...\n' "$CONFIGURATION" "$BUILD_ARCHS"
set +e
"$XCODEBUILD" \
  -project "$PROJECT_DIR/NotchTriage.xcodeproj" \
  -scheme NotchTriage \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ARCHS="$BUILD_ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY= \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  COMPILER_INDEX_STORE_ENABLE=NO \
  ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS=NO \
  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon \
  COPY_PHASE_STRIP=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  STRIP_STYLE=all \
  DEAD_CODE_STRIPPING=YES \
  DEPLOYMENT_POSTPROCESSING=YES \
  GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  DEBUG_INFORMATION_FORMAT=dwarf \
  build 2>&1 | tee "$LOG_PATH"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$BUILD_STATUS" -ne 0 ]]; then
  printf 'xcodebuild failed with status %s\n' "$BUILD_STATUS" >&2
  emit_real_errors "$LOG_PATH"
  exit "$BUILD_STATUS"
fi

readonly APP_SOURCE="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/NotchTriage.app"
[[ -d "$APP_SOURCE" ]] || fail "build did not produce $APP_SOURCE"
printf 'Build succeeded: %s\n' "$APP_SOURCE"

# Strip Finder/xattr detritus that often breaks ad-hoc codesign on CI.
xattr -cr "$APP_SOURCE" || true
find "$APP_SOURCE" -name '._*' -delete || true
find "$APP_SOURCE" -name '.DS_Store' -delete || true
find "$APP_SOURCE" -name '__MACOSX' -prune -exec rm -rf {} + || true
find "$APP_SOURCE" -name '*.dSYM' -prune -exec rm -rf {} + || true

readonly APP_PLIST="$APP_SOURCE/Contents/Info.plist"
readonly PLISTBUDDY="/usr/libexec/PlistBuddy"
readonly EXECUTABLE_NAME="$("$PLISTBUDDY" -c 'Print :CFBundleExecutable' "$APP_PLIST")"
readonly EXECUTABLE_PATH="$APP_SOURCE/Contents/MacOS/$EXECUTABLE_NAME"

# Extra slim pass on the Mach-O (safe after Release + STRIP_*).
if [[ -f "$EXECUTABLE_PATH" ]]; then
  BEFORE_BYTES="$(stat -f%z "$EXECUTABLE_PATH" 2>/dev/null || wc -c < "$EXECUTABLE_PATH" | tr -d ' ')"
  /usr/bin/strip -rSTx "$EXECUTABLE_PATH" 2>/dev/null \
    || /usr/bin/strip -x "$EXECUTABLE_PATH" 2>/dev/null \
    || true
  AFTER_BYTES="$(stat -f%z "$EXECUTABLE_PATH" 2>/dev/null || wc -c < "$EXECUTABLE_PATH" | tr -d ' ')"
  printf 'Stripped executable: %s → %s bytes\n' "$BEFORE_BYTES" "$AFTER_BYTES"
fi

ENTITLEMENTS="$PROJECT_DIR/NotchTriage/NotchTriage.entitlements"
sign_item() {
  local target="$1"
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$target"
  else
    codesign --force --sign - --timestamp=none "$target"
  fi
}

printf 'Ad-hoc signing embedded frameworks...\n'
find "$APP_SOURCE" -name '*.framework' -print0 | while IFS= read -r -d '' framework; do
  xattr -cr "$framework" || true
  codesign --force --sign - --timestamp=none "$framework" || true
done

find "$APP_SOURCE" -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
  codesign --force --sign - --timestamp=none "$dylib" || true
done

printf 'Ad-hoc signing app bundle...\n'
if ! sign_item "$APP_SOURCE"; then
  printf 'Entitlements sign failed; retrying without entitlements...\n'
  codesign --force --deep --sign - --timestamp=none "$APP_SOURCE" \
    || fail "ad-hoc codesign failed"
fi
codesign --verify --verbose=2 "$APP_SOURCE" || true

bundle_version="$("$PLISTBUDDY" -c 'Print :CFBundleShortVersionString' "$APP_PLIST")"
bundle_build="$("$PLISTBUDDY" -c 'Print :CFBundleVersion' "$APP_PLIST")"
printf 'Built version %s (%s)\n' "$bundle_version" "$bundle_build"

lipo "$EXECUTABLE_PATH" -verify_arch arm64
printf 'Architectures: %s\n' "$(lipo "$EXECUTABLE_PATH" -archs)"
printf 'App bundle size: %s\n' "$(du -sh "$APP_SOURCE" | awk '{print $1}')"

readonly ARTIFACT_STEM="NotchTriage-${bundle_version}-b${bundle_build}-macOS-arm64"
readonly APP_DEST="$DIST_DIR/NotchTriage.app"
readonly ZIP_PATH="$DIST_DIR/${ARTIFACT_STEM}.zip"
readonly DMG_PATH="$DIST_DIR/${ARTIFACT_STEM}.dmg"

rm -rf "$APP_DEST" "$ZIP_PATH" "$DMG_PATH"
ditto --norsrc --noextattr "$APP_SOURCE" "$APP_DEST"
# Highest zip compression for smaller download.
ditto -c -k --sequesterRsrc --keepParent -zlibCompressionLevel 9 "$APP_DEST" "$ZIP_PATH" 2>/dev/null \
  || ditto -c -k --sequesterRsrc --keepParent "$APP_DEST" "$ZIP_PATH"
printf 'Wrote %s (%s)\n' "$ZIP_PATH" "$(du -sh "$ZIP_PATH" | awk '{print $1}')"

set +e
ditto --norsrc --noextattr "$APP_SOURCE" "$STAGING_DIR/NotchTriage.app"
ln -sf /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "NotchTriage ${bundle_version}" \
  -srcfolder "$STAGING_DIR" \
  -format ULMO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"
DMG_STATUS=$?
if [[ "$DMG_STATUS" -ne 0 ]]; then
  # Fallback to classic compressed UDZO if ULMO unavailable.
  hdiutil create \
    -volname "NotchTriage ${bundle_version}" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"
  DMG_STATUS=$?
fi
set -e
if [[ "$DMG_STATUS" -ne 0 ]]; then
  printf 'warning: DMG creation failed (status %s); ZIP is still available\n' "$DMG_STATUS"
fi

{
  printf 'version=%s\n' "$bundle_version"
  printf 'build=%s\n' "$bundle_build"
  printf 'zip=%s\n' "$(basename "$ZIP_PATH")"
  if [[ -f "$DMG_PATH" ]]; then
    printf 'dmg=%s\n' "$(basename "$DMG_PATH")"
    printf 'sha256_dmg=%s\n' "$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  fi
  printf 'sha256_zip=%s\n' "$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
  printf 'app_size=%s\n' "$(du -sh "$APP_SOURCE" | awk '{print $1}')"
  printf 'xcode=%s\n' "$("$XCODEBUILD" -version | tr '\n' ' ')"
  printf 'skip_app_icon=%s\n' "$SKIP_APP_ICON"
} | tee "$DIST_DIR/build-info.txt"

printf 'Artifacts ready in %s\n' "$DIST_DIR"
ls -lh "$ZIP_PATH" || true
[[ -f "$DMG_PATH" ]] && ls -lh "$DMG_PATH" || true
[[ -f "$ZIP_PATH" ]] || fail "ZIP artifact missing"
