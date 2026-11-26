# -*- coding: utf-8 -*-
# Python 3
"""
vavoo.py - Vavoo Live-TV fuer xStream.

Aufbau:
  - HTTP ueber xStreams cRequestHandler (keine Abhaengigkeit von 'requests')
  - Katalog und Stream-Adresse kommen per POST von Vavoos MediaHubMX-
    Schnittstelle, jeder Abruf traegt die Signatur aus auth.py
  - Wiedergabe wie in hoster.py: ListItem(path) + HLS-MIME-Typ + Header-Pipe;
    HLS laeuft ueber InputStream Adaptive, wenn dieses Addon aktiv ist
    (player.applyIsa), sonst ueber Kodis nativen Player (kein ffmpegdirect)
  - Das Backend steht in auth.py (Backend-Wechsel nur dort)
  - Kein Favoriten-System (bewusst weggelassen)

Menueablauf:
  vavootv (Hauptmenuepunkt)  ->  show_channels (die Sender von GROUP)  ->  play

Cache:
  - Senderliste von GROUP: 20 min gueltig
"""

import os
import re
import sys
import shutil
import json
import time

import xbmc
import xbmcgui
import xbmcplugin
import xbmcvfs

from urllib.parse import urlencode, quote_plus

from resources.lib.handler.requestHandler import cRequestHandler, ERR_TIMEOUT, ERR_URL, REQUEST_ERRORS
from resources.lib.config import cConfig
from resources.lib.logger import logger
from resources.lib.player import cPlayer, applyIsa
from resources.lib.vavoo import auth


# =============================================================================
# KONSTANTEN
# =============================================================================

SITE_NAME = 'vavootv'

API_BASE_URL = auth.CATALOG_BASE

# Die eine Sendergruppe, die das Addon zeigt (seit dem 04.10.2026 nur deutsches
# Fernsehen, die Laenderliste davor ist raus). Begruendete Ausnahme von der Regel
# "nichts hartkodieren": der Wert ist die exakte Schreibweise des Gruppenfilters
# im Katalog des Anbieters, und der Filter achtet auf Gross-/Kleinschreibung ("germany",
# "GERMANY" und "Deutschland" liefern 0 Sender, gemessen 04.10.2026). Benennt
# der Anbieter die Gruppe um, kommt beim Klick genau ein Fenster "Keine Sender
# gefunden", bis dieser Wert nachgezogen ist.
GROUP = "Germany"

# Logo von Vavoo TV (dasselbe Bild wie im Hauptmenue) fuer jeden Eintrag der Senderliste, auch fuer den
# Aktualisieren-Eintrag: die Liste zeigt ihr Logo wie die Listen der Seiten, deren Eintraege ohne eigenes
# Bild das Logo der Seite bekommen (gui.createListItem). Bis zum 14.11.2026 trugen die Sender Kodis
# DefaultTVShows.png und der Aktualisieren-Eintrag DefaultFolder.png
LOGO = os.path.join(cConfig().getAddonInfo('path'), 'resources', 'art', 'vavoo.png')

# Praefix der Window-Properties (RAM-Ebene des Caches), Namensraum wie der Rest
# des Addons: xstream.<Bereich>.<Schluessel>. Fenster 10000 teilen sich alle
# Addons; die Datei-Ebene unter <profile>/vavoo/ bleibt davon unberuehrt.
PROP_PREFIX = "xstream.vavoo."

# Status, bei denen ein zweiter Versuch mit frischer Signatur sinnvoll ist: die
# Schnittstelle weist eine abgelaufene Signatur mit 403 ab ("MediaHubMX signature
# timed out") und eine kaputte mit 500 ("Malformed MediaHubMX signature"), der
# Katalog auch eine fehlende ("Internal error", alles gemessen 12.11.2026). Alles
# andere (400 Validation error, 502/503 Ueberlast, Timeout -1) liegt am Server und
# wird von einem neuen Ping nicht besser. Mit HTTP 500 antwortet die Schnittstelle
# auch auf eine unbekannte Senderkennung ("Not found") und auf eine Adresse, die
# sie nicht aufloesen kann ("No resolver found", gemessen 12.11.2026) — der zweite
# Versuch aendert dort nichts, es bleibt bei der Meldung an den Nutzer.
# Als Strings, weil getStatus() einen String liefert (seit dem 02.11.2026 in jedem Zweig).
AUTH_RETRY_STATUS = ('401', '403', '500')

