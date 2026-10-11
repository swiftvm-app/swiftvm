#!/bin/zsh
# Tidies the release notes that GitHub writes, from standard input to standard output: without the
# list of new contributors and the link to the full changelog, and without who merged what where.
set -euo pipefail

awk '
  /^## New Contributors[[:space:]]*$/ { in_contributors = 1; next }
  in_contributors {
    if (/^## / || /^\*\*Full Changelog\*\*/) { in_contributors = 0 }
    else { next }
  }
  /^\*\*Full Changelog\*\*/ { next }
  /^[*-] / {
    sub(/[[:space:]]+by[[:space:]]+@[A-Za-z0-9_-]+[[:space:]]+in[[:space:]]+https?:\/\/[^[:space:]]+[[:space:]]*$/, "")
    sub(/[[:space:]]+\(#[0-9]+\)[[:space:]]*$/, "")
  }
  { print }
' | awk '
  NF == 0 { blank++; if (blank > 1) next; print; next }
  { blank = 0; print }
'
