# -*- coding: utf-8 -*-
# Python 3
"""
Vavoo-Backend-Schicht — alles, was das Modul an EIN Backend bindet, steht in
DIESER Datei. Fuer einen Backend-Wechsel wird nur diese Datei angefasst: ACTIVE
auf einen anderen Profilnamen umlegen oder unter PROFILES einen Profilblock
ergaenzen und ACTIVE darauf zeigen lassen.

Ein Profil beschreibt beide Haelften des Backends:
  - den Ping (woher die Signatur kommt) und
  - Katalog und Resolve (Basis, Endpunkte, Signatur-Kopfzeile, User-Agent,
    catalogId, clientVersion), die vavoo.py ueber die Exporte unten liest.

Aufbau
  - SIGNATUR -> Ping an VYPN, ohne Token (kein geliehenes Token, das gesperrt
                werden koennte)
  - KATALOG  -> Vavoos MediaHubMX-Katalog auf vavoo.top, der die Signatur aus
                dem Ping annimmt

Die Signatur wird OHNE Token angefordert: VYPN stellt sie auf Geraetekennung,
Plattform electron und Paket net.vypn.app aus. Die Geraete-Identity (uniqueId +
Hostname) wird einmal erzeugt und gespeichert, jede Installation behaelt so
ueber alle Pings dieselbe Kennung — siehe Abschnitt GERAETE-IDENTITY.

Alle HTTP-Abrufe laufen ueber xStreams cRequestHandler (keine Abhaengigkeit von
'requests').
"""

import os
import json
import time
import uuid
import base64
import random
import string

import xbmcgui
import xbmcvfs

from resources.lib.handler.requestHandler import cRequestHandler
from resources.lib.config import cConfig
from resources.lib.logger import logger


# Home-Fenster (10000) — seine Properties bleiben fuer die Kodi-Sitzung erhalten.
home = xbmcgui.Window(10000)


# =============================================================================
# PROFILE  — das Einzige, was bei einem Backend-Wechsel angefasst wird
# =============================================================================

ACTIVE = "vypn"

