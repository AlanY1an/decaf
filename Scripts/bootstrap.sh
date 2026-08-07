#!/bin/bash
# bootstrap.sh — one-shot contributor setup (plan 06 §3).
# Installs XcodeGen if needed and regenerates Caffeinate.xcodeproj from project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "XcodeGen is missing and Homebrew is not installed." >&2
        echo "Install Homebrew (https://brew.sh) then re-run, or install XcodeGen" >&2
        echo "another way — any xcodegen on PATH works." >&2
        exit 1
    fi
    echo "==> Installing XcodeGen via Homebrew"
    brew install xcodegen
fi

echo "==> Generating Caffeinate.xcodeproj"
xcodegen generate

echo "==> Done. Open Caffeinate.xcodeproj, or run: swift test --package-path Core"
