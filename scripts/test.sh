#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
swiftc Sources/ProxyBar/{AppOperations,Models,ProcessInspector,Services,TerminalLauncher}.swift \
  tests/RegressionChecks.swift -o build/regression-checks
build/regression-checks
