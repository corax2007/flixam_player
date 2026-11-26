# -*- coding: utf-8 -*-
# Python 3

import re
import time
import xbmcgui
import os
import hashlib
import json
import traceback
import ssl
import certifi
import socket
import ipaddress
import zlib
import threading
import http.client

from resources.lib.config import cConfig
from resources.lib.handler import browserProfiles
from resources.lib.logger import logger
from resources.lib.cache import cCache
from resources.lib.tools import infoDialog
from xbmcvfs import translatePath

from urllib.parse import quote, urlencode, urlparse, quote_plus, urljoin
from urllib.error import HTTPError, URLError
from urllib.request import HTTPHandler, HTTPSHandler, Request, HTTPCookieProcessor, build_opener, urlopen, HTTPRedirectHandler
from http.cookiejar import LWPCookieJar
from http.client import HTTPException
from contextlib import contextmanager
from functools import partial

# Rueckgabewerte von request() im Fehlerfall. request() wirft NICHT, sondern
# liefert einen dieser Klartexte zurueck. Bei einer HTML-Seite faellt das nicht
# weiter auf: ein Regex findet darin nichts, die Site zeigt eine leere Liste.
# Wer die Antwort dagegen als JSON auswertet, MUSS den Fehlerfall hier erkennen
# koennen — deshalb stehen die Texte an einer Stelle und werden unten in den
# Fehlerzweigen von hier genommen, statt sie doppelt zu pflegen.
ERR_UNREACHABLE = 'SEITE NICHT ERREICHBAR'
ERR_CLOUDFLARE = 'CLOUDFLARE-SCHUTZ AKTIV'
ERR_DDOS = 'DDOS GUARD SCHUTZ'
ERR_TIMEOUT = 'TIMEOUT'
ERR_URL = 'URL FEHLER'
REQUEST_ERRORS = (ERR_UNREACHABLE, ERR_CLOUDFLARE, ERR_DDOS, ERR_TIMEOUT, ERR_URL)

# Merkmale der DDoS-Guard-Pruefseite (Titel, eigene Skripte, Pruefdienst; aus einer
# echten Pruefseite, 09.10.2026) — einer genuegt. Der Header `server: ddos-guard`
# steht dagegen auf JEDER Antwort einer Seite dahinter, auch auf einer normalen 404
# oder 502 des Ursprungs (gemessen 09.10.2026 an serienstream, filmo, aniworld), und
# taugt deshalb nicht als Merkmal.
DDOS_GUARD_MARKERS = ('check.ddos-guard.net', '/.well-known/ddos-guard/', '<title>ddos-guard</title>')

# DNS-Bypass: die per DoH aufgeloeste IP wird THREAD-LOKAL an den Hostnamen gebunden
# und beim Verbindungsaufbau von den eigenen Handlern unten benutzt. Frueher lief das
# ueber einen prozessweiten Tausch von socket.getaddrinfo — der leckte zwischen Threads
# (parallele Abrufe: checkDomain im Service, Prefetch der Sites, globale Suche): sobald
# ein Thread fertig war, verlor der naechste seine Zuordnung, und ein alter Patch blieb
# liegen (28.09.2026 am Code provoziert). Thread-lokal sieht jeder Thread nur seine
# eigene Zuordnung, nach dem Abruf ist sie weg. Die IP kommt je Abruf frisch aus
# __doh_request (bewusst kein Cache, siehe dort).
_dohPins = threading.local()

# Hat der Handler in DIESEM Thread einen Abruffehler gemeldet (Einblendung oder Fenster)? cGui.showInfo laesst
# dann die allgemeine Leer-Meldung weg, cGui.showError die allgemeine Hoster-Meldung — sonst kamen zwei Hinweise
# fuer einen Klick, etwa bei der kinoger-Suche hinter Cloudflare „CloudFlare-Schutz aktiv" und direkt danach
# „Kein Eintrag gefunden" (26.10.2026). Thread-lokal wie _dohPins: die globale Suche ruft die Sites in eigenen Threads ab, und ihre
# Sammelmeldung im Haupt-Thread bleibt davon unberuehrt. Jeder Kodi-Aufruf ist ein frischer Interpreter
# (kein reuselanguageinvoker), der Merker beginnt also mit jedem Klick leer. Auch captcha_helper._solved
# setzt ihn, wenn es ein gescheitertes Captcha gemeldet hat.
_errorShown = threading.local()


def errorShown():
    return getattr(_errorShown, 'flag', False)


def _markErrorShown():
    _errorShown.flag = True


# Laeuft gerade der Hosterlink-Schritt (hoster.py um den Aufruf der Hosterlink-Funktion der Site)? Dann bleiben die
# Fehlerfenster des Handlers (Adresse + Fehlertext bei 4xx/5xx, URLError, HTTPException, OSError, CUII) aus und es
# gibt nur die Logzeile: ein toter Hosterlink ist fuer den Nutzer „Stream nicht verfuegbar", das meldet hoster.py mit
# EINER Einblendung — das Fenster blockierte dort je totem Hoster einmal, im Auto-Modus bei zwei toten Hostern zweimal
# (filmo 26.10.2026: /n/<token> 404 je VOE-Link). Die Einblendungen (Cloudflare, DDoS-Guard, Timeout) bleiben, sie
# blockieren nicht und sagen, woran es lag; bei ihnen entfaellt dafuer die Meldung von hoster.py (cGui.showError).
# Seitenabrufe (Listen, Hosterliste) sind nicht betroffen, dort bleibt das Fenster mit der vollen Adresse (so entschieden
# am 25.08.2026). Prozessweit statt thread-lokal: der Hosterlink-Schritt ist der einzige Weg dieses Aufrufs, und ein
# Thread, den eine Site dabei startet, soll genauso still bleiben.
_quietWindows = {'flag': False}


@contextmanager
def quietWindows():
    before = _quietWindows['flag']
    _quietWindows['flag'] = True
    try:
        yield
    finally:
        _quietWindows['flag'] = before


def _windowsQuiet():
    return _quietWindows['flag']


# RedirectFilter hat eine CUII-Weiterleitung verweigert und gemeldet — request() bekommt dieselbe Antwort gleich
# darauf als HTTPError 3xx und laesst dann das eigene Fenster weg. Thread-lokal wie _errorShown.
_cuiiRefused = threading.local()


def _dohPin(host):
    # Liefert die gepinnte IP fuer 'host' (ohne Port, klein) oder None. Laeuft gerade ein Abruf mit DNS-Umgehung
    # (Resolver im Thread gesetzt, _doh_resolution), wird ein noch unbekannter Host hier per DoH aufgeloest und fuer
    # den Rest des Abrufs gemerkt — so gilt die Umgehung fuer JEDEN Hop, auch nach einer Weiterleitung auf einen
    # anderen Host. Bis zum 02.11.2026 galt sie nur fuer den ersten: der zweite Name lief ueber das System-DNS
    # (lokal nachgestellt). Ein Fehlschlag wird als '' gemerkt, damit derselbe Abruf nicht erneut fragt.
    host = (host or '').split(':')[0].lower()
    ip_map = getattr(_dohPins, 'ip_map', None)
    if ip_map is None:
        ip_map = _dohPins.ip_map = {}
    resolver = getattr(_dohPins, 'resolver', None)
    if host and host not in ip_map and resolver is not None:
        ip_map[host] = resolver(host) or ''
    return ip_map.get(host) or None


@contextmanager
def _doh_resolution(hostname, ip, resolver=None):
    """Bindet 'hostname' fuer die Dauer des Blocks im AKTUELLEN Thread an 'ip'; mit resolver loest der Block
    jeden Host, mit dem er sich verbindet, bei der ersten Verbindung selbst per DoH auf (_dohPin). Ohne ip und
    resolver passiert nichts. Das TLS-Zertifikat bleibt gueltig, weil die Verbindung weiterhin den echten
    Hostnamen kennt (SNI + Cert-Hostname stimmen) — nur die TCP-Verbindung geht zur IP statt zur DNS-Antwort
    des Systems. Nach dem Block gilt wieder genau der Stand davor."""
    if not ip and resolver is None:
        yield
        return
    ip_map = getattr(_dohPins, 'ip_map', None)
    if ip_map is None:
        ip_map = _dohPins.ip_map = {}
    before = dict(ip_map)
    before_resolver = getattr(_dohPins, 'resolver', None)
    if ip:
        ip_map[(hostname or '').lower()] = ip
    if resolver is not None:
        _dohPins.resolver = resolver
    try:
        yield
    finally:
        ip_map.clear()
        ip_map.update(before)
        _dohPins.resolver = before_resolver


