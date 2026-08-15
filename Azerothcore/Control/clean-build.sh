#!/usr/bin/env bash

set -euo pipefail

ACORE_DIR="${1:-}"

if [ -z "$ACORE_DIR" ] || [ "$ACORE_DIR" = "/" ]; then
    echo "Ungültiger AzerothCore-Pfad."
    exit 1
fi

case "$ACORE_DIR" in
    /*) ;;
    *) echo "Der AzerothCore-Pfad muss absolut sein."; exit 1 ;;
esac

BUILD_DIR="$ACORE_DIR/build"

if [ ! -d "$ACORE_DIR" ]; then
    echo "AzerothCore-Verzeichnis nicht gefunden: $ACORE_DIR"
    exit 1
fi

if [ "$BUILD_DIR" != "$ACORE_DIR/build" ] || [ "$(dirname "$BUILD_DIR")" != "$ACORE_DIR" ]; then
    echo "Sicherheitsprüfung für das Build-Verzeichnis fehlgeschlagen."
    exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
    mkdir -p "$BUILD_DIR"
    echo "Build-Verzeichnis wurde angelegt: $BUILD_DIR"
    exit 0
fi

echo "Es wird ausschließlich dieses Verzeichnis bereinigt:"
echo "  $BUILD_DIR"
echo "Quellcode und Control-Skripte außerhalb von build bleiben erhalten."
read -rp "Zum Fortfahren exakt CLEAN eingeben: " confirmation

if [ "$confirmation" != "CLEAN" ]; then
    echo "Abgebrochen."
    exit 0
fi

find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
echo "Build-Verzeichnis erfolgreich bereinigt."
