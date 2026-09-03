#!/bin/sh
set -eu

case "${CONFIGURATION}" in
    Debug) cargo build --manifest-path "${SRCROOT}/engine/Cargo.toml" ;;
    Release) cargo build --release --manifest-path "${SRCROOT}/engine/Cargo.toml" ;;
    *) echo "Unsupported Xcode configuration: ${CONFIGURATION}" >&2; exit 1 ;;
esac
