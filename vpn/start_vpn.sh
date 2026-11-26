#!/usr/bin/env bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
if ! command -v wireproxy >/dev/null 2>&1; then
    echo "wireproxy not found" >&2
    exit 1
fi
if [ ! -f "$DIR/wg0.conf" ]; then
    echo "wg0.conf not found" >&2
    exit 1
fi
exec wireproxy -c "$DIR/wg0.conf"