def _entpacke(data, sEncoding, sUrl='', bStreng=False):
    """Rumpf nach Content-Encoding entpacken wie ein Browser. deflate kommt in zlib-Form (RFC 9110, so senden es
    nginx und Apache) oder roh, probiert wird beides; was gar nicht passt (als gzip ausgewiesener Klartext), bleibt
    roh. Ein ABGESCHNITTENER Strom (Verbindung mittendrin weg, Laenge unbekannt oder Strom in sich unvollstaendig —
    zlib meldet es ueber eof) wirft mit bStreng IncompleteRead wie _rumpf bei kurzer Content-Length: der Aufrufer
    meldet den abgebrochenen Abruf, und die halbe Seite landet nicht als vollstaendige Antwort im Cache (bis zum
    02.11.2026 stand sie dort bis cacheTime). Ohne bStreng (Fehlerseite, Trailer) liefert er, was
    ankam, und wirft nie. Bis zum 02.11.2026 nahm der Erfolgszweig nur rohes deflate und heiles gzip an — alles
    andere warf zlib.error als Skriptfehler (lokal nachgestellt)."""
    if sEncoding in ('gzip', 'x-gzip'):   # x-gzip = gzip (RFC 9110)
        aWbits = (zlib.MAX_WBITS | 16,)
    elif sEncoding == 'deflate':
        aWbits = (zlib.MAX_WBITS, -zlib.MAX_WBITS)
    else:
        return data
    if not data:
        return data   # leerer Rumpf mit Content-Encoding (Content-Length 0): leer, kein abgeschnittener Strom
    for wbits in aWbits:
        try:
            oZ = zlib.decompressobj(wbits)
            out = oZ.decompress(data)
            while oZ.eof and oZ.unused_data.startswith(b'\x1f\x8b'):   # weiteres gzip-Glied (RFC 9110 erlaubt mehrere)
                oZ, rest = zlib.decompressobj(wbits), oZ.unused_data
                out += oZ.decompress(rest)
        except zlib.error:
            continue
        if bStreng and not oZ.eof:
            raise http.client.IncompleteRead(out, None)
        return out
    logger.error(' -> [requestHandler]: Antwort nicht entpackbar (%s), nehme sie roh: %s' % (sEncoding, sUrl))
    return data


# Gesamtfrist fuer das Lesen eines Rumpfs: der Lese-Timeout (requestTimeout) gilt je Stueck, ein tropfender Server (ein
# paar Bytes je Sekunde, nie eine Pause laenger als der Timeout) hielt den Aufruf bis zum 02.11.2026 beliebig lange (lokal
# nachgestellt). Frist = RUMPF_FAKTOR x requestTimeout, mindestens RUMPF_MINDESTFRIST Sekunden —
# Seiten und JSON-Antworten sind klein, Dateien laedt der requestHandler nicht (updateManager nutzt requests).
RUMPF_MINDESTFRIST = 60
RUMPF_FAKTOR = 6


def _rumpf(fp, iFrist):
    """Rumpf in Stuecken lesen; ist er nach iFrist Sekunden nicht zu Ende, socket.timeout (der Zweig des Lese-Timeouts).
    read1 liefert, was gerade da ist (read(n) wartete im Puffer auf n Bytes); endet der Strom vor der angekuendigten
    Content-Length, IncompleteRead wie bei read() ohne Laenge — der Aufrufer meldet den abgebrochenen Rumpf."""
    t0 = time.time()
    lesen = getattr(fp, 'read1', fp.read)
    aTeile = []
    while True:
        teil = lesen(65536)
        if not teil:
            data = b''.join(aTeile)
            iRest = getattr(fp, 'length', None)
            if iRest:
                raise http.client.IncompleteRead(data, iRest)
            return data
        aTeile.append(teil)
        if time.time() - t0 > iFrist:
            raise socket.timeout('Rumpf nach %d s nicht vollstaendig' % iFrist)


# Zeichensatz-Namen, die ein Browser als windows-1252 liest (WHATWG Encoding Standard, Label-Tabelle): die
# Bytes 0x80-0x9F sind dort Anfuehrungszeichen, Gedankenstrich und Euro — als iso-8859-1 gelesen waeren es
# Steuerzeichen. Python kennt diese Gleichsetzung nicht.
_CP1252_LABELS = ('iso-8859-1', 'iso8859-1', 'iso_8859-1', 'latin1', 'latin-1', 'l1', 'ascii', 'us-ascii', 'cp819',
                  'ibm819', 'csisolatin1', 'iso-ir-100', 'windows-1252', 'cp1252', 'x-cp1252', 'ansi_x3.4-1968')


def _text(data, sCharset):
    """Bytes -> Text im Zeichensatz der Antwort: Content-Type, sonst <meta charset> im Kopf der Seite, sonst UTF-8 — so
    liest es ein Browser, die Latin-1-Familie wie dort als windows-1252. Bis zum 02.11.2026 immer UTF-8: eine
    iso-8859-1-Seite kam mit Ersatzzeichen statt Umlauten (lokal nachgestellt). Ein unbekannter
    Name faellt auf UTF-8 zurueck."""
    if not sCharset:
        m = re.search(rb'<meta[^>]+charset=["\']?\s*([\w-]+)', data[:2048], re.I)
        if m:
            sCharset = m.group(1).decode('ascii', 'ignore')
    if sCharset:
        if sCharset.strip().lower() in _CP1252_LABELS:
            sCharset = 'cp1252'
        try:
            return data.decode(sCharset, 'replace')
        except LookupError:
            pass
    return data.decode('utf-8', 'replace')


# Eine Cookie-Dose je Cookie-Datei fuer die Dauer des Aufrufs (= Prozess): Sitzungs-Cookies ohne Ablauf wandern so von
# Antwort N zu Abruf N+1 desselben Klicks (in die Datei kommen sie nicht, save laesst discard-Cookies weg), und jeder
# Abruf legt neue Cookies in DIESELBE Dose, die danach gespeichert wird. Bis zum 02.11.2026 hielt persistent_openers je
# Domain den Opener des ersten Abrufs samt dessen Dose: Sitzungs-Cookies trug das implizit mit, aber ab dem zweiten
# Abruf einer Domain landeten neue Cookies (auch die eines 302-Hops) nur dort — weder mitgeschickt noch gespeichert
# (lokal nachgestellt). Die Datei wird vor jedem
# Abruf nachgeladen, weil setCookie() und andere Prozesse (Dienst, zweiter Aufruf) sie schreiben.
_cookieJars = {}
_cookieJarsLock = threading.Lock()


def _cookieJar(sPfad, bIgnoreDiscard, bIgnoreExpired):
    with _cookieJarsLock:
        oJar = _cookieJars.get(sPfad)
        if oJar is None:
            oJar = _cookieJars[sPfad] = LWPCookieJar(filename=sPfad)
        # Vor dem ersten Cookie einer Domain ist die Datei leer: __setCookiePath legt sie an, gefuellt wird sie erst
        # beim Speichern nach dem Abruf. load() weist eine leere Datei als fremdes Format ab, deshalb wird sie nicht
        # gelesen. Fehlt die Datei (kein Cookie-Pfad oder inzwischen geloescht), gibt es genauso nichts zu lesen. Bis
        # zum 11.11.2026 schrieb beides je Abruf eine Zeile ins Debug-Log.
        # Gelesen und gespeichert (save, zwei Stellen unten) wird unter derselben Sperre: save() leert die Datei, bevor
        # es sie neu schreibt, und mehrere Abrufe zugleich an denselben Host (TMDB-Vorlauf, zehn Threads) teilen sich
        # die Datei — ein Abruf, der zwischen Groessenabfrage und Lesen lag, las sie leer und schrieb die Fehlerzeile
        # (11.11.2026 nachgestellt: 16 Abrufe zugleich, rund jeder sechste). Ein anderes Skript (Dienst, zweiter
        # Aufruf) kennt die Sperre nicht: scheitert das Lesen, wird es einmal wiederholt, erst der zweite Fehlschlag
        # ist ein Lesefehler.
        for bLetzter in (False, True):
            try:
                if os.path.getsize(sPfad):
                    oJar.load(ignore_discard=bIgnoreDiscard, ignore_expires=bIgnoreExpired)
                break
            except FileNotFoundError:
                break
            except Exception as e:
                if bLetzter:
                    logger.error(' -> [requestHandler]: Failed load cookie: %s' % e)
                else:
                    logger.info(' -> [requestHandler]: Cookie-Datei nicht lesbar, zweiter Versuch: %s' % e)
    return oJar