PROFILES = {
    "vypn": {
        # --- Ping (ohne Token) ---
        # Endpunkt, User-Agent und Rumpf bilden die VYPN-Desktop-App nach (Electron,
        # Windows); Werte mit eigener Quelle sind an ihrer Zeile vermerkt. Gegen den
        # echten Ping geprueft am 14.10. und 12.11.2026: Signatur als Gast, App
        # electron 3.1.0 mit ok=true.
        "ping_endpoints": [
            "https://www.vypn.net/api/app/ping",
        ],
        # Chrome/124, abgeglichen am 19.09. und 25.09.2026. Gehoert zur
        # nachgebildeten App, keine Browser-Tarnung: faellt nicht unter die Pflege
        # der Browser-Kennung im requestHandler und wird nur geaendert, wenn danach
        # wieder ein laufendes Bild nachgewiesen ist.
        "ping_ua": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/124.0.0.0 Safari/537.36"),
        "ping_body": {
            "reason": "app-focus",
            "locale": "de",
            "theme": "dark",
            "metadata": {
                # uniqueId und os.host kommen je Abruf aus der gespeicherten
                # Geraete-Identity (siehe _get_device_identity); "" sind Platzhalter.
                "device": {"type": "desktop", "uniqueId": ""},
                # "Windows 11 Pro" ist selbst gewaehlt, nicht aus einem Mitschnitt, und
                # bewusst nicht angeglichen.
                "os": {"name": "win32", "version": "Windows 11 Pro",
                       "abis": ["x64"], "host": ""},
                "app": {"platform": "electron"},   # prueft der Server -> app.ok=true (gesehen 14.10. und 12.11.2026)
                # 3.1.0 angeglichen am 31.07.2026
                "version": {"package": "net.vypn.app", "binary": "3.1.0", "js": "3.1.0"},
            },
            "appFocusTime": 0,
            "playerActive": False,
            "playDuration": 0,
            "devMode": False,
            "hasAddon": True,
            "castConnected": False,
            "package": "net.vypn.app",
            "version": "3.1.0",          # wie metadata.version (angeglichen 31.07.2026)
            "process": "app",
            "firstAppStart": 0,
            "lastAppStart": 0,
            "ipLocation": None,
            "adblockEnabled": True,
            "proxy": {"supported": ["ss"], "engine": "Mu", "enabled": False, "autoServer": True},
            "iap": {"supported": False},
        },

        # --- Ziele der gespeicherten Identity (welche Pfade die feste Kennung bekommen) ---
        # vypn ist electron/windows/desktop -> uniqueId und host passen beide dazu.
        # Ein Profil bekommt nur die hier genannten Felder; fehlt ein Ziel, bleibt
        # das Feld, wie es im Rumpf steht (ein Android-Profil behielte so z.B.
        # seinen Android-Host).
        "identity_targets": {
            "uniqueId": ["metadata", "device", "uniqueId"],
            "host":     ["metadata", "os", "host"],
        },

        # --- Katalog / Resolve (auf vavoo.top; nimmt die Signatur aus dem Ping an) ---
        # MediaHubMX-Werte: Endpunkte, Kopfzeile, User-Agent, catalogId und
        # clientVersion. Gemessen 12.11.2026 und, auf vavoo.top, 13.11.2026: 300
        # Eintraege je Katalogseite, der Resolve antwortet als Liste. Der Katalog
        # verlangt die Signatur (ohne die Kopfzeile HTTP 500 "Internal error"; am
        # 14.10.2026 ging er noch ohne durch), der Resolve antwortet auch ohne. An
        # beiden bekommt eine kaputte Signatur HTTP 500 "Malformed MediaHubMX
        # signature" und eine abgelaufene HTTP 403 "MediaHubMX signature timed out".
        # Basis seit dem 13.11.2026 vavoo.top (bis dahin vavoo.to, dieselbe
        # Schnittstelle). Die Senderadressen im Katalog lauten weiter auf
        # https://vavoo.to/vavoo-iptv/play/<id>, der Resolve nimmt sie so an
        # (gemessen 13.11.2026).
        "catalog_base": "https://vavoo.top",
        "catalog_endpoint": "mediahubmx-catalog.json",
        "resolve_endpoint": "mediahubmx-resolve.json",
        "sig_header": "mediahubmx-signature",
        "catalog_ua": "MediaHubMX/2",
        "catalog_id": "vto-iptv",
        "client_version": "3.1.4",
    },
}

_P = PROFILES[ACTIVE]

# Exporte, die vavoo.py liest (damit im Abrufcode nichts hartkodiert steht).
CATALOG_BASE     = _P["catalog_base"]
CATALOG_ENDPOINT = _P["catalog_endpoint"]
RESOLVE_ENDPOINT = _P["resolve_endpoint"]
SIG_HEADER       = _P["sig_header"]
CATALOG_UA       = _P["catalog_ua"]
CATALOG_ID       = _P["catalog_id"]
CLIENT_VERSION   = _P["client_version"]


# =============================================================================
# CACHE- UND WIEDERHOLUNGS-KONSTANTEN
# =============================================================================

AUTH_RETRIES = 3        # Ping-Versuche je Endpunkt-Runde
AUTH_TTL = 600          # Ersatz-Laufzeit im Cache (10 min), wenn eine Signatur kein brauchbares validUntil traegt:
                        # keines, oder eines, das weniger als AUTH_BUFFER voraus liegt
AUTH_BUFFER = 180       # so viele Sekunden vor dem validUntil einer Signatur wird erneuert (3 min; gemessen
                        # 12.11.2026: validUntil liegt rund 19 min voraus)

# Namensraum wie der Rest des Addons (xstream.<Bereich>.<Schluessel>): Fenster
# 10000 teilen sich alle Addons, der Praefix haelt unsere Werte auseinander.
_PROP_SIG = "xstream.vavoo.auth_sig"
_PROP_EXP = "xstream.vavoo.auth_exp"   # absolute Unix-Zeit (s), zu der die gecachte Signatur ablaeuft