# Kein zweiter Versuch nach einem Lese-Timeout: der erste hat schon den
# Abruf-Timeout des requestHandlers gekostet (Einstellung requestTimeout), ein
# zweiter verdoppelt nur die Wartezeit, bevor der Nutzer die Meldung sieht.
NO_RETRY_STATUS = ('-1',)

# Kurze Pause vor dem Wiederholungsversuch. Gemessen am 31.08.2026 gegen den
# echten Katalog: 5 Fehlschlaege in 25 Abrufen, davon 4 durch einen sofortigen
# zweiten Versuch OHNE neuen Ping gerettet.
RETRY_DELAY_MS = 500

home = xbmcgui.Window(10000)

# Globaler Sender-Cache je Aufruf (Name -> [urls]) zum Nachschlagen beim Abspielen.
_channels_cache = None


# Zwei Fehlerarten, die frueher beide als ConnectionError herauskamen und deshalb
# nicht zu unterscheiden waren. Beide erben von ConnectionError, damit bestehende
# Aufrufer unveraendert weiterlaufen.
#   VavooAuthError    - der Ping ist gescheitert (der erste oder der zum Erneuern).
#                       get_signature() hat dem Nutzer bereits ein Fenster gezeigt
#                       (30845/30846 bzw. 30847/30848), der Aufrufer darf also NICHT
#                       nochmal melden.
#   VavooRequestError - der Ping lief, Katalog oder Resolve haben nicht geliefert.
#                       Hier hat noch niemand etwas gesagt (der requestHandler
#                       laeuft still, ignoreErrors), der Aufrufer MUSS melden.
class VavooAuthError(ConnectionError):
    """Der Ping ist gescheitert — das Fenster dazu wurde schon gezeigt."""


class VavooRequestError(ConnectionError):
    """Katalog- oder Resolve-Abruf gescheitert — dem Nutzer noch nicht gemeldet."""


# =============================================================================
# PLUGIN- UND ADRESS-HELFER
# =============================================================================

def _handle():
    try:
        return int(sys.argv[1])
    except Exception:
        return -1


def _base():
    try:
        return sys.argv[0]
    except Exception:
        return ''


def _url(**params):
    """Plugin-Adresse fuer den Rueckruf an den vavootv-Verteiler bauen."""
    params['site'] = SITE_NAME
    return _base() + '?' + urlencode(params)


def _L(string_id):
    """Lokalisierten String holen (Kurzform fuer cConfig().getLocalizedString)."""
    return cConfig().getLocalizedString(string_id)


def _notify(message, heading=None, error=False):
    if heading is None:
        heading = _L(30842)
    icon = xbmcgui.NOTIFICATION_ERROR if error else xbmcgui.NOTIFICATION_INFO
    xbmcgui.Dialog().notification(heading, message, icon)


def _error_dialog(heading, message):
    xbmcgui.Dialog().ok(heading, message)


# =============================================================================
# DATEI-/RAM-CACHE  (Window-Properties + JSON-Dateien im Addon-Profil)
# =============================================================================

_legacy_cache_checked = False


def _drop_legacy_cache_dir(profile):
    """Den alten vavoo_cache/-Ordner einmalig entfernen.

    Inhalt ist reiner Cache und wird beim naechsten Abruf in vavoo/ neu
    angelegt — es geht nichts verloren. Ein Fehler beim Loeschen wird nur geloggt.
    """
    global _legacy_cache_checked
    if _legacy_cache_checked:
        return
    _legacy_cache_checked = True
    old = os.path.join(profile, 'vavoo_cache')
    if not os.path.isdir(old):
        return
    try:
        shutil.rmtree(old)
        logger.info("[vavoo] removed legacy cache dir vavoo_cache")
    except OSError as e:
        logger.error("[vavoo] could not remove legacy cache dir: %s" % e)


def _cache_dir():
    """<profile>/vavoo — derselbe Ordner, in dem auth.py die device.json ablegt."""
    profile = xbmcvfs.translatePath(cConfig().getAddonInfo('profile'))
    path = os.path.join(profile, 'vavoo')
    if not os.path.exists(path):
        try:
            os.makedirs(path)
        except OSError:
            pass
    _drop_legacy_cache_dir(profile)
    return path


