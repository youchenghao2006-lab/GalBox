#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/GalBox.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$PROJECT_DIR/work/ModuleCache"
/usr/bin/swiftc -O -parse-as-library -module-cache-path "$PROJECT_DIR/work/ModuleCache" -target arm64-apple-macosx13.0 -framework SwiftUI -framework AppKit "$PROJECT_DIR/Source/GalBox.swift" -o "$APP_DIR/Contents/MacOS/GalBox"
/bin/cp "$PROJECT_DIR/Source/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$PROJECT_DIR/Source/AppIcon.icns" ]]; then
  /bin/cp "$PROJECT_DIR/Source/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
print "Built $APP_DIR"
