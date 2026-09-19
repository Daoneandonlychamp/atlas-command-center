#!/bin/bash
set -e

# Package ATLAS as a native macOS Application Bundle (.app)
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_BUNDLE="$PROJECT_DIR/dist/Atlas.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "=== Building ATLAS Release Executable ==="
cd "$PROJECT_DIR"
swift build -c release --product AtlasApp
swift build -c release --product atlasctl

echo "=== Creating Atlas.app Bundle Structure ==="
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/AtlasApp" "$MACOS_DIR/AtlasApp"
chmod +x "$MACOS_DIR/AtlasApp"

# atlasctl writes to the same encrypted databases as the app. It lives inside
# the bundle so codesign below covers it with the same identity — a helper
# signed separately (or ad-hoc) reads as a different application to the
# Keychain and gets its own access prompt after every build.
if [ -f "$BUILD_DIR/atlasctl" ]; then
    cp "$BUILD_DIR/atlasctl" "$MACOS_DIR/atlasctl"
    chmod +x "$MACOS_DIR/atlasctl"
else
    echo "WARNING: atlasctl missing from $BUILD_DIR"
fi

# SwiftPM emits target resources as separate .bundle directories next to the
# executable. Without these, Bundle.module finds nothing at runtime and any
# resource-backed feature fails silently in the packaged app while still
# working under `swift run`.
echo "=== Copying SwiftPM Resource Bundles & Helper Scripts ==="
shopt -s nullglob
bundles=("$BUILD_DIR"/*.bundle)
if [ ${#bundles[@]} -eq 0 ]; then
    echo "WARNING: no .bundle found in $BUILD_DIR — resources will be missing"
else
    for bundle in "${bundles[@]}"; do
        echo "  + $(basename "$bundle")"
        cp -R "$bundle" "$RESOURCES_DIR/"
    done
fi

# Binary dependencies ship as dynamic frameworks. SwiftPM links them with an
# @rpath install name and leaves them in the build directory, so an .app without
# them refuses to launch — SQLCipher is one, and the encrypted transcript store
# needs it. Copy them in and point the executable at Contents/Frameworks.
echo "=== Copying Frameworks ==="
frameworks=("$BUILD_DIR"/*.framework)
if [ ${#frameworks[@]} -gt 0 ]; then
    mkdir -p "$FRAMEWORKS_DIR"
    for framework in "${frameworks[@]}"; do
        echo "  + $(basename "$framework")"
        cp -R "$framework" "$FRAMEWORKS_DIR/"
    done
    for binary in "$MACOS_DIR"/*; do
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    done
fi

# The Dock reads the icon from the bundle, not from the project. Without this the
# app shows the generic executable placeholder.
if [ -f "$PROJECT_DIR/Design/AppIcon.icns" ]; then
    echo "=== Copying App Icon ==="
    cp "$PROJECT_DIR/Design/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
else
    echo "WARNING: Design/AppIcon.icns missing — the Dock will show a placeholder"
fi

cat <<'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AtlasApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.atlas.app</string>
    <key>CFBundleName</key>
    <string>ATLAS</string>
    <!-- Without a display name the Dock and menu bar fall back to the executable
         name, which is "AtlasApp". -->
    <key>CFBundleDisplayName</key>
    <string>ATLAS</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>ATLAS requires access to your Calendar to display today's events on your command center overview.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>ATLAS requires access to Reminders to display your overdue tasks.</string>
</dict>
</plist>
EOF

# Signing identity. Ad-hoc signing (-s -) derives the identity from the binary
# itself, so every rebuild looks like a brand new app to macOS: Documents access
# is re-requested and the Keychain re-prompts for the login password before ATLAS
# can read its own items. Signing with a real certificate keeps one stable
# identity across builds, so those grants stick.
SIGN_ID="${ATLAS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -o '"[^"]*"' | tr -d '"')}"

if [ -n "$SIGN_ID" ]; then
    echo "=== Signing Atlas.app as $SIGN_ID ==="
    codesign --force --deep -s "$SIGN_ID" "$APP_BUNDLE"
else
    echo "=== No signing identity found — falling back to ad-hoc ==="
    echo "    (macOS will re-ask for Documents and Keychain access after every build)"
    codesign --force --deep -s - "$APP_BUNDLE"
fi

echo "=== Atlas.app Successfully Created & Signed at: ==="
echo "$APP_BUNDLE"