def _safe_key(key):
    """Cache-Schluessel auf unbedenkliche Zeichen reduzieren.

    Der Schluessel traegt den Gruppennamen in der Schreibweise des Anbieters
    (heute die Konstante GROUP) und landet direkt im Dateinamen; ein
    Schraegstrich oder eine Punktfolge darin wuerde die Datei ausserhalb des
    Cache-Ordners ablegen. Auf Windows sind Doppelpunkte und Sternchen als
    Dateiname ohnehin unzulaessig.
    """
    return re.sub(r'[^A-Za-z0-9._-]', '_', str(key))


def _set_cache(key, value, timeout=False):
    """Wert ablegen. timeout=False -> dauerhaft; sonst Sekunden bis zum Ablauf."""
    expiry = False if timeout is False else int(time.time()) + timeout
    payload = json.dumps({"exp": expiry, "value": value})
    home.setProperty(PROP_PREFIX + key, payload)
    filepath = os.path.join(_cache_dir(), _safe_key(key) + ".json")
    tmp = filepath + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(payload)
        os.replace(tmp, filepath)
    except Exception as e:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass
        logger.error("[vavoo] failed to write cache %s: %s" % (key, e))


def _get_cache(key):
    """Gecachten Wert liefern, wenn vorhanden und nicht abgelaufen, sonst None."""
    now = int(time.time())

    cached = home.getProperty(PROP_PREFIX + key)
    if cached:
        try:
            data = json.loads(cached)
            exp = data.get("exp", 0)
            if exp is False or exp > now:
                return data.get("value")
            home.clearProperty(PROP_PREFIX + key)
        except (ValueError, TypeError):
            home.clearProperty(PROP_PREFIX + key)

    filepath = os.path.join(_cache_dir(), _safe_key(key) + ".json")
    try:
        with open(filepath) as f:
            data = json.load(f)
        exp = data.get("exp", 0)
        if exp is False or exp > now:
            value = data.get("value")
            home.setProperty(PROP_PREFIX + key, json.dumps({"exp": exp, "value": value}))
            return value
        os.remove(filepath)
    except (FileNotFoundError, json.JSONDecodeError, IOError, OSError):
        pass
    return None


def _clear_cache(key):
    home.clearProperty(PROP_PREFIX + key)
    try:
        filepath = os.path.join(_cache_dir(), _safe_key(key) + ".json")
        if os.path.exists(filepath):
            os.remove(filepath)
    except OSError:
        pass


# =============================================================================
# HTTP  (alles ueber cRequestHandler)
# =============================================================================

def _catalog_post(url, data_dict, _retry=True):
    """JSON per POST an den Katalog- oder Resolve-Endpunkt schicken, mit der
    Signatur aus auth.py; hoechstens ein Wiederholungsversuch — mit frischer
    Signatur nach 401/403/500, sonst nach kurzer Pause (keiner nach einem
    Lese-Timeout).

    Gibt das ausgewertete JSON zurueck. Wirft VavooAuthError bzw.
    VavooRequestError (beide ConnectionError), wenn nichts mehr zu retten ist.
    """
    signature = auth.get_signature()
    if not signature:
        raise VavooAuthError("Authentication failed")

    oRequest = cRequestHandler(url, caching=False, ignoreErrors=True,
                               method='POST', data=json.dumps(data_dict))
    oRequest.addHeaderEntry('User-Agent', auth.CATALOG_UA)
    oRequest.addHeaderEntry('Accept', 'application/json')
    oRequest.addHeaderEntry('Accept-Language', 'de')
    oRequest.addHeaderEntry('Content-Type', 'application/json; charset=utf-8')
    oRequest.addHeaderEntry(auth.SIG_HEADER, signature)

    content = oRequest.request()
    status = oRequest.getStatus()

    try:
        result = json.loads(content)
    except Exception:
        result = None

    if result is None:
        if _retry:
            if str(status) in AUTH_RETRY_STATUS:
                # Eine frische Signatur hilft nur, wenn der Server die alte
                # beanstandet hat (403 abgelaufen, 500 kaputt oder fehlend — siehe
                # AUTH_RETRY_STATUS). Bis zum 31.08.2026 lief der Ping bei JEDEM
                # Fehler mit und hat im Log jenes Tages jeden Aufruf verdoppelt,
                # ohne dass ein einziger Versuch dadurch durchkam.
                logger.info("[vavoo] catalog/resolve failed (status=%s) — refreshing auth and retrying" % status)
                if auth.refresh():
                    return _catalog_post(url, data_dict, _retry=False)
                # Der Ping zum Erneuern ist gescheitert, get_signature() hat das Fenster dazu
                # schon gezeigt — wie beim ersten Ping meldet der Aufrufer dann nicht nochmal
                # (bis zum 12.11.2026 kam hier ein zweites Fenster hinterher).
                logger.error("[vavoo] catalog/resolve failed (status=%s), no fresh signature" % status)
                raise VavooAuthError("Authentication failed")
            elif str(status) not in NO_RETRY_STATUS:
                # Aussetzer auf Serverseite (400 Validation error, 503 Ueberlast).
                # Da hilft kein neuer Ping, aber sehr wohl ein zweiter Anlauf:
                # gemessen 31.08.2026, 5 Fehlschlaege in 25 Abrufen, 4 davon beim
                # sofortigen zweiten Versuch durchgekommen.
                logger.info("[vavoo] catalog/resolve failed (status=%s) — retrying once without a new ping" % status)
                xbmc.sleep(RETRY_DELAY_MS)
                return _catalog_post(url, data_dict, _retry=False)
        logger.error("[vavoo] catalog/resolve failed (status=%s), giving up" % status)
        raise VavooRequestError("Request failed (status=%s)" % status)

    return result


