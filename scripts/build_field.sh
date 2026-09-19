#!/bin/bash
set -e
# Bundles the three.js particle field into one classic script.
#
# WKWebView refuses to load ES modules from a file:// page, so the HUD cannot
# use an importmap. esbuild flattens three.js, its addons and the field source
# into a single IIFE with no imports, which a file:// page loads happily.
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT/Sources/AtlasCore/Vendor/three"
SRC="$PROJECT/Sources/AtlasCore/Vendor/reactor_field.js"
OUT="$PROJECT/Sources/AtlasCore/Resources/field.bundle.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/node_modules/three/build" "$WORK/node_modules/three/addons"
cp "$VENDOR"/three.module.js "$VENDOR"/three.core.js "$WORK/node_modules/three/build/"
cp -R "$VENDOR"/addons/* "$WORK/node_modules/three/addons/"
printf '{"name":"three","version":"0.183.0","main":"build/three.module.js","module":"build/three.module.js"}\n' \
  > "$WORK/node_modules/three/package.json"
cp "$SRC" "$WORK/entry.js"

cd "$WORK"
npx --yes esbuild entry.js --bundle --format=iife --minify --outfile="$OUT"
echo "built $(du -h "$OUT" | cut -f1) -> ${OUT#$PROJECT/}"
