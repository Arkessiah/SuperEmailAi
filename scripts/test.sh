#!/bin/sh
# Runs the test suite. The Command Line Tools ship no test framework, so the
# installed Xcode is used for this command only (no xcode-select, no sudo).
# Separate scratch path so switching toolchains doesn't invalidate `swift build`.
set -e
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec swift test --scratch-path .build/xcode-tests "$@"