# =============================================================================
# SENDERNAMEN VEREINHEITLICHEN
# =============================================================================

def _normalize_channel_name(name):
    """Endungen der Stream-Varianten abschneiden, damit Dubletten zusammenfallen.

    Katalog: "RTL .b" / "RTL .c" / "RTL .s" -> "RTL" (12.11.2026, alle Seiten:
    .b 893, .c 430, .s 246)   |   aeltere Form: "RTL (1)" -> "RTL"
    """
    normalized = name.strip()
    normalized = re.sub(r'\s+\.[a-zA-Z]+$', '', normalized)
    normalized = re.sub(r'\s+\(\d+\)$', '', normalized)
    return normalized


# =============================================================================
# SENDER ABRUFEN
# =============================================================================

def _fetch_channels_page(group, cursor=0):
    """Eine einzelne Seite Sender einer Gruppe abrufen (Katalog-API)."""
    # Rumpf im MediaHubMX-Format, gegen die Schnittstelle geprueft am 14.10. und
    # 12.11.2026; region 'AT' und sort 'name' abgeglichen am 19.09.2026.
    # count 9999 kappt der Server auf 300 je Seite, weiter geht es
    # ueber nextCursor (Zahl 300, 600, ...; die letzte Seite kommt mit null —
    # gemessen 12.11.2026: 6 Seiten).
    data = {
        "language": "de",
        "region": "AT",
        "catalogId": auth.CATALOG_ID,
        "id": auth.CATALOG_ID,
        "adult": False,
        "search": "",
        "sort": "name",
        "filter": {"group": group},
        "cursor": cursor,
        "count": 9999,
        "clientVersion": auth.CLIENT_VERSION,
    }
    url = "%s/%s" % (API_BASE_URL, auth.CATALOG_ENDPOINT)
    return _catalog_post(url, data)


def _collect_channels(group, channels):
    """Alle Sender einer Gruppe ueber die Katalog-API sammeln (seitenweise)."""
    cursor = 0
    page_num = 0
    max_pages = 100
    seen_cursors = set()

    while page_num < max_pages:
        page_num += 1
        response = _fetch_channels_page(group, cursor)
        if not isinstance(response, dict):
            # Der Katalog antwortet als Objekt {features, items, nextCursor}; alles
            # andere ist keine Senderliste.
            logger.error("[vavoo] catalog answer is no object (type=%s)" % type(response).__name__)
            raise VavooRequestError("Catalog without object")
        items = response.get("items")
        if not isinstance(items, list):
            items = []
        next_cursor = response.get("nextCursor")
        logger.info("[vavoo] catalog page %d: %d items, nextCursor=%s (group=%s)" % (
            page_num, len(items), next_cursor, group))
        if not items:
            break

        for item in items:
            if not isinstance(item, dict):
                continue
            raw_name = str(item.get("name") or "").strip()
            item_url = item.get("url")
            if not item_url or not raw_name:
                continue
            normalized_name = _normalize_channel_name(raw_name)
            if normalized_name not in channels:
                channels[normalized_name] = []
            if item_url not in channels[normalized_name]:
                channels[normalized_name].append(item_url)

        if next_cursor is None or next_cursor in ("", 0, "null"):
            break
        cursor_key = str(next_cursor)
        if cursor_key in seen_cursors:
            break
        seen_cursors.add(cursor_key)
        cursor = next_cursor

    if page_num >= max_pages:
        logger.info("[vavoo] hit max pages limit for group '%s'" % group)


