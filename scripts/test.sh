#!/bin/zsh
# Runs the unit tests of the SwiftVMKit package.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/SwiftVMKit "$@"
