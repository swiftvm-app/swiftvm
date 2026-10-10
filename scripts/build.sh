#!/bin/zsh
# Builds the app and the swiftvm command-line tool.
#   scripts/build.sh            Debug build
#   scripts/build.sh Release    Release build
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
xcodebuild -project SwiftVM.xcodeproj -scheme SwiftVM -configuration "$configuration" \
    -derivedDataPath build build | grep -E "error:|warning:|\*\* " || true
swift build --package-path Packages/SwiftVMKit --product swiftvm \
    -c "$(echo "$configuration" | tr '[:upper:]' '[:lower:]')" | tail -1

echo "App: build/Build/Products/$configuration/SwiftVM.app"
echo "CLI: Packages/SwiftVMKit/.build/out/Products/$configuration/swiftvm"