# ZERTIFIKATSPRUEFUNG. Jeder HTTPS-Abruf prueft das Zertifikat der Gegenseite (seit dem 11.11.2026; bis dahin
# pruefte der Handler bei keinem Abruf — wer die Leitung umleiten kann, las mit und konnte Listen und Links
# austauschen). Name und Aussteller muessen stimmen, sonst kommt die Verbindung nicht zustande. Die Einstellung
# „SSL Zertifikate pruefen" schaltet das fuer alle Abrufe ohne Schluessel ab (cRequestHandler, ssl_verify).
#   - Geprueft wird zuerst gegen certifi: derselbe Speicher auf jeder Plattform, unabhaengig davon, was Kodi dem
#     Python mitgibt.
#   - Kennt certifi den Aussteller nicht, folgt EIN zweiter Versuch gegen den Speicher des Systems: dort steht auch
#     das Zertifikat eines Virenscanners oder Firmen-Proxys, der die Verbindungen des Rechners mitliest.
#   - Nachsicht nur beim Datum: ist ein Zertifikat abgelaufen oder noch nicht gueltig (der Betreiber hat die
#     Erneuerung verschlafen, oder ein Geraet ohne Uhr steht direkt nach dem Start auf einem falschen Datum), laeuft
#     die Verbindung weiter — Name und Aussteller bleiben geprueft — und im Log steht eine Warnung.
# Die Kontexte entstehen einmal je Prozess und erst bei Bedarf: create_default_context liest die Zertifikate ein
# (5-7 ms je Aufruf auf einem PC, auf einem Stick mehr). Unter einer Sperre, weil parallele Abrufe (Domain-Check,
# TMDB-Vorlauf) sonst je einen eigenen Kontext bauen: _kontextArt erkennt einen Kontext an seinem Platz hier.
_sslContexts = {}
_sslContextLock = threading.Lock()
# Fehlernummern der Pruefung (OpenSSL, x509_vfy.h): 9 Zertifikat noch nicht gueltig, 10 abgelaufen — und die
# Faelle „Aussteller unbekannt": 2 und 20 Aussteller nicht gefunden, 18 und 19 selbst ausgestellt (einzeln, in der
# Kette), 21 erstes Zertifikat nicht pruefbar. Ein falscher Name (62) bekommt keinen zweiten Versuch.
_ZERT_DATUM = (9, 10)
_ZERT_AUSSTELLER = (2, 18, 19, 20, 21)
# X509_V_FLAG_NO_CHECK_TIME (OpenSSL, x509_vfy.h): die Pruefung ohne den Blick aufs Datum. Python fuehrt die
# Konstante nicht (nachgestellt mit Python 3.8 bis 3.14 am 10.11.2026: abgelaufen wird angenommen, falscher
# Name, selbst ausgestellt, unbekannter Aussteller und unvollstaendige Kette bleiben abgelehnt).
_X509_NO_CHECK_TIME = 0x200000
# Der Kontext, mit dem ein Host in diesem Aufruf zuletzt durchkam (Speicher des Systems, Nachsicht beim Datum):
# der naechste Abruf an denselben Host beginnt damit statt wieder mit dem Versuch, der scheitert. Nur eine
# Abkuerzung: lehnt der gemerkte Kontext ab, beginnt die Pruefung einmal von vorn.
_zertWahl = {}


def _sslContext(bVerify, bSystem=False, bOhneDatum=False):
    key = (True, bool(bSystem), bool(bOhneDatum)) if bVerify else (False, False, False)
    oContext = _sslContexts.get(key)
    if oContext is None:
        with _sslContextLock:
            oContext = _sslContexts.get(key)
            if oContext is None:
                if bVerify:
                    oContext = ssl.create_default_context() if bSystem else ssl.create_default_context(cafile=certifi.where())
                    oContext.check_hostname = True
                    oContext.verify_mode = ssl.CERT_REQUIRED
                    if bOhneDatum:
                        oContext.verify_flags |= _X509_NO_CHECK_TIME
                else:
                    oContext = ssl.create_default_context()
                    oContext.check_hostname = False
                    oContext.verify_mode = ssl.CERT_NONE
                _sslContexts[key] = oContext
    return oContext


def _kontextArt(oContext):
    # (prueft, Speicher des Systems, ohne Datum) eines Kontexts aus _sslContext — None fuer einen fremden
    for key, oBekannt in list(_sslContexts.items()):
        if oBekannt is oContext:
            return key
    return None


def _zertNachsicht(oContext, e):
    """Lohnt nach einem abgelehnten Zertifikat ein weiterer Versuch? Liefert den Kontext dafuer oder None.
    Jeder Schritt schaltet genau eine Stufe weiter (Speicher des Systems, Nachsicht beim Datum), es bleibt also
    bei hoechstens zwei weiteren Versuchen."""
    aArt = _kontextArt(oContext)
    if not aArt or not aArt[0]:
        return None
    iCode = getattr(e, 'verify_code', None)
    try:
        if iCode in _ZERT_DATUM and not aArt[2]:
            return _sslContext(True, aArt[1], True)
        if iCode in _ZERT_AUSSTELLER and not aArt[1]:
            return _sslContext(True, True, aArt[2])
    except Exception as eKontext:
        # der Speicher des Systems laesst sich nicht laden oder die TLS-Bibliothek kennt den Schalter nicht:
        # dann bleibt es bei der Ablehnung
        logger.error(' -> [requestHandler]: kein zweiter Kontext fuer die Zertifikatspruefung: %s' % eKontext)
    return None


class _PinnedHTTPConnection(http.client.HTTPConnection):
    # Verbindet zur gepinnten IP, spricht die Gegenseite aber weiter mit dem Hostnamen an.
    def __init__(self, host, ip=None, **kwargs):
        super().__init__(host, **kwargs)
        self._pinned_ip = ip

    def connect(self):
        if not self._pinned_ip:
            return super().connect()
        self.sock = self._create_connection((self._pinned_ip, self.port), self.timeout, self.source_address)
        try:
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass
        if self._tunnel_host:
            self._tunnel()


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    # Jede HTTPS-Verbindung des Handlers: mit Pin zur IP wie oben, sonst wie die Stdlib — danach TLS mit
    # server_hostname=Hostname: SNI und Zertifikatspruefung laufen gegen den echten Namen, nicht gegen die IP.
    # Lehnt die Pruefung das Zertifikat ab, entscheidet _zertNachsicht, ob ein weiterer Versuch lohnt (Speicher
    # des Systems, Nachsicht beim Datum — Regeln bei _sslContexts).
    def __init__(self, host, ip=None, **kwargs):
        super().__init__(host, **kwargs)
        self._pinned_ip = ip

    def connect(self):
        sName = self._tunnel_host if self._tunnel_host else self.host
        oContext = self._context
        aBasis = _kontextArt(oContext)
        bGemerkt = aBasis == (True, False, False) and sName in _zertWahl
        if bGemerkt:
            oContext = _sslContext(True, *_zertWahl[sName])
        eDatum = None
        while True:
            try:
                self._verbinde(oContext, sName)
                break
            except ssl.SSLCertVerificationError as e:
                oWeiter = _zertNachsicht(oContext, e)
                if oWeiter is None and bGemerkt:
                    # der gemerkte Kontext passt nicht mehr (anderes Zertifikat als beim letzten Abruf)
                    bGemerkt = False
                    _zertWahl.pop(sName, None)
                    oContext, eDatum = self._context, None
                    continue
                if oWeiter is None:
                    e.xsHost = sName    # fuer die Meldung in request(): der Host, dessen Zertifikat abgelehnt wurde
                    raise
                if getattr(e, 'verify_code', None) in _ZERT_DATUM:
                    eDatum = e
                oContext = oWeiter
        aArt = _kontextArt(oContext)
        if aBasis == (True, False, False) and aArt and aArt != aBasis and _zertWahl.get(sName) != aArt[1:]:
            _zertWahl[sName] = aArt[1:]
            if eDatum is not None:
                logger.warning(' -> [requestHandler]: Zertifikat von %s abgelaufen oder noch nicht gueltig (%s) — '
                               'Name und Aussteller sind geprueft, die Verbindung laeuft weiter'
                               % (sName, getattr(eDatum, 'verify_message', None) or eDatum))

    def _verbinde(self, oContext, sName):
        if self._pinned_ip:
            self.sock = self._create_connection((self._pinned_ip, self.port), self.timeout, self.source_address)
            try:
                self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass
            if self._tunnel_host:
                self._tunnel()
        else:
            http.client.HTTPConnection.connect(self)
        self.sock = oContext.wrap_socket(self.sock, server_hostname=sName)


class _PinnedHTTPHandler(HTTPHandler):
    # Ohne Pin fuer den Host verhaelt sich der Handler exakt wie HTTPHandler.
    def http_open(self, req):
        ip = _dohPin(req.host)
        if not ip:
            return super().http_open(req)
        return self.do_open(partial(_PinnedHTTPConnection, ip=ip), req)


class _PinnedHTTPSHandler(HTTPSHandler):
    # Jede HTTPS-Verbindung laeuft ueber _PinnedHTTPSConnection, mit oder ohne Pin (dort sitzt der zweite
    # Versuch der Zertifikatspruefung). Nur der SSL-Kontext wird durchgereicht — check_hostname kennt
    # HTTPSConnection ab Python 3.12 nicht mehr als Argument, und wir setzen es ohnehin im Kontext.
    def https_open(self, req):
        return self.do_open(partial(_PinnedHTTPSConnection, ip=_dohPin(req.host)), req, context=self._context)


def _vorStellen(dHeaders, sKey, aAnker):
    """sKey direkt vor die erste vorhandene Zeile aus aAnker stellen: die Reihenfolge des Kopfzeilen-Dicts einer
    urllib-Request ist die Sendefolge (Schluessel wie dort: erster Buchstabe gross)."""
    for sAnker in aAnker:
        if sAnker in dHeaders and sAnker != sKey:
            aItems = [(k, v) for k, v in dHeaders.items() if k != sKey]
            aItems.insert([k for k, _ in aItems].index(sAnker), (sKey, dHeaders[sKey]))
            dHeaders.clear()
            dHeaders.update(aItems)
            return


def _hinterStellen(dHeaders, aKeys, sAnker):
    """Die vorhandenen Zeilen aus aKeys in dieser Folge direkt hinter sAnker stellen (Sendefolge wie bei _vorStellen)."""
    if sAnker not in dHeaders:
        return
    aWeg = [k for k in aKeys if k in dHeaders and k != sAnker]
    aItems = [(k, v) for k, v in dHeaders.items() if k not in aWeg]
    iPos = [k for k, _ in aItems].index(sAnker) + 1
    aItems[iPos:iPos] = [(k, dHeaders[k]) for k in aWeg]
    dHeaders.clear()
    dHeaders.update(aItems)