# =============================================================================
# SIGNATUR-CACHE  (Window-Properties, bleiben ueber die Plugin-Aufrufe erhalten)
# =============================================================================

def _extract_valid_until(signature):
    """Das validUntil der Signatur als Unix-Zeit in Sekunden, sonst None.

    Die Signatur ist base64(JSON) mit einem Feld "data", das selbst JSON ist und
    validUntil traegt (Unix-Zeit in ms). Ohne dieses Feld kommt None zurueck, der
    Aufrufer nimmt dann AUTH_TTL.
    """
    try:
        env = json.loads(base64.b64decode(signature + "=="))
        inner = json.loads(env.get("data", "{}"))
        valid_until = inner.get("validUntil")
        if isinstance(valid_until, (int, float)) and valid_until > 0:
            return int(valid_until / 1000)   # ms -> s
    except Exception:
        pass
    return None


def _get_cached():
    """Die gecachte Signatur liefern, solange sie gilt; sonst den Cache leeren und None."""
    sig = home.getProperty(_PROP_SIG) or None
    exp = home.getProperty(_PROP_EXP) or None
    if not sig or not exp:
        return None
    try:
        exp = int(exp)
    except (ValueError, TypeError):
        _clear_cached()
        return None
    now = int(time.time())
    if now >= exp:
        logger.info("[vavoo.auth] expired (now=%s >= exp=%s), clearing" % (now, exp))
        _clear_cached()
        return None
    return sig


def _set_cached(signature):
    """Die Signatur ablegen; der Ablauf ergibt sich aus ihrem validUntil (minus Puffer)."""
    now = int(time.time())
    valid_until = _extract_valid_until(signature)
    if valid_until and (valid_until - AUTH_BUFFER) > now:
        expiry = valid_until - AUTH_BUFFER
        logger.info("[vavoo.auth] expiry from validUntil: %ss ahead" % (expiry - now))
    else:
        expiry = now + AUTH_TTL
        logger.info("[vavoo.auth] no usable validUntil, fallback expiry: %ss" % AUTH_TTL)
    home.setProperty(_PROP_SIG, signature)
    home.setProperty(_PROP_EXP, str(expiry))


def _clear_cached():
    """Den Signatur-Cache leeren."""
    home.clearProperty(_PROP_SIG)
    home.clearProperty(_PROP_EXP)


# =============================================================================
# GERAETE-IDENTITY  (fest je Installation)
# =============================================================================
#
# Ein echter Desktop-Client behaelt ueber jeden Ping DIESELBE Geraetekennung; sie
# je Abruf neu zu erzeugen verraet ein Skript. Beim ersten Lauf entsteht deshalb
# eine Identity, die gespeichert wird — jede Installation hat ihre eigene feste
# uniqueId und ihren eigenen Hostnamen (von Geraet zu Geraet verschieden, ueber
# die Zeit gleich).
#
#   uniqueId : vollstaendige uuid4 mit Bindestrichen (Format der Windows-MachineGuid)
#   host     : DESKTOP-XXXXXXX (Vorgabeformat fuer Windows-Computernamen)
#
# Abgelegt als JSON unter <profile>/vavoo/; uebersteht Neustarts und Addon-Updates.

_DEVICE_FILE = "device.json"
_LEGACY_DEVICE_FILE = "vavoo_device.json"   # lag bis 29.07.2026 direkt im Profil-Root
_device_identity = None   # Cache im Speicher fuer diesen Prozess


def _profile_dir():
    """Absoluter Pfad des Addon-Profilordners."""
    return xbmcvfs.translatePath(cConfig().getAddonInfo("profile"))


def _vavoo_dir():
    """Absoluter Pfad zu <profile>/vavoo (wird angelegt, wenn er fehlt).

    Alles, was Vavoo ablegt, liegt in diesem einen Ordner — die Geraete-Identity
    und der Senderlisten-Cache aus vavoo.py.
    """
    path = os.path.join(_profile_dir(), "vavoo")
    if not os.path.isdir(path):
        try:
            os.makedirs(path)
        except OSError:
            pass
    return path


