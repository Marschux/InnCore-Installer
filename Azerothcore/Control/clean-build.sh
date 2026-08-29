#!/usr/bin/env bash

set -euo pipefail

ACORE_DIR="${1:-}"

if [ -z "$ACORE_DIR" ] || [ "$ACORE_DIR" = "/" ]; then
    echo "Invalid AzerothCore path."
    exit 1
fi

case "$ACORE_DIR" in
    /*) ;;
    *) echo "The AzerothCore path must be absolute."; exit 1 ;;
esac

BUILD_DIR="$ACORE_DIR/build"

if [ ! -d "$ACORE_DIR" ]; then
    echo "AzerothCore directory not found: $ACORE_DIR"
    exit 1
fi

if [ "$BUILD_DIR" != "$ACORE_DIR/build" ] || [ "$(dirname "$BUILD_DIR")" != "$ACORE_DIR" ]; then
    echo "Safety check for the build directory failed."
    exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
    mkdir -p "$BUILD_DIR"
    echo "Build directory created: $BUILD_DIR"
    exit 0
fi

echo "Only this directory will be cleaned:"
echo "  $BUILD_DIR"
echo "Source code and Control scripts outside of build are kept."
read -rp "Type exactly CLEAN to continue: " confirmation

if [ "$confirmation" != "CLEAN" ]; then
    echo "Aborted."
    exit 0
fi

find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
echo "Build directory cleaned successfully."
