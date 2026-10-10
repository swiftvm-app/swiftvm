#!/bin/zsh
# Builds the app, which has the swiftvm command-line tool inside it, and the tool on its own.
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
echo "CLI: build/Build/Products/$configuration/SwiftVM.app/Contents/Helpers/swiftvm"
echo "     Packages/SwiftVMKit/.build/out/Products/$configuration/swiftvm (the same tool, built on its own)"