def getchannels_by_group(group):
    """Sender einer Gruppe. Nutzt den 20-min-Datei-Cache und fuellt den globalen Cache."""
    global _channels_cache

    cache_key = "channels_group_%s" % group
    cached = _get_cache(cache_key)
    if cached:
        logger.info("[vavoo] cached channels for '%s' (%s)" % (group, len(cached)))
        if _channels_cache is None:
            _channels_cache = {}
        _channels_cache.update(cached)
        return cached

    channels = {}
    _collect_channels(group, channels)
    logger.info("[vavoo] group=%s collected=%d distinct channels" % (group, len(channels)))

    # Rueckfall bei leerem Ergebnis: einmal die Signatur erneuern und neu abrufen.
    # Er stammt aus der Zeit, als eine leere Liste eine abgelaufene Signatur
    # bedeuten konnte. Gemessen 12.11.2026: der Katalog weist jede beanstandete
    # Signatur mit einem Fehler ab (das faengt _catalog_post ab), und 200 mit 0
    # Eintraegen kommt nur bei einem Gruppennamen, den er nicht kennt ("germany").
    # Der zweite Abruf bleibt als billige Absicherung, falls sich das wieder aendert.
    if not channels:
        logger.info("[vavoo] 0 channels — refreshing auth and retrying once")
        if not auth.refresh():
            # Der Ping ist gescheitert und hat sein Fenster schon gezeigt — kein zweites
            # ("Keine Sender gefunden") hinterher, wie in _catalog_post.
            raise VavooAuthError("Authentication failed")
        _collect_channels(group, channels)
        logger.info("[vavoo] retry after auth refresh: %s channels" % len(channels))

    # Nur nicht-leere Ergebnisse cachen: eine leere Liste ist ein Fehlschlag
    # (unbekannter Gruppenname, abgewiesener Abruf), keine echte leere Gruppe.
    if channels:
        _set_cache(cache_key, channels, 1200)   # 20 min

    if _channels_cache is None:
        _channels_cache = {}
    _channels_cache.update(channels)
    return channels


def refresh_group_cache(group):
    """Sender-Cache einer Gruppe leeren, damit neu abgerufen wird."""
    global _channels_cache
    _clear_cache("channels_group_%s" % group)
    _channels_cache = None


# =============================================================================
# STREAM AUFLOESEN
# =============================================================================

