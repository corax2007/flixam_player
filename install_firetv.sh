#!/usr/bin/env bash
# Installiert die passende APK auf dem Fire TV (IP als Argument).
# Fire TV vorher: Einstellungen -> My Fire TV -> Entwickleroptionen ->
#   "ADB-Debugging" UND "Installieren über USB/ADB" aktivieren.
set -e

IP="$1"
if [ -z "$IP" ]; then
  echo "Benutzung: $0 <IP-des-Fire-TV>"
  echo "Beispiel:  $0 192.168.178.35"
  exit 1
fi

APKDIR="$HOME/flixam_player/frontend/build/app/outputs/flutter-apk"
DEVICE="$IP:5555"

echo "Verbinde mit $DEVICE ..."
adb connect "$DEVICE"

ABI=$(adb -s "$DEVICE" shell getprop ro.product.cpu.abi | tr -d '\r\n')
echo "Fire TV Architektur: $ABI"

case "$ABI" in
  arm64-v8a)    APK="$APKDIR/app-arm64-v8a-release.apk" ;;
  armeabi-v7a)  APK="$APKDIR/app-armeabi-v7a-release.apk" ;;
  x86_64)       APK="$APKDIR/app-x86_64-release.apk" ;;
  *) echo "Unbekannte Architektur: $ABI"; exit 1 ;;
esac

echo "Installiere $APK ..."
adb -s "$DEVICE" install -r "$APK"

echo ""
echo "Fertig! App starten mit:"
echo "  adb -s $DEVICE shell monkey -p de.flixam.player 1"