def _migrate_legacy_device_file(new_path):
    """Ein altes vavoo_device.json aus dem Profil-Root nach vavoo/device.json holen.

    Die Identity MUSS ueber Updates hinweg dieselbe bleiben — ohne diesen Umzug
    wuerde jede bestehende Installation beim Update eine neue uniqueId erzeugen
    und sich bei Vavoo als frisches Geraet melden. Laeuft einmalig und still.
    """
    if os.path.exists(new_path):
        return
    old_path = os.path.join(_profile_dir(), _LEGACY_DEVICE_FILE)
    if not os.path.exists(old_path):
        return
    try:
        os.replace(old_path, new_path)
        logger.info("[vavoo.auth] moved device identity to vavoo/%s" % _DEVICE_FILE)
    except OSError as e:
        logger.error("[vavoo.auth] could not move device identity: %s" % e)


def _generate_host():
    """Ein frischer Computername im Windows-Format: DESKTOP- + 7 Grossbuchstaben bzw. Ziffern."""
    chars = string.ascii_uppercase + string.digits
    return "DESKTOP-" + "".join(random.choice(chars) for _ in range(7))


def _get_device_identity():
    """Die gespeicherte Identity {uniqueId, host} liefern; beim ersten Lauf erzeugen und speichern."""
    global _device_identity
    if _device_identity:
        return _device_identity

    file_path = os.path.join(_vavoo_dir(), _DEVICE_FILE)
    _migrate_legacy_device_file(file_path)

    # Eine vorhandene Identity laden.
    try:
        with open(file_path, "r") as fh:
            data = json.load(fh)
        if data.get("uniqueId") and data.get("host"):
            _device_identity = {"uniqueId": data["uniqueId"], "host": data["host"]}
            return _device_identity
    except (IOError, ValueError):
        pass   # fehlt oder ist beschaedigt -> unten neu erzeugen

    # Eine neue, feste Identity erzeugen und speichern.
    _device_identity = {"uniqueId": str(uuid.uuid4()), "host": _generate_host()}
    try:
        with open(file_path, "w") as fh:
            json.dump(_device_identity, fh)
        logger.info("[vavoo.auth] generated new persistent device identity")
    except IOError as e:
        logger.error("[vavoo.auth] could not persist device identity: %s" % e)
    return _device_identity


# =============================================================================
# PING  (Signatur ohne Token anfordern)
# =============================================================================

def _build_ping_body():
    """Frische Kopie des Ping-Rumpfs aus dem aktiven Profil mit den Werten dieses Abrufs.

    Die gespeicherte Geraete-Identity (uniqueId + host) wird nur in die Pfade
    geschrieben, die das aktive Profil unter "identity_targets" nennt. Ein Profil
    bekommt so nur die Felder, die zu seiner Plattform passen: ein Electron-/
    Windows-Profil beide, ein Android-Profil die uniqueId, aber nicht den
    Windows-Hostnamen; ein Profil ohne Ziele bleibt unberuehrt. lastAppStart ist
    der Zeitpunkt des Abrufs, firstAppStart 24 h davor (die Installation liegt
    scheinbar einen Tag zurueck).
    """
    body = json.loads(json.dumps(_P["ping_body"]))   # tiefe Kopie
    now_ms = int(time.time() * 1000)
    identity = _get_device_identity()

    for id_key, path in _P.get("identity_targets", {}).items():
        value = identity.get(id_key)
        if value is None or not path:
            continue
        node = body
        try:
            for key in path[:-1]:
                node = node[key]
            node[path[-1]] = value
        except (KeyError, TypeError):
            logger.error("[vavoo.auth] identity_targets path %s not found for '%s'" % (
                path, id_key))

    body["firstAppStart"] = now_ms - 86400000   # Installation scheinbar vor rund 24 h
    body["lastAppStart"] = now_ms
    return body


def _log_signature_details(signature):
    """Die Angaben in der Signatur dekodieren und ins Log schreiben (fuer die Fehlersuche)."""
    try:
        inner = json.loads(json.loads(base64.b64decode(signature + "==")).get("data", "{}"))
        logger.info("[vavoo.auth] status=%s, verified=%s, validUntil=%s" % (
            inner.get('status'), inner.get('verified'), inner.get('validUntil')))
    except Exception:
        pass