def _follow_stream_url(url):
    """Einer aufgeloesten Adresse ueber Weiterleitungen bis zur endgueltigen
    Stream-Adresse folgen.

    Einfache Zwischen- und Werbeseiten (HTML) werden uebersprungen: ist die
    Antwort HTML, wird daraus eine .m3u8 gezogen. Nach bestem Bemuehen: sonst
    bleibt es bei der urspruenglichen Adresse. Gibt (None, headers) zurueck,
    wenn die Adresse gar nicht antwortet (Timeout, keine Verbindung) oder mit
    einem Serverfehler (5xx) — siehe den Kommentar an diesem Zweig.
    """
    # Der Abspiel-Kopfsatz traegt die Kennung der App wie die API-Abrufe
    # (Vorabruf hier, Player ueber die Pipe bzw. die ISA-Properties)
    stream_headers = {
        'User-Agent': auth.CATALOG_UA,
        'Accept': '*/*',
    }
    try:
        oRequest = cRequestHandler(url, caching=False, ignoreErrors=True)
        oRequest.addHeaderEntry('User-Agent', auth.CATALOG_UA)
        oRequest.addHeaderEntry('Accept', '*/*')
        started = time.time()
        content = oRequest.request()
        status = str(oRequest.getStatus())
        # Eine Zeile je Vorabruf mit Status und Dauer: das Verhalten der Edge-Server
        # wechselt stuendlich (ARD auf 193.47.62.157 antwortete am 26.10.2026 fast
        # den ganzen Vormittag mit 500, zwischendurch mit 200), und nur das Log
        # zeigt hinterher, ob die Adresse oder der Player gescheitert ist.
        logger.info("[vavoo] stream pre-check: status %s after %.1f s" % (status, time.time() - started))
        if content in (ERR_TIMEOUT, ERR_URL) or (content in REQUEST_ERRORS and status.startswith('5')):
            # Gar keine Antwort (Timeout, keine Verbindung) oder ein Serverfehler:
            # der Player wuerde an derselben Adresse nur scheitern — mit
            # InputStream Adaptive bis zu einer halben Minute bei schwarzem Bild,
            # und ein Stopp in dieser Wartezeit hing bei neueren Kodi-Versionen.
            # Gemessen 20.10.2026: ein Edge-Server hielt den Abruf 30 s fest und
            # antwortete dann mit 502, waehrend andere Sender auf demselben
            # Edge-Server sofort antworteten. Gemessen 26.10.2026: derselbe
            # Edge-Server antwortete fuer einen Sender stundenlang sofort mit 500
            # — der Player zeigte dann nur Kodis eigenes Fenster, und nichts sagte,
            # welchen Stream man nehmen soll. Deshalb zaehlt ein 5xx als keine
            # Antwort, mit unserer Meldung (30855/30856). 4xx bleibt wie bisher
            # beim Player, der scheitert daran schnell. Der requestHandler hat
            # die Adresse schon geloggt.
            logger.error("[vavoo] stream address gave no answer (status %s), not starting the player" % status)
            return None, stream_headers
        final_url = oRequest.getRealUrl() or url

        head = (content or "")[:2000].lower()
        if '<html' in head or '<!doctype html' in head:
            m3u8_matches = re.findall(r'(https?://[^\s"\'<>]+\.m3u8[^\s"\'<>]*)', content)
            if m3u8_matches:
                final_url = m3u8_matches[0]
            else:
                stream_matches = re.findall(
                    r'(https?://[^\s"\'<>]+(?:\.ts|/live/|/stream/|/playlist|/index)[^\s"\'<>]*)', content)
                if stream_matches:
                    final_url = stream_matches[0]

        return final_url, stream_headers
    except Exception as e:
        logger.error("[vavoo] follow stream URL failed, using original: %s" % e)
        return url, stream_headers


def resolve_link(link):
    """Sender-Link zu einem abspielbaren Paar (url, headers) aufloesen; url ist
    None, wenn die Stream-Adresse nicht antwortet (_follow_stream_url)."""
    # Resolve-Rumpf und Stream-Kopfzeilen: Signatur, Referer und Origin auf den
    # Katalog-Host. Gemessen 14.10. und 12.11.2026: die
    # Antwort kommt als Liste [{id, name, url}], die Adresse zeigt direkt auf die
    # .m3u8 eines Edge-Servers; _follow_stream_url ruft sie einmal vorab ab. Die
    # Edge-Server antworten unabhaengig von der Signatur-Kopfzeile (gemessen
    # 12.11.2026: frisch, abgelaufen, kaputt und ohne — jedes Mal Playlist und
    # Segment), der Kopfsatz bleibt trotzdem, wie er war.
    url = "%s/%s" % (API_BASE_URL, auth.RESOLVE_ENDPOINT)
    data = {
        "language": "de",
        "region": "AT",
        "url": link,
        "clientVersion": auth.CLIENT_VERSION,
    }

    result = _catalog_post(url, data)
    entry = result[0] if isinstance(result, list) and result else None
    resolved_url = entry.get("url") if isinstance(entry, dict) else None
    if not isinstance(resolved_url, str) or not resolved_url.strip():
        seen = entry if isinstance(entry, dict) else result
        logger.error("[vavoo] resolve without stream address (keys=%s)" % (
            sorted(seen) if isinstance(seen, dict) else type(seen).__name__))
        raise VavooRequestError("Resolve without url")
    resolve_headers = entry.get("headers")

    signature = auth.get_signature()

    final_url, stream_headers = _follow_stream_url(resolved_url)

    if isinstance(resolve_headers, dict):
        stream_headers.update(resolve_headers)
    if signature:
        stream_headers[auth.SIG_HEADER] = signature
    stream_headers["Referer"] = API_BASE_URL + "/"
    stream_headers["Origin"] = API_BASE_URL

    return final_url, stream_headers


# =============================================================================
# STREAM-AUSWAHL (OBERFLAECHE)
# =============================================================================