class RedirectFilter(HTTPRedirectHandler):
    # 308 folgen wie 301, 302, 303 und 307: urllib kennt den Code erst ab Python 3.11, Kodi 21 bringt unter
    # Windows und Xbox Python 3.8 mit (Kodi-Quelle 21.3, Paketliste fuer Windows) — dort endete eine 308 als
    # „Seite nicht erreichbar".
    http_error_308 = HTTPRedirectHandler.http_error_302

    def redirect_request(self, req, fp, code, msg, hdrs, newurl):
        if cConfig().getSetting('bypassDNSlock', 'false') != 'true':
            if 'notice.cuii' in newurl:
                # Die verweigerte Weiterleitung kommt in request() als HTTPError 3xx an; der Merker haelt dort das
                # zweite Fenster („Fehler beim Abrufen der URL … HTTP Error 302") zurueck — gemeldet wird hier
                # (26.10.2026 lokal provoziert: bis dahin zwei Fenster je Klick bei ausgeschalteter DNS-Umgehung)
                _cuiiRefused.flag = True
                if not _windowsQuiet():
                    _markErrorShown()
                    xbmcgui.Dialog().ok(cConfig().getLocalizedString(30265), cConfig().getLocalizedString(30260) + '\n' + cConfig().getLocalizedString(30261))
                return None
        if code in (307, 308) and req.get_method() == 'POST':
            # 307/308 auf einen POST: derselbe POST samt Rumpf und Content-Type am neuen Ort (RFC 9110, so folgen Browser).
            # urllib kennt den Fall nicht und reicht die Antwort als HTTPError 307 durch — bis zum 02.11.2026 endete der
            # Abruf damit mit einer Fehlermeldung (lokal nachgestellt). 301/302/303 bleiben bei urllib:
            # weiter als GET ohne Rumpf, wie im Browser. Die Schleifen-Grenze (max_redirections) sitzt im Aufrufer.
            newreq = Request(newurl.replace(' ', '%20'), data=req.data, headers=dict(req.headers),
                             origin_req_host=req.origin_req_host, unverifiable=True, method='POST')
        else:
            # 308 geht als 307 an die Stdlib: dieselbe Regel (GET und HEAD folgen), aber Python vor 3.11 weist
            # den Code 308 an dieser Stelle ab
            newreq = HTTPRedirectHandler.redirect_request(self, req, fp, 307 if code == 308 else code, msg, hdrs, newurl)
        if newreq is not None and browserProfiles.profileForUA(req.get_header('User-agent')):
            # Firefox bildet Sec-Fetch-Site, Referer und Origin je Hop neu, urllib kopiert sie unveraendert
            # (browserProfiles.redirectHop); fremde UAs (ohne Profil: die Vavoo-App-UAs) bleiben,
            # wie urllib sie weiterreicht.
            # Ein neuer Wert ersetzt die vorhandene Zeile an ihrer Stelle (add_header schreibt in dasselbe Dict).
            # Bis zum 01.11.2026 loeschte der Filter sie vorher, die drei landeten so hinter Priority — Firefox 159
            # laesst den Sec-Fetch-Block auf dem Hop zusammen (Mitschnitte Faelle 10, 13-20)
            for key, value in browserProfiles.redirectHop(req.full_url, newreq.full_url, req.get_header('Referer'),
                                                          req.get_header('Sec-fetch-site'), req.get_header('Origin'),
                                                          req.get_header('Sec-fetch-mode') == 'cors',
                                                          req.get_method() == 'POST',
                                                          newreq.get_method() == 'POST').items():
                if value is None:
                    newreq.remove_header(key.capitalize())
                else:
                    newreq.add_header(key, value)
            # Origin steht auf dem Hop eines fetch() VOR dem Referer (im ersten Abruf dahinter), ohne Referer vor
            # Connection — auch wenn er erst hier dazukommt (Firefox 159 de, Faelle 13, 14, 16, 18, 20; Firefox 160 de
            # 09.11.2026 auch auf dem 307-Hop eines POST, Fall 22). Auf dem Hop einer Navigation folgen Referer, Origin
            # (nur ein POST auf 307/308 traegt einen) und Connection in dieser Reihenfolge — im ersten Abruf steht
            # Connection dagegen vor dem Referer (Firefox 160 de 09.11.2026, Faelle 05, 17, 19 und 21)
            bCorsHop = req.get_header('Sec-fetch-mode') == 'cors'
            if 'Origin' in newreq.headers and (bCorsHop or 'Referer' not in newreq.headers):
                _vorStellen(newreq.headers, 'Origin', ('Referer', 'Connection'))
            elif not bCorsHop:
                _hinterStellen(newreq.headers, ('Origin', 'Connection'), 'Referer')
        return newreq


class _NoRedirect(HTTPRedirectHandler):
    # Folgt Redirects NICHT: redirect_request gibt None zurueck, wodurch urllib die
    # 3xx-Antwort als HTTPError durchreicht -> dort steht der Location-Header.
    def redirect_request(self, req, fp, code, msg, hdrs, newurl):
        return None

