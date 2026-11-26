# flixam_player

Linux-Desktop-App und backend-freie Android-/Fire-TV-App für Film- und Serien-
Entdeckung, Streaming, Filter, Favoriten, persönliche Bewertungen und
Wiedergabe-Fortschritt. Die Oberfläche ist auf Deutsch.

> Hinweis: Die App durchsucht öffentlich erreichbare Video-Quellen. Bitte nur
> für legale Inhalte verwenden. Es gibt keine Erwachsenen-/XXX-Quellen.

## Funktionen

- **Home** mit 9 Kategorien (u. a. „Neu & beliebt", „Kommt bald",
  „Neu hinzugefügt"), automatische Aktualisierung alle 15 Minuten
- **Entdecken** über TMDB: Suche, Genres, FSK, Jahr, Monat, Typ, Sortierung,
  Streaming-Anbieter und Trailer
- **Quellen**: xStream/xShip-Addons, GEZ Kino, TMDB-Trailer, eigene Quellen
- **Serien**: Staffeln/Folgen, „Ab hier wiedergeben", optional **Staffel ohne
  Pause abspielen** (Einstellungen → Zahnrad)
- **Player**: Fortsetzen, Suchleiste, +/-10 s, Lautstärke, Endzeit-Anzeige,
  automatisch ausgeblendete untere Steuerung, dauerhaft sichtbare obere Leiste
- **Persönlich**: Favoriten, 5-Sterne-Bewertung, Notizen/Schnell-Tags
  („Sehr brutal", „Brutal", „Gruselig", …), Fortschritt pro Folge und Film

## Aufbau

```
backend/     FastAPI-Server, Kodi-Addon-Mocks, /resolve, HLS-Flattening, VPN
frontend/    Flutter-App (Linux + Android/Fire TV)
vpn/         wireproxy + example config (wg0.conf bleibt lokal)
```

- **Linux** nutzt den lokalen Python-Backend (REST `localhost:8000`,
  UDP-Discovery `9000`).
- **Android/Fire TV** läuft komplett ohne PC: TMDB und Scraper direkt in Dart
  (`api.useDirect = true`).

## TMDB-API-Key

Der Key ist **nicht** im Quellcode enthalten. Er kann auf drei Arten gesetzt
werden:

1. **Lokale Datei** `~/.flixam_tmdb_key` (eine Zeile mit dem Key) – empfohlen
2. **Build-Flag**:
   ```bash
   flutter build linux --dart-define=FLIXAM_TMDB_KEY=DEIN_KEY
   ```
3. **Backend**: `backend/.env` anhand von `backend/.env.example` anlegen
   (`TMDB_API_KEY=…`).

Ohne Key funktionieren die TMDB-Funktionen nicht.

## Linux starten

```bash
cd backend
python3 -m venv venv
./venv/bin/pip install -r requirements.txt   # falls vorhanden: fastapi uvicorn requests resolveurl …
cd ..
./start_flixam_lan.sh
```

Das Skript startet das Backend auf `0.0.0.0:8000` und die Flutter-App.
Health-Check: `curl http://127.0.0.1:8000/health`

## Android / Fire TV bauen

Das Fire-TV-Gerät benötigt Android 5.1 (API 22) – dafür Flutter 3.29 verwenden:

```bash
cd frontend
/home/joerg/flutter_329/bin/flutter build apk --release --split-per-abi
adb connect 192.168.178.31:5555
adb install -r build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk
```

Alternativ: `./install_firetv.sh` (installiert die passende ABI).

## Eigene Quellen

`~/.flixam_sources.json` enthält benutzerdefinierte Scraper. Änderungen
über die Einstellungen („Eigene Quellen neu laden") übernehmen.

## Lokale Daten

| Datei | Inhalt |
|---|---|
| `~/.flixam_player_prefs.json` | Favoriten, Bewertungen, Notizen, Positionen, Dauer |
| `~/.flixam_player_settings.json` | Player- und App-Einstellungen |
| `~/.flixam_tmdb_key` | TMDB-API-Key |
| `~/.flixam_sources.json` | eigene Quellen |

Diese Dateien liegen außerhalb des Repos und werden nicht versioniert.

## Prüfungen

```bash
/home/joerg/flutter/bin/flutter analyze
/home/joerg/flutter_329/bin/flutter analyze
/home/joerg/flutter/bin/flutter build linux
/home/joerg/flutter_329/bin/flutter build apk --release --split-per-abi
```