def _select_stream(name, urls):
    """Stream waehlen. Gibt (index, title) zurueck; index -1 == abgebrochen."""
    stream_count = len(urls)
    if stream_count <= 1:
        return 0, name
    options = [_L(30866) % i for i in range(1, stream_count + 1)]
    dialog_index = xbmcgui.Dialog().select(name, options)
    if dialog_index < 0:
        return -1, None
    return dialog_index, "%s (%s/%s)" % (name, dialog_index + 1, stream_count)


# =============================================================================
# VERZEICHNISLISTEN
# =============================================================================

def _add_dir(label, isFolder=True, **params):
    """Ordner- bzw. Menueeintrag zum Verzeichnis dieses Aufrufs hinzufuegen."""
    listitem = xbmcgui.ListItem(label)
    listitem.setArt({'icon': LOGO, 'thumb': LOGO, 'poster': LOGO})
    try:
        listitem.getVideoInfoTag().setPlot(' ')
    except Exception:
        pass
    xbmcplugin.addDirectoryItem(_handle(), _url(**params), listitem, isFolder)


def show_channels(params):
    """Oberste Ebene von Vavoo TV: die Sender von GROUP. Oben steht der rote
    Eintrag zum Aktualisieren."""
    group = GROUP
    xbmcplugin.setContent(_handle(), "videos")

    try:
        results = getchannels_by_group(group)
    except VavooAuthError as e:
        # Der Ping ist gescheitert, get_signature() hat das Fenster schon gezeigt.
        # Hier NICHT nochmal melden, sonst kommen zwei Fenster nacheinander.
        logger.error("[vavoo] failed to load channels for %s: %s" % (group, e))
        xbmcplugin.endOfDirectory(_handle(), succeeded=False)
        return
    except Exception as e:
        # Alles andere hat noch niemand gemeldet (der requestHandler laeuft still):
        # ohne das Fenster klickte der Nutzer, und es passierte sichtbar gar nichts
        # (31.08.2026: der Ping lief sauber durch, der Katalog antwortete mit 400).
        logger.error("[vavoo] failed to load channels for %s: %s" % (group, e))
        _error_dialog(_L(30851), _L(30852) % group)
        xbmcplugin.endOfDirectory(_handle(), succeeded=False)
        return

    if not results:
        _error_dialog(_L(30851), _L(30852) % group)
        xbmcplugin.endOfDirectory(_handle(), succeeded=False)
        return

    # Roter Aktualisieren-Eintrag (nur, wenn die Sender geladen wurden).
    _add_dir("[COLOR red]%s[/COLOR]" % _L(30865), isFolder=True,
             function="refresh_channels")

    entries = []
    for name, urls in results.items():
        name = name.strip()
        count = len(urls)
        title = "%s  (%s)" % (name, count) if count > 1 else name
        listitem = xbmcgui.ListItem(title)
        listitem.setArt({'icon': LOGO, 'thumb': LOGO, 'poster': LOGO})
        try:
            vtag = listitem.getVideoInfoTag()
            vtag.setMediaType('video')
            vtag.setTitle(title)
            vtag.setPlot(' ')
        except Exception:
            pass
        listitem.setProperty("IsPlayable", "true")
        callback = _url(function="play", name=quote_plus(name), urls=quote_plus(json.dumps(urls)))
        entries.append((callback, listitem, False))

    xbmcplugin.addDirectoryItems(_handle(), entries, len(entries))
    xbmcplugin.addSortMethod(_handle(), xbmcplugin.SORT_METHOD_VIDEO_TITLE)
    xbmcplugin.endOfDirectory(_handle())


def refresh_channels(params):
    """Senderliste von GROUP mit Fortschrittsanzeige frisch abrufen, dann neu laden."""
    group = GROUP

    progress = xbmcgui.DialogProgress()
    progress.create(_L(30842), _L(30861) % group)
    progress.update(30)

    refresh_group_cache(group)

    progress.update(70, _L(30862))
    try:
        channels = getchannels_by_group(group)
        success = bool(channels)
    except Exception:
        success = False

    progress.update(100)
    progress.close()

    xbmcplugin.endOfDirectory(_handle(), succeeded=False)
    xbmc.executebuiltin("Action(ParentDir)")
    xbmc.sleep(300)

    if success:
        _notify(_L(30858) % group)
        xbmc.executebuiltin("Container.Refresh")
    else:
        _notify(_L(30859), error=True)


