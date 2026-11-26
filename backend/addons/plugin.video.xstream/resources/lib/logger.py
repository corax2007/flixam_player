# -*- coding: utf-8 -*-
# Python 3
# xStream interner Log
import os
import re
import sys
import xbmc
import xbmcaddon
import xbmcvfs
from urllib.parse import parse_qsl, quote, quote_plus, urlsplit

# API-Schluessel in Adressen kommen nie ins Log (Hilfe-Logs landen oft in fremden Haenden): TMDB
# traegt ihn als api_key in der Adresse, und der requestHandler schreibt jede Adresse mit — ein selbst
# eingetragener TMDB-Schluessel stand so bis zum 31.10.2026 im Klartext im Log; YouTube traegt ihn als
# key, und trailer.py schreibt die Adresse bei einem Fehler gekuerzt mit.
_SECRET_PARAM = re.compile(r'([?&](?:api_key|key)=)[^&\s]+', re.IGNORECASE)

# Maskenliste: was in keiner Zeile dieses Addons im Klartext stehen darf, in welcher Form es auch
# geschrieben wird (JSON, Kopfzeile, Fehlertext einer Bibliothek).
#   1. die Werte dieser Einstellungen (eine neue Schluessel-Einstellung hier eintragen). cConfig meldet
#      den Wert beim Lesen an. Der Logger liest die Einstellungen nicht selbst: ein eigenes Addon-Objekt
#      luede sie je Aufruf ein zweites Mal, und ein gehaltenes naehme dem Dienst seinen frischen Stand
#      (Kodi laedt nach jedem Speichern nur das aelteste lebende Addon-Objekt neu, Kodi 21.3 und 22).
SECRET_SETTINGS = ('2captcha.pass', 'tmdb_user_api_key')
#   2. eingebaute Schluessel — ihr Modul meldet sie ueber logger.secret() an
#   3. Google-Schluessel (YouTube): festes Kennzeichen, deshalb als Muster — auch hinter einem kodierten
#      Zeichen (%3D, %253D), wie er in einer Adresse innerhalb einer Plugin-Adresse steht; dazu das
#      Client-Geheimnis (GOCSPX-…) aus der Schluesseldatei des YouTube-Addons
_GOOGLE_KEY = (r'(?:(?<![\w\-])|(?<=%[0-9A-Fa-f]{2})|(?<=%25[0-9A-Fa-f]{2}))'
               r'(?:AIza[\w\-]{35}|GOCSPX-[\w\-]{20,})(?![\w\-])')
#   4. der Name des Benutzerkontos im Pfad des Heimordners (Linux, macOS, Windows) — auch dort, wo der
#      Pfad kodiert in einer Plugin-Adresse steht (%2Fhome%2Fname, einfach und doppelt kodiert), und im
#      Pfad einer Wechselplatte (/run/media/name/…, /media/name/…), wenn Kodis Daten dort liegen
# Gesucht wird der Wert selbst, nicht ein Name davor: Zeilen mit sId, token oder Cookie eines
# Hosters bleiben lesbar. Ein Wert unter 16 Zeichen ist kein Schluessel (ein Rest im Eingabefeld
# schwaerzte sonst halbe Zeilen). Ein angemeldeter Wert (1. und 2.) steht roh auf der Liste und so,
# wie ihn eine Adresse traegt (_addressForms).
_MIN_LEN = 16
_ESCAPE = re.compile(r'%[0-9A-F]{2}')                   # ein kodiertes Zeichen, wie quote es schreibt
_HOME_HEAD = r'((?:/var)?/home/|/Users/|/run/media/|/media/|[A-Za-z]:[\\/]Users[\\/])([^\\/]+)'
_SLASH = r'(?:/|%2F|%252F)'                             # Schraegstrich: roh, kodiert, doppelt kodiert
_BACKSLASH = r'(?:\\\\|\\|/|%5C|%255C|%2F|%252F)'       # Windows: einfach, doppelt (repr), Schraegstrich, kodiert
_NO_ACCOUNT = ('public', 'shared', 'default', 'all users')

_secrets = set()
_home = []          # leer = noch nicht ermittelt, sonst [Liste der Muster]


