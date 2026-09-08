#!/usr/bin/env bash
# Compile le helper headless en binaire natif unique.
# À exécuter sur la machine réceptrice (Linux) — nécessite le SDK Dart.
set -euo pipefail

cd "$(dirname "$0")"

command -v dart >/dev/null || { echo "❌ Dart SDK introuvable (apt install dart | https://dart.dev/get-dart)"; exit 1; }

dart pub get
dart compile exe bin/rd_helper.dart -o rd_helper

echo
echo "✅ Binaire : $(pwd)/rd_helper"
echo "   Test    : ./rd_helper --help"
