#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/build/Vectracast.app"
SERVICE_DIR="$APP_DIR/Contents/XPCServices/ExtensionHost.xpc"
node "$PROJECT_DIR/scripts/prepare-sparkle.mjs"
SPARKLE_DIR="$PROJECT_DIR/build/dependencies/sparkle-2.10.0"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$SERVICE_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_DIR/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE"
node "$PROJECT_DIR/scripts/prepare-distribution.mjs" "$APP_DIR/Contents/Resources/distribution.json"
node "$PROJECT_DIR/scripts/bundle-store.mjs"
cp "$PROJECT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE"
swift "$PROJECT_DIR/scripts/prepare-icons.swift" "$PROJECT_DIR"
iconutil -c icns "$PROJECT_DIR/build/branding/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/assets/branding/vectracast-logo.png" "$APP_DIR/Contents/Resources/VectracastLogo.png"
cp "$PROJECT_DIR"/build/branding/MenuBarTemplate*.png "$APP_DIR/Contents/Resources/"
swiftc -swift-version 5 -O -g -target arm64-apple-macosx13.3 \
  "$PROJECT_DIR/apps/macos/Shared/RuntimeProtocol.swift" \
  "$PROJECT_DIR/services/extension-host/main.swift" \
  -o "$SERVICE_DIR/Contents/MacOS/ExtensionHost"
swiftc -swift-version 5 -O -g -target arm64-apple-macosx13.3 \
  "$PROJECT_DIR/apps/macos/Shared/RuntimeProtocol.swift" \
  "$PROJECT_DIR"/apps/macos/Sources/*.swift \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  -o "$APP_DIR/Contents/MacOS/Vectracast"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Vectracast</string><key>CFBundleIdentifier</key><string>local.launcher.app</string>
<key>CFBundleName</key><string>Vectracast</string><key>CFBundleDisplayName</key><string>Vectracast</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.6.1</string>
<key>CFBundleVersion</key><string>16</string><key>LSMinimumSystemVersion</key><string>13.3</string>
<key>NSAppleEventsUsageDescription</key><string>在你选择“显示简介”时，请求 Finder 显示所选应用的简介窗口。</string>
<key>LSUIElement</key><true/><key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
APP_VERSION="$(node -p "require('$PROJECT_DIR/package.json').version")"
APP_BUILD="$(node -p "require('$PROJECT_DIR/package.json').buildNumber")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP_DIR/Contents/Info.plist"
SPARKLE_PUBLIC_KEY="$(node -p "require('$PROJECT_DIR/assets/update-signing.json').publicKey")"
SPARKLE_FEED_URL="$(node -p "require('$PROJECT_DIR/assets/update-signing.json').feedURL")"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool false' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool false' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireSignedFeed bool true' "$APP_DIR/Contents/Info.plist"
cat > "$SERVICE_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ExtensionHost</string><key>CFBundleIdentifier</key><string>local.launcher.ExtensionHost</string>
<key>CFBundleName</key><string>ExtensionHost</string><key>CFBundlePackageType</key><string>XPC!</string>
<key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
cat > "$PROJECT_DIR/build/extension-host.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
mkdir -p "$APP_DIR/Contents/Resources/Documentation"
cp -R "$PROJECT_DIR/docs/developer" "$PROJECT_DIR/docs/architecture" "$PROJECT_DIR/docs/platform" "$APP_DIR/Contents/Resources/Documentation/"
for extension in applications calculator text-tools youdao clipboard-history plugin-store file-search; do
  mkdir -p "$APP_DIR/Contents/Resources/extensions/$extension"
  if [ -f "$PROJECT_DIR/extensions/$extension/README.md" ]; then
    cp "$PROJECT_DIR/extensions/$extension/README.md" "$APP_DIR/Contents/Resources/extensions/$extension/README.md"
  fi
done
codesign --force --sign - --entitlements "$PROJECT_DIR/build/extension-host.entitlements" "$SERVICE_DIR"
codesign --force --sign - "$APP_DIR"
printf 'Built %s\n' "$APP_DIR"
