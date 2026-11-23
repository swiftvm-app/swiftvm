#!/bin/zsh
# Runs the unit tests: those of the SwiftVMKit package, then the app's own, then those of the Rust
# workspace in crates/, which is the swiftvm tool. Arguments go to swift test.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --package-path Packages/SwiftVMKit "$@"
swift test "$@"
cargo test --quiet --locked --workspace