def _fetch():
    """Eine frische Signatur vom Ping-Endpunkt des aktiven Profils holen.

    Probiert jeden Endpunkt der Reihe nach, AUTH_RETRIES Runden, ohne Fenster.
    Gibt (signature, None) zurueck, sonst (None, grund): "server_down" (kein
    Versuch bekam eine JSON-Antwort: nicht erreichbar, HTTP-Fehler oder eine
    Seite ohne JSON) oder "auth_failed" (JSON kam, aber ohne Signatur).

    HTTP ueber cRequestHandler (POST mit JSON-Rumpf; ignoreErrors, damit der
    requestHandler keine eigenen Fenster zeigt).
    """
    got_response = False   # der Server hat mindestens einmal auswertbares JSON geliefert

    for attempt in range(1, AUTH_RETRIES + 1):
        for endpoint in _P["ping_endpoints"]:
            body = _build_ping_body()
            try:
                oRequest = cRequestHandler(endpoint, caching=False, ignoreErrors=True,
                                           method='POST', data=json.dumps(body))
                oRequest.addHeaderEntry('User-Agent', _P["ping_ua"])
                oRequest.addHeaderEntry('Accept', '*/*')
                oRequest.addHeaderEntry('Content-Type', 'application/json; charset=utf-8')
                content = oRequest.request()

                try:
                    result = json.loads(content)
                except Exception:
                    # Bei einem Transportfehler liefert cRequestHandler einen Platzhalter-Text statt der Antwort
                    logger.info("[vavoo.auth] non-JSON response from %s (status=%s)" % (
                        endpoint, oRequest.getStatus()))
                    continue

                got_response = True
                signature = result.get("addonSig") or result.get("sig")
                if signature:
                    logger.info("[vavoo.auth] signature obtained successfully")
                    _log_signature_details(signature)
                    return signature, None

                logger.info("[vavoo.auth] no signature in response from %s (attempt %s/%s)" % (
                    endpoint, attempt, AUTH_RETRIES))

            except Exception as e:
                logger.error("[vavoo.auth] request to %s failed (attempt %s/%s): %s" % (
                    endpoint, attempt, AUTH_RETRIES, e))

    reason = "auth_failed" if got_response else "server_down"
    logger.error("[vavoo.auth] failed after all retries (%s)" % reason)
    return None, reason


# =============================================================================
# OEFFENTLICHE SCHNITTSTELLE  (was vavoo.py aufruft)
# =============================================================================

def get_signature():
    """Eine gueltige Signatur liefern (aus dem Cache oder frisch geholt), sonst None.

    Die Wiederholungen laufen still; erst wenn alle Versuche scheitern, kommt
    ein Fehlerfenster.
    """
    cached = _get_cached()
    if cached:
        return cached

    logger.info("[vavoo.auth] no valid cached auth, requesting fresh signature...")
    try:
        signature, fail_reason = _fetch()
        if signature:
            _set_cached(signature)
            logger.info("[vavoo.auth] auth obtained successfully")
            return signature

        if fail_reason == "server_down":
            logger.error("[vavoo.auth] server unreachable!")
            xbmcgui.Dialog().ok(cConfig().getLocalizedString(30845),
                                cConfig().getLocalizedString(30846))
        else:
            logger.error("[vavoo.auth] authentication rejected!")
            xbmcgui.Dialog().ok(cConfig().getLocalizedString(30847),
                                cConfig().getLocalizedString(30848))
        return None

    except Exception as e:
        logger.error("[vavoo.auth] unexpected error during auth: %s" % e)
        return None


def refresh():
    """Den Signatur-Cache leeren und eine frische Signatur holen.

    Von vavoo.py genutzt, wenn ein Abruf scheitert und eine frische Signatur
    helfen koennte.
    """
    logger.info("[vavoo.auth] refreshing auth...")
    _clear_cached()
    return get_signature()