class cRequestHandler:
    @staticmethod
    def RandomUA():
        # Einstieg fuer alle Aufrufer (Sites, trailer.py, updateManager): der User-Agent
        # des Browser-Profils (seit dem 14.10.2026 genau eines, Firefox auf Windows). Profil,
        # Kopfsaetze und Versionspflege stehen in browserProfiles.py.
        return browserProfiles.randomUA()

    def __init__(self, sUrl, caching=True, ignoreErrors=False, method='GET', data=None, compression=True, jspost=False, ssl_verify=None, cookies=True):
        self._sUrl = self.__cleanupUrl(sUrl)
        self._sRealUrl = ''
        self._USER_AGENT = self.RandomUA()
        self._aParameters = {}
        self._headerEntries = {}
        self._profilePath = translatePath(cConfig().getAddonInfo('profile'))
        self._cachePath = ''
        self._cookiePath = ''
        self._Status = ''
        self._Protection = ''  # 'cf' / 'ddos', sobald ein Schutzsystem erkannt wurde
        self._mode = browserProfiles.MODE_PAGE  # Seitenaufruf; requestJson() schaltet auf API
        self._sResponseHeader = ''
        # Zertifikatspruefung (Regeln bei _sslContexts): an, solange die Einstellung „SSL Zertifikate pruefen" sie
        # nicht abschaltet. ssl_verify=True prueft IMMER, auch bei ausgeschalteter Einstellung — fuer Abrufe, die
        # einen Schluessel tragen (2Captcha, TMDB). Abschalten laesst sich die Pruefung nur ueber die Einstellung.
        self._ssl_verify = bool(ssl_verify) or cConfig().getSetting('sslVerify', 'true') != 'false'
        self.ignoreDiscard(False)
        self.ignoreExpired(False)
        self.caching = caching
        self.method = method
        self.data = data
        self.ignoreErrors = ignoreErrors
        self.compression = compression
        self.jspost = jspost
        # cookies=False: sitzungslose Anfrage. Es wird kein Cookie mitgeschickt und
        # keines gespeichert; der Opener kommt ohne Cookie-Verarbeitung. Gebaut fuer
        # parallele Abrufe gegen DLE-Seiten:
        # die binden die Sitzung an ein PHPSESSID-Cookie, und PHP sperrt die Sitzung
        # je Anfrage — parallele Abrufe mit demselben Cookie werden serverseitig
        # NACHEINANDER abgearbeitet (kkiste: vier Seiten 5,3 s mit, 2,1 s ohne Cookie;
        # hdfilme 4,1 s gegen 1,6 s, gemessen 02.09.2026). Seit die Suche nur noch eine
        # Ergebnisseite je Aufruf holt (21.10.2026), hat der Schalter keinen Aufrufer;
        # er bleibt als Option fuer den naechsten parallelen Abruf.
        self.cookies = cookies
        self.cacheTime = int(cConfig().getSetting('cacheTime', 1)) * 3600  # Stunden * 3600 = Sekunden
        self.requestTimeout = int(cConfig().getSetting('requestTimeout', 10))
        self._iRumpfFrist = max(RUMPF_MINDESTFRIST, RUMPF_FAKTOR * self.requestTimeout)
        self.bypassDNSlock = (cConfig().getSetting('bypassDNSlock', 'false') == 'true')
        self.removeBreakLines(True)
        self.removeNewLines(True)
        self.__setDefaultHeader()
        self.__setCachePath()
        self.__setCookiePath()
        self.isMemoryCacheActive = (cConfig().getSetting('volatileHtmlCache', 'false') == 'true')
        if self.isMemoryCacheActive:
            self._memCache = cCache()
        
        socket.setdefaulttimeout(self.requestTimeout)

    def getStatus(self):
        return self._Status

    def _errorWindow(self, sText):
        # Fehlerfenster des Handlers (4xx/5xx, URLError, ungueltige Anfrage): nicht bei stillen Abrufen
        # (ignoreErrors) und nicht im Hosterlink-Schritt (quietWindows, oben) — dann bleibt nur die Logzeile
        if self.ignoreErrors or _windowsQuiet():
            return
        _markErrorShown()
        xbmcgui.Dialog().ok('xStream', sText)

    def getProtection(self):
        """'cf' bei einer Cloudflare-Sperre, 'ddos' bei DDoS-Guard, sonst ''.

        Der Domain-Check braucht die Unterscheidung: im Status steht nur der
        HTTP-Code, und der ist bei beiden Systemen 403.
        """
        return self._Protection

    def requestJson(self):
        """request() mit JSON-Auswertung — liefert None statt eine Exception zu werfen.

        Sites, die eine JSON-Schnittstelle abfragen, duerfen `json.loads` NICHT
        direkt auf `request()` anwenden: im Fehlerfall kommt von dort ein
        Klartext aus REQUEST_ERRORS zurueck, und `json.loads` wirft darauf einen
        JSONDecodeError. Der Nutzer sah deshalb einen Skriptfehler, obwohl der
        Handler den Fehler bereits gemeldet hatte — bei jedem 4xx/5xx, jedem
        Timeout und jeder Sperre. Mit None greifen stattdessen die vorhandenen
        `if not jSearch`-Pruefungen der Site-Files, und der Nutzer bekommt die
        gewohnte Meldung.

        Kaputtes JSON einer erreichbaren Seite faellt gleich mit ab: es knallte
        bisher an genau derselben Stelle.
        """
        self._mode = browserProfiles.MODE_API  # fetch() der Seite auf ihre Schnittstelle
        sContent = self.request()
        if not sContent or sContent in REQUEST_ERRORS:
            return None
        try:
            return json.loads(sContent)
        except ValueError as e:
            logger.error(' -> [requestHandler]: kein gueltiges JSON (%s) Url: %s' % (e, self._sUrl))
            return None

    def removeNewLines(self, bRemoveNewLines):
        self.__bRemoveNewLines = bRemoveNewLines

    def removeBreakLines(self, bRemoveBreakLines):
        self.__bRemoveBreakLines = bRemoveBreakLines

    def addHeaderEntry(self, sHeaderKey, sHeaderValue):
        self._headerEntries[sHeaderKey] = sHeaderValue

    def addParameters(self, key, value, Quote=False):
        self._aParameters[key] = value if not Quote else quote(str(value))

    def getResponseHeader(self):
        return self._sResponseHeader

    def getRealUrl(self):
        return self._sRealUrl

    def getRequestUri(self):
        return self._sUrl + '?' + urlencode(self._aParameters)

    def __setDefaultHeader(self):
        # Beim Anlegen steht nur der UA fest. Der restliche Kopfsatz entsteht erst beim
        # Abruf (__buildHeaders), weil eine Site den UA bis dahin noch ueberschreiben
        # kann (Sitzungs-UA bei kinoger und megakino) — und der Satz muss zu dem UA
        # passen, der wirklich rausgeht.
        self.addHeaderEntry('User-Agent', self._USER_AGENT)

    def __legacyHeaders(self, sUA):
        # Der Kopfsatz von vor den Browser-Profilen, unveraendert: gilt fuer jeden UA,
        # der zu keinem Profil gehoert (die Vavoo-App-UAs: Ping, Katalog, Resolve
        # und Stream-Vorabruf), damit sich dort nichts bewegt.
        # Firefox-typische Zeilen, dazu Keep-Alive, das kein Browser sendet.
        aHeaders = [('User-Agent', sUA),
                    ('Accept-Language', 'de,en-US;q=0.7,en;q=0.3'),
                    ('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8')]
        if self.compression:
            aHeaders.append(('Accept-Encoding', 'gzip, deflate'))
        aHeaders += [('Connection', 'keep-alive'), ('Keep-Alive', 'timeout=5')]
        return aHeaders

    def __buildHeaders(self, bPost=False):
        """Der Kopfsatz, der wirklich auf die Leitung geht — als geordnete Liste.

        Grundlage ist das Browser-Profil zu dem UA, der JETZT gesetzt ist (Default
        oder von der Site ueberschrieben). Den Modus bestimmt der Aufruf: requestJson(),
        X-Requested-With, jspost oder ein JSON-Rumpf heissen "fetch() der Seite",
        alles andere ist ein Seitenaufruf; Sec-Fetch-Site ergibt sich aus dem Referer,
        bei einem POST (bPost, wie urllib ihn sendet) ohne Referer same-origin statt none,
        und ein POST bekommt Origin.
        Was die Site selbst gesetzt hat, gewinnt — unabhaengig von der Schreibweise
        (burningseries setzt seine Namen klein), neue Zeilen kommen hinten dran. Ausnahme
        Referer: der Wert der Site ist die Adresse der ausloesenden Seite, hinaus geht, was
        das Profil daraus macht (an fremde Urspruenge nur der Ursprung, seit 01.11.2026).
        """
        aSite = list(self._headerEntries.items())
        sUA = self._USER_AGENT
        sReferer = ''
        sMode = self._mode
        if self.jspost:
            sMode = browserProfiles.MODE_API
        for key, value in aSite:
            sKey = key.lower()
            if sKey == 'user-agent':
                sUA = value
            elif sKey == 'referer':
                sReferer = value
            elif sKey == 'x-requested-with' or (sKey == 'content-type' and 'json' in value.lower()):
                sMode = browserProfiles.MODE_API
        aHeaders = browserProfiles.buildHeaders(sUA, self._sUrl, sReferer, sMode, self.compression, bPost)
        bProfile = aHeaders is not None
        if aHeaders is None:
            aHeaders = self.__legacyHeaders(sUA)
        aOut = []
        dIndex = {}
        for key, value in aHeaders:
            dIndex[key.lower()] = len(aOut)
            aOut.append([key, value])
        for key, value in aSite:
            sKey = key.lower()
            if bProfile and sKey == 'referer':
                continue  # schon im Profil-Satz, gekuerzt wie bei Firefox (oder weggelassen, https nach http)
            if sKey in dIndex:
                aOut[dIndex[sKey]][1] = value
            else:
                dIndex[sKey] = len(aOut)
                aOut.append([key, value])
        return [(key, value) for key, value in aOut]

    @staticmethod
    def __getDefaultHandler(ssl_verify):
        return [_PinnedHTTPSHandler(context=_sslContext(bool(ssl_verify)))]

    @staticmethod
    def __cleanupUrl(url):
        return url
    
    def request(self):
        if self.caching and self.cacheTime > 0  and self.method == 'GET' and self.data is None:
            if self.isMemoryCacheActive:
                sContent = self.__readVolatileCache(self.getRequestUri(), self.cacheTime)
            else:
                sContent = self.__readPersistentCache(self.getRequestUri())
            if sContent:
                self._Status = '200'
                return sContent
        # Jeder Abruf, der hinausgeht, steht im Log; ein Treffer aus dem Cache schreibt oben seine eigene Zeile. Bis zum
        # 11.11.2026 stand hier nur der Abruf ohne Cache — einer mit Cache, der nichts im Cache fand, ging still hinaus.
        logger.info('-> [requestHandler]: read html for %s' % self.getRequestUri())

        # DNS-Bypass global ueber Setting (kein per-Site-Flag mehr): jeder Host des Abrufs, auch hinter einer
        # Weiterleitung, wird bei der ersten Verbindung per DoH aufgeloest (_dohPin)
        _doh_resolver = self.__dohHost if self.bypassDNSlock else None

        cookieJar = _cookieJar(self._cookiePath, self.__bIgnoreDiscard, self.__bIgnoreExpired)

        # Ein Opener je Abruf mit der Cookie-Dose der Domain (_cookieJar, oben), die unten gespeichert wird. Einen
        # Opener wiederzuverwenden spart nichts: urllib schliesst jede Verbindung nach der Antwort (Connection: close).
        handlers = self.__getDefaultHandler(self._ssl_verify) + [_PinnedHTTPHandler()]
        if self.cookies:
            handlers.append(HTTPCookieProcessor(cookiejar=cookieJar))
        opener = build_opener(*(handlers + [RedirectFilter()]))

        if self.method == 'POST':
            if self.data is not None:
                if isinstance(self.data, dict):
                    # Default: form data
                    sParameters = urlencode(self.data).encode()
                elif isinstance(self.data, str):
                    sParameters = self.data.encode()
                else:
                    sParameters = self.data
            else:
                sParameters = None
        else:
            sParameters = json.dumps(self._aParameters).encode() if self.jspost else urlencode(self._aParameters, True).encode()
            if len(sParameters) == 0:
                sParameters = None
        
        try:
            oRequest = Request(self._sUrl, sParameters if sParameters and len(sParameters) > 0 else None)
        except ValueError as e:
            # Adresse ohne Schema (unknown url type) u. ae.: Meldung wie bei einem Verbindungsfehler statt
            # Skriptfehler (02.11.2026 nachgestellt)
            self._errorWindow(str(e))
            logger.error(' -> [requestHandler]: ungueltige Adresse: ' + str(e))
            return ERR_URL

        for key, value in self.__buildHeaders(oRequest.get_method() == 'POST'):
            oRequest.add_header(key, value)
        
        # Content-Type nur mit Rumpf: ohne Daten schickt urllib ein GET, das bis zum 01.11.2026 trotzdem einen bekam
        # (method='POST' ohne data, jspost ohne Parameter — kein Aufrufer, aber ein GET mit Content-Type gibt es im Browser nicht)
        if oRequest.data is not None:
            if self.method == 'POST' and 'Content-Type' not in self._headerEntries:
                oRequest.add_header('Content-Type', 'application/x-www-form-urlencoded')
            elif self.jspost:
                oRequest.add_header('Content-Type', 'application/json')
        
        if self.cookies:
            cookieJar.add_cookie_header(oRequest)
        
        try:
            with _doh_resolution(None, None, _doh_resolver):
                oResponse = opener.open(oRequest)
            # Auch das LESEN der Antwort gehoert in den Schutz: stockt der Body (Lese-Timeout)
            # oder bricht die Verbindung mittendrin ab (IncompleteRead, Reset), greifen dieselben
            # Zweige wie beim Verbindungsaufbau. Belegt 04.09.2026: 9 von ~9.200 Klicks
            # endeten so als Skriptfehler, weil read() bis dahin hinter dem try stand.
            self._sResponseHeader = oResponse.info()
            content_encoding = self._sResponseHeader.get('Content-Encoding', '').lower()
            sContent = _text(_entpacke(_rumpf(oResponse, self._iRumpfFrist), content_encoding, self._sUrl, bStreng=True),
                             self._sResponseHeader.get_content_charset())
        except HTTPError as e:
            if e.code >= 400:
                self._Status = str(e.code)
                # Auch das Lesen der Fehlerseite kann stocken oder abbrechen — dann reicht der Status fuer die
                # Meldung. Bis zum 02.11.2026 flog ein Lese-Timeout hier als Skriptfehler heraus, weil er im
                # except-Zweig selbst entstand (nachgestellt: 503 mit stockendem Rumpf)
                try:
                    data = _rumpf(e.fp, self._iRumpfFrist)
                except (OSError, HTTPException):
                    data = b''
                # Auch eine Fehlerseite kommt gepackt, wenn der Server gzip/deflate nutzt — unser
                # Accept-Encoding gilt fuer jede Antwort (kinoger-404 und Cloudflare-Challenges
                # kamen gzip, gemessen 22.10.2026). Bis dahin liefen die Marker unten und die
                # Logzeile auf den gepackten Bytes: eine gepackte DDoS-Guard-Seite hiess „nicht
                # erreichbar", im Log stand Binaermuell. Entpackt wird wie im Erfolgszweig; eine
                # kaputte Huelle bleibt roh, damit der Fehlerweg selbst nie wirft.
                data = _entpacke(data, (e.headers.get('Content-Encoding') or '').lower(), self._sUrl)
                # ERKENNUNG DER SCHUTZSYSTEME — Merkmale statt Namensraten.
                # Frueher galt JEDER 4xx als Cloudflare-Sperre, sobald irgendwo in den
                # Headern das Wort "cloudflare" stand. Bei einer Seite hinter Cloudflare
                # steht es aber IMMER drin (server: cloudflare, dazu ein report-to auf
                # a.nel.cloudflare.com) — auch in einer voellig harmlosen 404. Gemessen
                # am 25.08.: 10 von 18 Seiten, jede tote Adresse wurde dem Nutzer als
                # Sperre gemeldet. Merkmal ist deshalb `cf-mitigated`: den Header setzt
                # Cloudflare nur, wenn es tatsaechlich eingegriffen hat (hdfilme:
                # 403 + cf-mitigated: challenge; alle gemessenen 404 ohne). Ersatzmerkmal
                # im Body ('just a moment' = Titel, 'cf_chl' = Kennung im Challenge-Skript
                # der Cloudflare-Seite; 25.08.2026), nur bei 403/503.
                # DDoS-Guard genauso: bis zum 09.10.2026 reichte der Header
                # `server: ddos-guard` — den traegt aber jede Antwort einer Seite
                # dahinter, auch eine normale 404 (tote Serie) oder ein 502, und die
                # bekamen so faelschlich die Sperrmeldung. Merkmal ist die Pruefseite
                # selbst (DDOS_GUARD_MARKERS), wie bei Cloudflare nur bei 403/503.
                sBody = str(data).lower()
                aHeaderNames = set(k.lower() for k in e.headers.keys())
                isDdosGuard = e.code in (403, 503) and any(m in sBody for m in DDOS_GUARD_MARKERS)
                isCloudflare = ('cf-mitigated' in aHeaderNames
                                or (e.code in (403, 503) and ('just a moment' in sBody or 'cf_chl' in sBody)))
                self._Protection = 'ddos' if isDdosGuard else ('cf' if isCloudflare else '')
                if isDdosGuard:
                    # Bewusst KEIN Umgehungsversuch mehr (raus seit dem 06.10.2026):
                    # der alte Weg ueber check.ddos-guard.net scheiterte dort fast immer
                    # an einem 403, und kam er doch durch, las er die Antwort nicht und
                    # brach mit einem Skriptfehler ab. Am Geraet sperrt DDoS-Guard
                    # nicht einmal ueber VPN. Die Erkennung oben bleibt: Meldung,
                    # Rueckgabe und der Status fuer den Domain-Check (getProtection).
                    if not self.ignoreErrors:
                        _markErrorShown()
                        infoDialog(cConfig().getLocalizedString(30875), icon='WARNING', time=10000)
                    logger.error(' -> [requestHandler]: Failed DDoS-Guard active: ' + self._sUrl)
                    return ERR_DDOS
                elif isCloudflare:
                    if not self.ignoreErrors:
                        _markErrorShown()
                        infoDialog(cConfig().getLocalizedString(30829), icon='WARNING', time=10000)
                    logger.error(' -> [requestHandler]: Failed Cloudflare active: ' + self._sUrl)
                    return ERR_CLOUDFLARE
                else:
                    self._errorWindow(cConfig().getLocalizedString(30259) + ' {0} {1}'.format(self._sUrl, str(e)))
                    # Den Fehlertext des Servers mitschreiben: er steht ohnehin schon in
                    # `data` und beantwortet oft direkt, WAS er beanstandet hat. Aus der
                    # blossen Statuszahl war das nicht zu erkennen - am 31.08.2026 kam
                    # von der Vavoo-API minutenlang ein 400, und erst der Body verriet
                    # {"error":"Validation error"}. Gekuerzt und einzeilig, damit eine
                    # HTML-Fehlerseite das Log nicht flutet.
                    sErrorBody = ''
                    try:
                        sErrorBody = ' '.join(data.decode('utf-8', 'replace').split())[:200]
                    except Exception:
                        pass
                    logger.error(' -> [requestHandler]: HTTPError ' + str(e) + ' Url: ' + self._sUrl
                                 + ((' Body: ' + sErrorBody) if sErrorBody else ''))
                    return ERR_UNREACHABLE
            else:
                # Ein 3xx landet nur hier, wenn RedirectFilter die Weiterleitung verweigert hat (CUII-Sperre, dort
                # schon gemeldet) oder urllib eine Weiterleitungsschleife abbricht — ein Fenster nur im zweiten Fall
                if getattr(_cuiiRefused, 'flag', False):
                    _cuiiRefused.flag = False
                else:
                    self._errorWindow(cConfig().getLocalizedString(30259) + ' {0} {1}'.format(self._sUrl, str(e)))
                logger.error(' -> [requestHandler]: HTTPError ' + str(e) + ' Url: ' + self._sUrl)
                return ERR_UNREACHABLE
        except (socket.timeout, TimeoutError):
            # Der Server hat die Verbindung angenommen und dann nicht geantwortet.
            # Seit Python 3.10 IST socket.timeout dasselbe wie TimeoutError und faellt
            # damit durch URLError/HTTPException hindurch — vorher flog der Fall als
            # unbehandelte Exception aus request() heraus und Kodi zeigte einen
            # Skriptfehler.
            return self._timeout()
        except URLError as e:
            # Die Verbindung kam gar nicht zustande. Ein Fall ist dabei eindeutig:
            # sagt der DNS "Name unbekannt" (gaierror -2 / WSAHOST_NOT_FOUND 11001),
            # existiert die Domain nicht mehr — das ist offline, nicht bloss gestoert.
            # Eine voruebergehende Aufloesungsstoerung meldet dagegen gaierror -3
            # (EAI_AGAIN), ein toter Server errno 111/104; die bleiben ohne Status und
            # gelten als unklar.
            # Der Domain-Check liest das aus (STATUS_OFFLINE_DNS bzw. keine Verbindung).
            reason = getattr(e, 'reason', None)
            if isinstance(reason, (socket.timeout, TimeoutError)):
                # Die Frist lief schon im Verbindungsaufbau ab (die Gegenseite nimmt an und schweigt im
                # TLS-Handshake): urllib verpackt das in einen URLError. Dieselbe Lage wie der Lese-Timeout,
                # also dieselbe Meldung — bis zum 11.11.2026 kam hier ein Fenster mit dem Text der
                # TLS-Bibliothek, und im Menue stand „Verbindungsfehler".
                return self._timeout()
            if isinstance(reason, ssl.SSLCertVerificationError):
                return self._zertAbgelehnt(reason)
            if isinstance(reason, socket.gaierror) and reason.errno in (-2, 11001):
                self._Status = '-5'
            self._errorWindow(str(e.reason))
            logger.error(' -> [requestHandler]: URLError ' + str(e.reason) + ' Url: ' + self._sUrl)
            return ERR_URL
        except HTTPException as e:
            # Die Gegenseite bricht die Antwort mittendrin ab oder schliesst, ohne zu antworten
            self._abgebrochen()
            logger.error(' -> [requestHandler]: HTTPException ' + str(e) + ' Url: ' + self._sUrl)
            return ERR_TIMEOUT
        except OSError as e:
            # Verbindung waehrend des Lesens weg (Reset, EOF) — kein URLError, sonst ungefangen
            self._abgebrochen()
            logger.error(' -> [requestHandler]: OSError ' + str(e) + ' Url: ' + self._sUrl)
            return ERR_URL
        except ValueError as e:
            # Nicht-ASCII in Pfad oder Kopfzeile (UnicodeEncodeError beim Senden): Meldung statt Skriptfehler
            # (02.11.2026 nachgestellt)
            self._errorWindow(str(e))
            logger.error(' -> [requestHandler]: ungueltige Anfrage ' + str(e) + ' Url: ' + self._sUrl)
            return ERR_URL

        if self.cookies:
            try:
                with _cookieJarsLock:
                    cookieJar.save(ignore_discard=self.__bIgnoreDiscard, ignore_expires=self.__bIgnoreExpired)
            except Exception as e:
                logger.error(' -> [requestHandler]: Failed save cookie: %s' % e)

        self._sRealUrl = oResponse.geturl()
        # Immer Text wie in allen anderen Zweigen (Cache-Treffer '200', Fehler '404', '-1') — bis zum 02.11.2026
        # kam hier die Zahl aus getcode(), und Aufrufer mussten selbst umwandeln
        self._Status = str(oResponse.getcode()) if self._sUrl == self._sRealUrl else '301'

        if self.__bRemoveNewLines:
            sContent = sContent.replace('\n', '').replace('\r\t', '')
        if self.__bRemoveBreakLines:
            sContent = sContent.replace('&nbsp;', '')

        if self.caching and self.cacheTime > 0 and self.method == 'GET' and self.data is None:
            if self.isMemoryCacheActive:
                self.__writeVolatileCache(self.getRequestUri(), sContent)
            else:
                self.__writePersistentCache(self.getRequestUri(), sContent)

        return sContent

    def _timeout(self):
        # Status -1 (kein gueltiger HTTP-Code) heisst fuer den Domain-Check: langsam, aber nicht tot — die
        # Domain bleibt stehen, die globale Suche ruht bis zur Nachpruefung des Service (pluginHandler).
        self._Status = '-1'
        if not self.ignoreErrors:
            _markErrorShown()
            # Als Einblendung statt als Fenster (so entschieden am 25.08.): ein
            # Timeout trifft bei einer langsamen Seite gleich mehrere Abrufe
            # hintereinander — ein Fenster je Abruf wuerde die Oberflaeche
            # blockieren. Im Menue steht die Seite ausserdem als "Timeout", und die
            # vollstaendige Adresse steht in der Logzeile darunter.
            infoDialog('%s %s' % (cConfig().getLocalizedString(30872), urlparse(self._sUrl).hostname or self._sUrl),
                       icon='ERROR', time=8000)
        logger.error(' -> [requestHandler]: Timeout Url: ' + self._sUrl)
        return ERR_TIMEOUT

    def _abgebrochen(self):
        # Die Gegenseite hat die Verbindung waehrend der Antwort abgebrochen: eine Einblendung wie beim Timeout, kein
        # Fenster mit dem Text der Bibliothek („IncompleteRead(0 bytes read)" — so stand es bis zum 11.11.2026 im
        # Fenster, der naechste Abruf lief jeweils wieder). Wo bisher kein Fenster kam (stiller Abruf,
        # Hosterlink-Schritt), kommt auch keine Einblendung. Der Status bleibt, wie er ist; der Grund und die
        # vollstaendige Adresse stehen in der Logzeile des Fehlerzweigs.
        if not self.ignoreErrors and not _windowsQuiet():
            _markErrorShown()
            infoDialog('%s %s' % (cConfig().getLocalizedString(30877), urlparse(self._sUrl).hostname or self._sUrl),
                       icon='ERROR', time=8000)

    def _zertAbgelehnt(self, reason):
        # Das Zertifikat der Gegenseite wurde abgelehnt (falscher Name, unbekannter Aussteller — Regeln bei
        # _sslContexts): eine Einblendung wie beim Timeout, kein Fenster mit dem Text der TLS-Bibliothek. Im Menue
        # steht hinter dem Namen der Seite „SSL Zertifikatsfehler" (Status -6, pluginHandler.STATUS_CERT); der Grund und
        # die vollstaendige Adresse stehen in der Logzeile.
        self._Status = '-6'
        if not self.ignoreErrors:
            _markErrorShown()
            sHost = getattr(reason, 'xsHost', None) or urlparse(self._sUrl).hostname or self._sUrl
            infoDialog('%s %s' % (cConfig().getLocalizedString(30922), sHost), icon='ERROR', time=8000)
        logger.error(' -> [requestHandler]: Zertifikat abgelehnt (%s) Url: %s'
                     % (getattr(reason, 'verify_message', None) or reason, self._sUrl))
        return ERR_URL

    def getRedirectUrl(self):
        # Loest EINEN Redirect-Hop auf und liefert NUR das Location-Ziel zurueck,
        # ohne die Zielseite selbst zu laden. Noetig fuer Hoster, deren Embed-Seite
        # hinter Cloudflare liegt (z.B. DoodStream): ein GET auf die Seite
        # loest den CF-Block aus. Das Redirect-Ziel liefert die Quell-Seite (URL_MAIN)
        # selbst aus, die Embed-Seite wird hier gar nicht kontaktiert; ResolveURL holt die
        # Seite spaeter mit eigener Logik. Nutzt bewusst dieselbe DoH/Cookie/UA-Basis
        # wie request(), mit eigenem Opener, der Weiterleitungen nicht folgt.
        _doh_resolver = self.__dohHost if self.bypassDNSlock else None

        cookieJar = _cookieJar(self._cookiePath, self.__bIgnoreDiscard, self.__bIgnoreExpired)

        handlers = self.__getDefaultHandler(self._ssl_verify)
        handlers += [_PinnedHTTPHandler(), HTTPCookieProcessor(cookiejar=cookieJar), _NoRedirect()]
        opener = build_opener(*handlers)

        # POST-Bodies werden mitgeschickt, wenn der Aufrufer method='POST' gesetzt hat.
        # Gebraucht fuer Freigabe-Formulare, deren Antwort NUR aus dem Location-Header
        # besteht (serienstream-Captcha-Gate: POST auf /r -> 302 auf die Hoster-Adresse).
        sParameters = None
        if self.method == 'POST' and self.data is not None:
            if isinstance(self.data, dict):
                sParameters = urlencode(self.data).encode()
            elif isinstance(self.data, str):
                sParameters = self.data.encode()
            else:
                sParameters = self.data

        sLocation = ''
        try:
            oRequest = Request(self._sUrl, sParameters)
            for key, value in self.__buildHeaders(oRequest.get_method() == 'POST'):
                oRequest.add_header(key, value)
            if sParameters and 'Content-Type' not in self._headerEntries:
                oRequest.add_header('Content-Type', 'application/x-www-form-urlencoded')
            cookieJar.add_cookie_header(oRequest)
            with _doh_resolution(None, None, _doh_resolver):
                oResponse = opener.open(oRequest)
            sLocation = oResponse.geturl()  # kein Redirect gekommen (z.B. direkt 200) -> finale URL
        except HTTPError as e:
            if e.code in (301, 302, 303, 307, 308):
                sLocation = e.headers.get('Location', '')
            else:
                logger.error(' -> [requestHandler]: getRedirectUrl HTTPError %s Url: %s' % (str(e), self._sUrl))
        except (URLError, HTTPException, OSError, ValueError) as e:
            # OSError: Lese-Timeout oder Reset vor der Antwort — bis zum 02.11.2026 flogen beide als Skriptfehler
            # heraus (nachgestellt); ValueError: ungueltige Adresse
            logger.error(' -> [requestHandler]: getRedirectUrl Fehler %s Url: %s' % (str(e), self._sUrl))

        if sLocation:
            sLocation = urljoin(self._sUrl, sLocation)  # relative Location -> absolut
        return sLocation

    def __setCookiePath(self):
        cookieFile = os.path.join(self._profilePath, 'cookies')
        if not os.path.exists(cookieFile):
            # exist_ok: der Domain-Check legt je Site einen Thread an, und auf einem
            # frischen Profil sehen mehrere Threads gleichzeitig "Ordner fehlt" — der
            # zweite flog hier mit FileExistsError raus, seine Site stand danach bis
            # zum Kodi-Neustart auf "Unbekannter Fehler" ohne globale Suche (06.10.2026,
            # 16 von 30 Laeufen). Die Pruefung davor bleibt, damit ein
            # kaputtes Profil (Datei statt Ordner) sich verhaelt wie bisher.
            os.makedirs(cookieFile, exist_ok=True)
        if 'dummy' not in self._sUrl:
            # Der Dateiname kommt aus der Adresse der Gegenseite — nur Buchstaben, Ziffern,
            # Bindestrich und Unterstrich bleiben, alles andere wird '_' (Regel: Fremddaten
            # nie ungefiltert in Dateipfade). Fuer normale Hosts ist das derselbe Name wie
            # bisher (nur '.' -> '_'); ein Host mit Port (Live-TV-Edges IP:8008) hiess bis
            # zum 22.10.2026 „…:8008.txt" — unter Windows ein Datenstrom, auf FAT unzulaessig.
            sNetloc = ''.join(c if (c.isascii() and c.isalnum()) or c in '-_' else '_' for c in urlparse(self._sUrl).netloc)
            cookieFile = os.path.join(cookieFile, sNetloc + '.txt')
            if not os.path.exists(cookieFile):
                open(cookieFile, 'w').close()
            self._cookiePath = cookieFile

    def setCookie(self, oCookie):
        # in die Dose der Domain (_cookieJar), damit der naechste Abruf desselben Aufrufs das Cookie auch dann traegt,
        # wenn es ein Sitzungs-Cookie ist, das die Datei nicht aufnimmt
        try:
            cookieJar = _cookieJar(self._cookiePath, self.__bIgnoreDiscard, self.__bIgnoreExpired)
            cookieJar.set_cookie(oCookie)
            with _cookieJarsLock:
                cookieJar.save(ignore_discard=self.__bIgnoreDiscard, ignore_expires=self.__bIgnoreExpired)
        except Exception as e:
            logger.error(e)

    def ignoreDiscard(self, bIgnoreDiscard):
        self.__bIgnoreDiscard = bIgnoreDiscard

    def ignoreExpired(self, bIgnoreExpired):
        self.__bIgnoreExpired = bIgnoreExpired

    def __dohHost(self, hostname):
        # Resolver fuer _dohPin: Hostname (ohne Port) -> IP per DoH oder None
        try:
            return self.__doh_request('https://%s/' % hostname)
        except ValueError:
            return None

    def __doh_request(self, url, doh_server="https://cloudflare-dns.com/dns-query"):
        parsed_url = urlparse(url)
        hostname = parsed_url.hostname
        # Eine IP-Adresse als Host (Live-TV-Edges auf Port 8008) hat nichts aufzuloesen:
        # die DoH-Abfrage dafuer kam als NXDOMAIN zurueck — je Senderstart eine Logzeile
        # „Invalid DNS response" und 0,1 bis 0,6 s Wartezeit (gemessen 22.10.2026). Ohne
        # Pin verbindet die Stdlib direkt zur IP, genau wie bei abgeschaltetem Bypass.
        try:
            ipaddress.ip_address(hostname)
            return None
        except ValueError:
            pass
        # Bewusst NICHT gecacht: DDoS-Guard-Edges rotieren, eine im RAM-Cache
        # festgehaltene IP koennte innerhalb der TTL sterben -> immer frisch aufloesen.
        params = urlencode({"name": hostname, "type": "A"})
        doh_url = f"{doh_server}?{params}"
        req = Request(doh_url)
        req.add_header("Accept", "application/dns-json")

        try:
            response = urlopen(req, timeout=5)
            response_text = response.read().decode("utf-8", "replace")
            dns_response = json.loads(response_text)
            if "Answer" not in dns_response:
                raise Exception("Invalid DNS response")
            # Ersten echten A-Record (type 1) aus der Answer-Liste nehmen statt stur [0]:
            # bei CNAME-Ketten kann die IP erst weiter hinten stehen, [0] waere dann der CNAME.
            ip_address = next((a["data"] for a in dns_response["Answer"] if a.get("type") == 1), None)
            if not ip_address:
                raise Exception("No A record in DNS answer")
            return ip_address
        except Exception as e:
            logger.error(' -> [requestHandler]: DNS query failed: %s' % e)
            return None

    def __setCachePath(self):
        cache = os.path.join(self._profilePath, 'htmlcache')
        if not os.path.exists(cache):
            os.makedirs(cache, exist_ok=True)  # gleiches Rennen wie bei cookies/, siehe __setCookiePath
        self._cachePath = cache

    def __readPersistentCache(self, url):
        h = hashlib.md5(url.encode('utf8')).hexdigest()
        cacheFile = os.path.join(self._cachePath, h)
        fileAge = self.getFileAge(cacheFile)
        if 0 < fileAge < self.cacheTime:
            # Vorbelegen: schlaegt das Lesen fehl, war `content` frueher gar
            # nicht zugewiesen — die Pruefung darunter warf dann einen
            # UnboundLocalError und der ganze Seitenaufruf brach ab.
            content = None
            try:
                with open(cacheFile, 'rb') as f:
                        content = f.read().decode('utf8')
            except Exception:
                logger.error(' -> [requestHandler]: Could not read Cache')
                # Beschaedigte Datei wegraeumen, sonst scheitert jeder weitere
                # Aufruf an derselben Stelle.
                try:
                    os.remove(cacheFile)
                except Exception:
                    pass
            if content:
                logger.info(' -> [requestHandler]: read html for %s from cache' % url)
                return content
        return None

    def __writePersistentCache(self, url, content):
        # Erst in eine eigene Datei, dann umbenennen: ein gleichzeitiger Leser (zweiter Aufruf, Widget, Thread)
        # sieht nie eine halbe Seite. Bis zum 02.11.2026 schrieb der Handler direkt in die Cache-Datei — nachgestellt
        # lasen drei Leser neben einem Schreiber 1.112 von 59.980 Mal eine halbe Seite.
        sTmp = ''
        try:
            h = hashlib.md5(url.encode('utf8')).hexdigest()
            sPfad = os.path.join(self._cachePath, h)
            sTmp = '%s.%d.%d.tmp' % (sPfad, os.getpid(), threading.get_ident())
            with open(sTmp, 'wb') as f:
                f.write(content.encode('utf8'))
            os.replace(sTmp, sPfad)
        except Exception:
            logger.error(' -> [requestHandler]: Could not write Cache')
            if sTmp:
                try:
                    os.remove(sTmp)
                except OSError:
                    pass

    def __writeVolatileCache(self, url, content):
        self._memCache.set(hashlib.md5(url.encode('utf8')).hexdigest(), content, self.cacheTime)

    def __readVolatileCache(self, url, cache_time):
        entry = self._memCache.get(hashlib.md5(url.encode('utf8')).hexdigest(), cache_time)
        if entry:
            logger.info('-> [requestHandler]: read html for %s from cache' % url)
        return entry

    @staticmethod
    def getFileAge(cacheFile):
        try:
            return time.time() - os.stat(cacheFile).st_mtime
        except Exception:
            return 0

    def dropCacheEntry(self):
        """Den Cache-Eintrag DIESER Adresse verwerfen (RAM-Cache und Datei).

        Fuer Antworten, die mit Status 200 kommen und trotzdem nicht der Inhalt
        sind — die Pruefseite eines vorgeschalteten WAF etwa. request() hat sie
        beim Eintreffen wie jede 200er-Antwort gecacht; bliebe sie liegen, bekaeme
        jeder weitere Aufruf die alte Pruefseite mit ihrer laengst verbrauchten
        Aufgabe aus dem Cache statt einer frischen vom Server. Der Aufrufer
        erkennt die Seite am Inhalt und ruft danach diese Methode.
        Nicht verwechseln mit clearCache(): das leert den GANZEN Cache.
        """
        sKey = hashlib.md5(self.getRequestUri().encode('utf8')).hexdigest()
        if self.isMemoryCacheActive:
            # cCache kennt kein Loeschen; ein leerer Wert zaehlt beim Lesen als
            # Fehltreffer (request() prueft `if sContent`) und wird vom naechsten
            # Abruf ueberschrieben.
            self._memCache.set(sKey, '', self.cacheTime)
        try:
            os.remove(os.path.join(self._cachePath, sKey))
        except OSError:
            pass

    def clearCache(self):
        # Laeuft beim Kodi-Start aus dem Dienst (service.delHtmlCache), ohne Meldung. Den Aufruf von Hand
        # (function=clearCache, mit der Einblendung „HTML Cache geleert") baute keine Stelle im Addon; er ist
        # seit dem 11.11.2026 raus.
        if self.isMemoryCacheActive:
            self._memCache.clear()

        # Persistenten Cache aufraeumen: NUR abgelaufene Dateien loeschen.
        # Der Lesepfad prueft ohnehin `0 < fileAge < cacheTime`, abgelaufene Eintraege
        # werden also nie benutzt — der Wisch dient allein dem Plattenplatz. Frische
        # Dateien zu behalten spart nach dem Aufraeumen den kompletten Kaltstart:
        # sonst muss jeder erste Aufruf des Tages ins Netz. Grenze = die Einstellung
        # „HTML Cache in Stunden" (seit dem 05.11.2026 setzt keine Seite mehr eigene
        # Stunden). Aelteres kann nie mehr ein Treffer sein.
        maxAge = int(cConfig().getSetting('cacheTime', 1)) * 3600
        cutoff = time.time() - maxAge
        removed = 0
        try:
            for entry in os.scandir(self._cachePath):
                try:
                    if entry.is_file() and entry.stat().st_mtime < cutoff:
                        os.remove(entry.path)
                        removed += 1
                except OSError:
                    pass
        except OSError as e:
            logger.error(' -> [requestHandler]: clearCache failed: %s' % e)
        logger.info(' -> [requestHandler]: cache cleanup, %d abgelaufene Dateien entfernt' % removed)
