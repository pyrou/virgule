#!/bin/sh
set -eu

export PATH="$HOME/.cargo/bin:$PATH"

case "${CONFIGURATION}" in
    Debug) cargo build --manifest-path "${SRCROOT}/engine/Cargo.toml" ;;
    Release) cargo build --release --manifest-path "${SRCROOT}/engine/Cargo.toml" ;;
    *) echo "Unsupported Xcode configuration: ${CONFIGURATION}" >&2; exit 1 ;;
esac
