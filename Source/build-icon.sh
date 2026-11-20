#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/work/ModuleCache"
/usr/bin/swift -module-cache-path "$PROJECT_DIR/work/ModuleCache" "$PROJECT_DIR/Source/Icon.swift" "$PROJECT_DIR"
print "Built $PROJECT_DIR/Source/AppIcon.icns"