def _homePatterns():
    """Je Kontoname ein Muster. Der Name kommt aus Kodis eigenen Pfaden; auf Android, LibreELEC und
    CoreELEC steht keiner darin, dann bleibt die Liste leer."""
    if not _home:
        patterns, seen = [], set()
        paths = [os.path.expanduser('~')]
        for sSpecial in ('special://home/', 'special://xbmc/', 'special://temp/'):
            try:
                paths.append(xbmcvfs.translatePath(sSpecial))
            except Exception:
                pass
        for sPath in paths:
            # ohne Heimordner im Pfad wird kein Muster uebersetzt (das kostet auf schwachen Boxen je Aufruf)
            if not sPath or not (sPath.startswith(('/home/', '/var/home/', '/Users/', '/run/media/', '/media/'))
                                 or sPath[1:2] == ':'):
                continue
            m = re.match(_HOME_HEAD, sPath)
            if not m or m.group(2).lower() in _NO_ACCOUNT or m.group(2).lower() in seen:
                continue
            seen.add(m.group(2).lower())
            # der Name roh und so, wie ihn eine Adresse traegt (Leerzeichen als %20 oder +, Umlaut;
            # einfach und doppelt kodiert)
            aForms = set()
            for sForm in (m.group(2), quote(m.group(2), safe=''), quote_plus(m.group(2), safe='')):
                aForms.update((sForm, quote(sForm, safe='')))
            sName = '(?:' + '|'.join(re.escape(f) for f in sorted(aForms, key=len, reverse=True)) + ')'
            if m.group(1)[1:2] == ':':
                # Windows: jedes Laufwerk, einfacher oder doppelter Backslash (repr eines Pfads),
                # Schraegstrich, kodiert
                patterns.append((('users',), re.compile(
                    r'((?:[A-Za-z](?::|%3A|%253A))' + _BACKSLASH + r'Users' + _BACKSLASH + r')' + sName
                    + r'(?![\w.\-])', re.IGNORECASE)))
            else:
                patterns.append((('home', 'users', 'media'), re.compile(
                    r'(' + _SLASH + r'(?:home|Users|media)' + _SLASH + r')' + sName + r'(?![\w.\-])', re.IGNORECASE)))
        _home.append(patterns)
    return _home[0]


def _addressForms(sValue):
    """Ein angemeldeter Wert roh und so, wie ihn eine Adresse traegt: Sonderzeichen kodiert (Leerzeichen
    als %20 oder +), die Hex-Ziffern gross oder klein, einfach und doppelt kodiert (eine Adresse in einer
    Plugin-Adresse) — dieselben Formen wie beim Kontonamen. Ein Wert ohne Sonderzeichen (Hex, Base64 fuer
    Adressen) bleibt ein Eintrag. Bis zum 12.11.2026 stand nur der rohe Wert auf der Liste: ein Wert mit
    + / = (Base64) oder Leerzeichen blieb kodiert lesbar, wo kein ?key= oder &api_key= davor steht (am
    Anfang von POST-Daten, hinter einem anderen Parameternamen, in einer Adresse innerhalb einer
    Plugin-Adresse)."""
    sQuoted = quote(sValue, safe='')
    if sQuoted == sValue:
        return (sValue,)
    aForms = {sValue}
    for sForm in (sQuoted, quote_plus(sValue, safe='')):
        for sCase in (sForm, _ESCAPE.sub(lambda m: m.group(0).lower(), sForm)):
            aForms.update((sCase, quote(sCase, safe='')))
    return aForms


def _mask(sLog):
    sLog = _SECRET_PARAM.sub(r'\1***', sLog)
    if 'AIza' in sLog or 'GOCSPX-' in sLog:     # das Muster wird erst uebersetzt, wenn eine Zeile es braucht
        sLog = re.sub(_GOOGLE_KEY, '***', sLog)
    for sValue in tuple(_secrets):
        if sValue in sLog:
            sLog = sLog.replace(sValue, '***')
    aPatterns = _homePatterns()
    if aPatterns:
        sLower = sLog.lower()
        for aWords, pattern in aPatterns:
            if any(sWord in sLower for sWord in aWords):    # billige Vorpruefung, nie enger als das Muster
                sLog = pattern.sub(r'\1USER', sLog)
    return sLog


class logger:
    ADDON_NAME = xbmcaddon.Addon().getAddonInfo('name')

    @staticmethod
    def secret(*aValues):
        """Schluessel anmelden: sie stehen danach in keiner Zeile mehr im Klartext, auch nicht kodiert in
        einer Adresse."""
        for sValue in aValues:
            if isinstance(sValue, str) and len(sValue.strip()) >= _MIN_LEN:
                _secrets.update(_addressForms(sValue.strip()))

    @staticmethod
    def mask(sText):
        """Derselbe Schutz fuer einen Text, der nicht ins Log geht (Fehlerfenster)."""
        try:
            return _mask(str(sText))
        except Exception:
            return ''

    # Eine Debug-Stufe gibt es seit dem 11.11.2026 nicht mehr (so entschieden): alles, was das Addon schreibt, steht
    # ohne Debug-Modus im Log, und keine Zeile kann sich hinter der Stufe verstecken.
    @staticmethod
    def info(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGINFO)

    @staticmethod
    def warning(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGWARNING)

    @staticmethod
    def error(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGERROR)

    @staticmethod
    def __writeLog(sLog, cLogLevel=xbmc.LOGINFO):
        try:
            params = dict()
            if len(sys.argv) >= 3 and len(sys.argv[2]) > 0:
                params = dict(parse_qsl(urlsplit(sys.argv[2]).query))
            if 'site' in params:
                sLog = "[%s] -> [%s]: %s" % (logger.ADDON_NAME, params['site'], sLog)
            else:
                sLog = "[%s] %s" % (logger.ADDON_NAME, sLog)
            xbmc.log(_mask(sLog), cLogLevel)
        except Exception as e:
            xbmc.log('Logging Failure: %s' % logger.mask(e), cLogLevel)    # auch der Fehlertext kann den Inhalt tragen