# =============================================================================
# WIEDERGABE  (Kodi-Player; HLS ueber InputStream Adaptive, wenn dieses Addon
#              aktiv ist — player.applyIsa —, sonst nativ, kein ffmpegdirect)
# =============================================================================

def _build_play_path(url, headers):
    """Kopfzeilen in Kodis Pipe-Schreibweise an die Stream-Adresse haengen."""
    if not headers:
        return url
    return url + '|' + urlencode(headers)


def play(params):
    """Sender aufloesen und abspielen (InputStream Adaptive, wenn aktiv, sonst nativ)."""
    name = params.getValue('name')
    if name:
        from urllib.parse import unquote_plus
        name = unquote_plus(name)
    urls = None
    urls_param = params.getValue('urls')
    if urls_param:
        try:
            from urllib.parse import unquote_plus
            urls = json.loads(unquote_plus(urls_param))
        except (json.JSONDecodeError, TypeError, ValueError):
            urls = None

    if urls is None:
        if _channels_cache is not None and name in _channels_cache:
            urls = _channels_cache[name]
        if not urls:
            _error_dialog(_L(30853), _L(30854) % name)
            return

    stream_index, _title = _select_stream(name, urls)
    if stream_index == -1:
        return

    total = len(urls)

    progress = xbmcgui.DialogProgress()
    progress.create(_L(30842), _L(30863) % name)
    progress.update(50)

    try:
        resolved_url, resolved_headers = resolve_link(urls[stream_index])
    except Exception as e:
        progress.close()
        logger.error("[vavoo] failed to resolve stream %s: %s" % (stream_index + 1, e))
        # Nach einem gescheiterten Ping hat get_signature() schon ein Fenster
        # gezeigt (VavooAuthError) — dann hier kein zweites.
        if "Authentication failed" not in str(e):
            _error_dialog(_L(30855), _L(30856))
        return

    progress.close()

    # None: die Stream-Adresse hat nicht geantwortet (_follow_stream_url) — kein
    # Playerstart, die Meldung sagt, einen anderen Stream zu nehmen oder die
    # Liste zu aktualisieren.
    if not resolved_url:
        _error_dialog(_L(30855), _L(30856))
        return

    play_path = _build_play_path(resolved_url, resolved_headers)
    display_title = "%s (%s/%s)" % (name, stream_index + 1, total) if total > 1 else name

    listitem = xbmcgui.ListItem(display_title, path=play_path)
    # Nativer Kodi-Player: Kodi das Format nennen, damit es HLS direkt demuxt.
    if '.m3u8' in resolved_url:
        listitem.setMimeType('application/vnd.apple.mpegurl')
        listitem.setContentLookup(False)
    # HLS ueber InputStream Adaptive, wenn es aktiv ist; die Kopfzeilen wandern
    # dann aus der Pipe in die ListItem-Properties.
    _path, use_isa = applyIsa(listitem, play_path)
    try:
        vtag = listitem.getVideoInfoTag()
        vtag.setMediaType('video')
        vtag.setTitle(display_title)
        vtag.setPlot('[B]%s[/B] - %s' % (name, _L(30867) % (stream_index + 1, total)))
    except Exception:
        pass
    listitem.setProperty("IsPlayable", "true")

    xbmcplugin.setResolvedUrl(_handle(), True, listitem)
    if use_isa:
        # Neueres ISA zeigt ein eigenes, blockierendes Fehlerfenster, solange der
        # Player noch oeffnet (toter Sender); startPlayer schliesst es. Nur bis
        # zum ersten Bild warten: ein Warten bis zum Ende der Wiedergabe hielte
        # beim Umschalten jedes Skript am Leben (gemessen 15.10.2026). Die native
        # Wiedergabe bleibt wie bisher, ohne Warten.
        cPlayer().startPlayer(isa=True, untilAv=True)


# =============================================================================
# AUFRUFE VERTEILEN
# =============================================================================

def dispatch(function, params):
    """Einen vavootv-Rueckruf an die passende Funktion weiterleiten.

    Alles ohne eigenen Zweig landet in der Senderliste: der Hauptmenuepunkt
    ('load'), alte Favoriten auf 'channelsbycategory' und die frueheren
    Laender-Funktionen.
    """
    if function == 'refresh_channels':
        refresh_channels(params)
    elif function == 'play':
        play(params)
    else:
        show_channels(params)
