#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Diffy"
BUNDLE_ID="com.nickt.diffy"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

clean_code_signing_xattrs() {
  local bundle_path="$1"
  local offenders

  xattr -cr "$bundle_path" 2>/dev/null || true
  xattr -cr -s "$bundle_path" 2>/dev/null || true

  while IFS= read -r -d '' file_path; do
    xattr -c "$file_path" 2>/dev/null || true
    xattr -c -s "$file_path" 2>/dev/null || true
  done < <(find -H "$bundle_path" "$bundle_path/Contents/Frameworks/Sparkle.framework/Versions/Current" -print0 2>/dev/null || true)

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    offenders="$(
      xattr -lr "$bundle_path" 2>/dev/null \
        | grep -E 'com.apple.FinderInfo|com.apple.fileprovider.fpfs#P|com.apple.ResourceFork' \
        | sed 's/: com\.apple\..*//' \
        | sort -u \
        || true
    )"

    [[ -n "$offenders" ]] || break

    while IFS= read -r file_path; do
      [[ -n "$file_path" ]] || continue
      xattr -d com.apple.FinderInfo "$file_path" 2>/dev/null || true
      xattr -d 'com.apple.fileprovider.fpfs#P' "$file_path" 2>/dev/null || true
      xattr -d -s com.apple.FinderInfo "$file_path" 2>/dev/null || true
      xattr -d -s 'com.apple.fileprovider.fpfs#P' "$file_path" 2>/dev/null || true
      xattr -c -s "$file_path" 2>/dev/null || true
      xattr -c "$file_path" 2>/dev/null || true
    done <<< "$offenders"
  done
}

cd "$ROOT_DIR"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME" || true
fi

swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/debug/$APP_NAME" "$MACOS_DIR/$APP_NAME"

if [[ -f "$ROOT_DIR/Resources/Diffy.icns" ]]; then
  cp "$ROOT_DIR/Resources/Diffy.icns" "$RESOURCES_DIR/Diffy.icns"
fi
if [[ -d "$ROOT_DIR/Resources/EditorIcons" ]]; then
  cp -R "$ROOT_DIR/Resources/EditorIcons" "$RESOURCES_DIR"
fi
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"
cp "$ROOT_DIR/Resources/THIRD_PARTY_NOTICES.txt" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.txt"
cp "$ROOT_DIR/Resources/SOURCE_CODE.md" "$RESOURCES_DIR/SOURCE_CODE.md"

SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build" -path '*/Sparkle.framework' -type d | head -n 1 || true)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  ditto --norsrc "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>Diffy</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.7.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

clean_code_signing_xattrs "$APP_DIR"
if ! codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>/dev/null; then
  clean_code_signing_xattrs "$APP_DIR"
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

case "${1:-}" in
  --verify)
    /usr/bin/open -n "$APP_DIR"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME is running from $APP_DIR"
    ;;
  *)
    /usr/bin/open -n "$APP_DIR"
    echo "Launched $APP_DIR"
    ;;
esac
