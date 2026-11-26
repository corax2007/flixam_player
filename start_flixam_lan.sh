#!/usr/bin/env bash
# Startet flixam mit Backend im LAN (damit Fire TV / Auto-Discovery funktioniert).
set -e

echo "Starte flixam - Backend hoert auf 0.0.0.0:8000, Discovery auf UDP 9000 ..."

# Laufende Instanz beenden (sonst ist Port 8000 belegt)
pkill -f '[f]rontend/build/linux/x64/release/bundle/frontend' 2>/dev/null || true
sleep 3

export FLIXAM_BACKEND_HOST=0.0.0.0
exec "$HOME/flixam_player/frontend/build/linux/x64/release/bundle/frontend"
