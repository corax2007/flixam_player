# -*- coding: utf-8 -*-
import os
import sys
import socket
import json
import base64
import subprocess
import re
import threading
from datetime import date, timedelta
from urllib.parse import urlencode, quote, quote_plus, unquote_plus, urlsplit, parse_qsl, urljoin

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# load .env
_env_path = os.path.join(BASE_DIR, ".env")
if os.path.exists(_env_path):
    for _line in open(_env_path):
        _line=_line.strip()
        if _line and "=" in _line and not _line.startswith("#"):
            _k,_v=_line.split("=",1)
            os.environ.setdefault(_k.strip(), _v.strip())
ADDONS_DIR = os.path.join(BASE_DIR, "addons")
KODI_MOCKS = os.path.join(BASE_DIR, "kodi_mocks")
RESOLVEURL_LIB = os.path.join(ADDONS_DIR, "script.module.resolveurl", "lib")
KODI_SIX_LIBS = os.path.join(ADDONS_DIR, "script.module.kodi-six", "libs")
INFOTAGGER_LIB = os.path.join(ADDONS_DIR, "script.module.infotagger", "resources", "modules")
SIMPLEJSON_LIB = os.path.join(ADDONS_DIR, "script.module.simplejson", "lib")
REQUESTS_LIB = os.path.join(ADDONS_DIR, "script.module.requests", "lib")

# 1. sys.path setup
paths = [KODI_MOCKS, RESOLVEURL_LIB, KODI_SIX_LIBS, INFOTAGGER_LIB, SIMPLEJSON_LIB, REQUESTS_LIB]
for addon in ("plugin.video.xstream", "plugin.video.xship"):
    paths.append(os.path.join(ADDONS_DIR, addon))
for p in reversed(paths):
    if p not in sys.path:
        sys.path.insert(0, p)

# Optional VPN proxy (no longer fail-closed global proxy)
import socks
from contextlib import contextmanager

PROXY_HOST = "127.0.0.1"
PROXY_PORT = 1080
VPN_ENABLED = os.environ.get("VPN_ENABLED", "false").strip().lower() in ("1", "true", "yes", "on")
TMDB_API_KEY = os.environ.get("TMDB_API_KEY", "").strip()


def is_proxy_reachable() -> bool:
    try:
        socket.create_connection((PROXY_HOST, PROXY_PORT), timeout=2).close()
        return True
    except Exception:
        return False


def get_proxies() -> dict | None:
    if not VPN_ENABLED:
        return None
    if not is_proxy_reachable():
        return None
    return {
        "http": f"socks5h://{PROXY_HOST}:{PROXY_PORT}",
        "https": f"socks5h://{PROXY_HOST}:{PROXY_PORT}",
    }


@contextmanager
def _vpn_proxy_context():
    if not VPN_ENABLED:
        yield None
        return
    if not is_proxy_reachable():
        yield None
        return
    proxy = get_proxies()
    old_socket = socket.socket
    old_default = socks.get_default_proxy()
    socket.socket = socks.socksocket
    socks.set_default_proxy(socks.SOCKS5, PROXY_HOST, PROXY_PORT, True, None, None)
    try:
        yield proxy
    finally:
        socket.socket = old_socket
        socks.set_default_proxy(old_default[0], old_default[1], old_default[2], old_default[3], old_default[4], old_default[5])


import requests
import urllib.request

# urllib runs without proxy unless VPN context sets it.
# Wichtig: install_opener erwartet einen OpenerDirector, keinen Handler -
# ein installierter ProxyHandler haette kein .open() und wuerde jeden
# urlopen()-Aufruf der Addons mit AttributeError abbrechen.
urllib.request.install_opener(urllib.request.build_opener(urllib.request.ProxyHandler({})))

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse, Response
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

app = FastAPI(title="flixam_player backend")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# --- LAN-Auto-Discovery (UDP) ---------------------------------------------
# Der Fire-TV-Client schickt einen Broadcast; das Backend antwortet mit
# seiner LAN-IP, damit in der App keine IP manuell eingetragen werden muss.
DISCOVERY_PORT = int(os.environ.get("FLIXAM_DISCOVERY_PORT", "9000"))
BACKEND_PORT = int(os.environ.get("FLIXAM_BACKEND_PORT", "8000"))


def _lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def _discovery_loop():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.bind(("0.0.0.0", DISCOVERY_PORT))
    except Exception as exc:
        print(f"[discovery] Port {DISCOVERY_PORT} nicht verfuegbar: {exc}")
        return
    print(f"[discovery] listening on UDP {DISCOVERY_PORT}")
    while True:
        try:
            data, addr = sock.recvfrom(1024)
            if b"FLIXAM_DISCOVER" in data:
                reply = f"FLIXAM_BACKEND http://{_lan_ip()}:{BACKEND_PORT}".encode()
                sock.sendto(reply, addr)
        except Exception:
            continue


threading.Thread(target=_discovery_loop, daemon=True, name="flixam-discovery").start()


import re as _re
_TMDB_CACHE = {}
_GENRE_CACHE = {}
_HOME_CACHE = {"data": None, "time": 0.0}

def _clean_title(title: str) -> str:
    if not title:
        return ""
    t = title
    # Addons haengen die Site in `[I]...[/I]` an - das gehoert nicht zum Titel.
    t = _re.sub(r"\[I\].*?\[/I\]", " ", t, flags=_re.I | _re.S)
    t = _re.sub(r"\([^)]*\)", " ", t)
    t = _re.sub(r"\[[^]]*\]", " ", t)
    t = _re.sub(r"Staffel\s*\d+", " ", t, flags=_re.I)
    t = _re.sub(r"S\d+E?\d*", " ", t, flags=_re.I)
    t = _re.sub(r"\s+", " ", t).strip()
    # remove common hoster suffixes
    for suf in ["Voe", "Streamtape", "Doodstream", "Vidoza"]:
        t = t.replace(suf, "").strip()
    return t

def _tmdb_search(title: str):
    if not TMDB_API_KEY:
        return None
    base = _clean_title(title)
    year_match = re.search(r"\b(?:19|20)\d{2}\b", str(title or ""))
    year = year_match.group(0) if year_match else ""
    key = f"{base}|{year}" if year else base
    if not base:
        return None
    if key in _TMDB_CACHE:
        return _TMDB_CACHE[key]
    try:
        with _vpn_proxy_context() as proxies:
            r = requests.get(
                "https://api.themoviedb.org/3/search/multi",
                params={"api_key": TMDB_API_KEY, "language": "de-DE", "query": base, "page": 1},
                proxies=proxies,
                timeout=10,
            )
        r.raise_for_status()
        results = (r.json() or {}).get("results", []) or []
        pool = results
        if year:
            exact = [
                x for x in results
                if str(x.get("release_date") or x.get("first_air_date") or "").startswith(year)
            ]
            if not exact:
                # search/multi ignoriert Jahrzahlen -> gezielt nach Jahr suchen
                movie = _tmdb_get("search/movie", {
                    "query": base, "language": "de-DE",
                    "primary_release_year": year, "page": 1,
                })
                tv = _tmdb_get("search/tv", {
                    "query": base, "language": "de-DE",
                    "first_air_date_year": year, "page": 1,
                })
                exact = ((movie or {}).get("results") or []) + ((tv or {}).get("results") or [])
            if exact:
                pool = exact
        chosen = None
        for res in pool:
            if res.get("media_type") in ("movie", "tv") or res.get("title") or res.get("name"):
                chosen = res
                break
        if not chosen and pool:
            chosen = pool[0]
        _TMDB_CACHE[key] = chosen
        return chosen
    except Exception:
        _TMDB_CACHE[key] = None
        return None


def _tmdb_get(path: str, params: dict):
    """Kleiner TMDB-GET-Helper mit VPN-Kontext und Fehlertoleranz."""
    if not TMDB_API_KEY:
        return None
    try:
        p = dict(params or {})
        p["api_key"] = TMDB_API_KEY
        with _vpn_proxy_context() as proxies:
            r = requests.get(
                f"https://api.themoviedb.org/3/{path.lstrip('/')}",
                params=p, proxies=proxies, timeout=12,
            )
        r.raise_for_status()
        return r.json()
    except Exception:
        return None


def _genre_names(type_: str = "movie"):
    if type_ not in _GENRE_CACHE:
        data = _tmdb_get(f"genre/{type_}/list", {"language": "de-DE"})
        genres = data.get("genres", []) if data else []
        _GENRE_CACHE[type_] = {int(g["id"]): g.get("name", "") for g in genres if g.get("id")}
    return _GENRE_CACHE[type_]


def _art_url(value: str) -> str:
    """Lokale Addon-Bilder als HTTP-URL bereitstellen (Flutter lädt via network)."""
    if not value:
        return ""
    v = str(value).strip()
    if v.startswith(("http://", "https://", "data:")):
        return v
    try:
        if os.path.isfile(v):
            rel = os.path.relpath(os.path.realpath(v), os.path.realpath(ADDONS_DIR))
            if not rel.startswith(".."):
                return "http://127.0.0.1:8000/art/" + quote(rel.replace(os.sep, "/"))
    except Exception:
        pass
    return v


@app.get("/art/proxy")
def art_proxy(url: str = Query("")):
    """Externe Cover mit Browser-Headers laden (Hotlink-Schutz umgehen)."""
    if not url.startswith(("http://", "https://")):
        return Response(status_code=404)
    try:
        parts = urlsplit(url)
        referer = f"{parts.scheme}://{parts.netloc}/"
        r = requests.get(
            url,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/148.0 Safari/537.36"
                ),
                "Referer": referer,
                "Accept": "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            },
            timeout=15,
        )
        if r.status_code != 200 or not r.content:
            return Response(status_code=404)
        return Response(
            content=r.content,
            media_type=r.headers.get("content-type") or "image/jpeg",
        )
    except Exception:
        return Response(status_code=404)


@app.get("/art/{path:path}")
def serve_art(path: str):
    base = os.path.realpath(ADDONS_DIR)
    target = os.path.realpath(os.path.join(base, path))
    if not target.startswith(base + os.sep) or not os.path.isfile(target):
        return {"detail": "not found"}
    return FileResponse(target)


def _tmdb_to_item(res: dict, media_type: str | None = None):
    """TMDB-Ergebnis in ein Flixam-Item mit playbarer Such-URL umwandeln."""
    if not isinstance(res, dict):
        return None
    mt = media_type or res.get("media_type") or ("tv" if res.get("name") else "movie")
    title = res.get("title") or res.get("name") or ""
    date = res.get("release_date") or res.get("first_air_date") or ""
    poster = res.get("poster_path")
    backdrop = res.get("backdrop_path")
    ids = res.get("genre_ids") or []
    names = _genre_names(mt)
    genres = [names[int(i)] for i in ids if int(i) in names and names[int(i)]]
    try:
        rating = round(float(res.get("vote_average")), 1)
    except (TypeError, ValueError):
        rating = None
    return {
        "id": res.get("id"),
        "title": title,
        "url": f"plugin://flixam/search/{quote_plus(title)}",
        "isFolder": False,
        "poster_url": ("https://image.tmdb.org/t/p/w500" + poster) if poster else "",
        "backdrop_url": ("https://image.tmdb.org/t/p/w1280" + backdrop) if backdrop else "",
        "rating": rating,
        "year": date.split("-")[0] if date else None,
        "release_date": date or None,
        "overview": res.get("overview") or "",
        "media_type": mt,
        "genres": genres,
        "original_language": res.get("original_language") or "",
    }


def _enrich_items(items, max_enrich: int = 40):
    if not isinstance(items, list):
        return items
    out = []
    enriched = 0
    for it in items:
        if not isinstance(it, dict):
            out.append(it)
            continue
        url = str(it.get("url", "") or "")
        title = str(it.get("title", "") or "")
        # Episoden-/Ordner-Titel sind keine Film-Titel -> keine TMDB-Suche
        # (sonst liefert die Suche falsche Poster, z.B. "S01E01" -> ein beliebiger Film).
        if re.match(r"^(S\d{1,2}E\d{1,3}\b|String_\d+\b)", title, re.I):
            # Die Addons liefern echte Episoden-Stills in 'art' (TMDB-Bilder).
            art = it.get("art", {}) or {}
            it = dict(it)
            it["poster_url"] = _art_url(art.get("thumb") or art.get("poster") or art.get("icon") or "")
            it["backdrop_url"] = _art_url(art.get("fanart") or art.get("landscape") or it["poster_url"])
            out.append(it)
            continue
        # Ordner (Sites, Kategorien): Cover aus den Addon-Art-Daten nehmen,
        # keine TMDB-Suche (sonst falsche Film-Poster fuer z.B. "Filme").
        if it.get("isFolder"):
            art = it.get("art", {}) or {}
            it = dict(it)
            it["poster_url"] = _art_url(art.get("thumb") or art.get("poster") or art.get("icon") or "")
            it["backdrop_url"] = _art_url(art.get("fanart") or art.get("landscape") or it["poster_url"])
            it["genres"] = []
            out.append(it)
            continue
        # skip direct hoster links
        if url.startswith("http") and "plugin://" not in url:
            out.append(it)
            continue
        # enrich (nur die ersten Eintraege - TMDB limitiert die Anfragen)
        meta = _tmdb_search(title) if enriched < max_enrich else None
        if enriched < max_enrich:
            enriched += 1
        art = it.get("art", {}) or {}
        poster = _art_url(art.get("poster") or art.get("thumb") or "")
        fanart = _art_url(art.get("fanart") or art.get("landscape") or "")
        if meta:
            poster_path = meta.get("poster_path")
            backdrop_path = meta.get("backdrop_path")
            if poster_path:
                poster = "https://image.tmdb.org/t/p/w500" + poster_path
            if backdrop_path:
                fanart = "https://image.tmdb.org/t/p/w1280" + backdrop_path
            vote = meta.get("vote_average")
            try:
                rating = round(float(vote), 1)
            except (TypeError, ValueError):
                rating = None
            date = meta.get("release_date") or meta.get("first_air_date") or ""
            year = date.split("-")[0] if date else None
            overview = meta.get("overview") or ""
            media_type = meta.get("media_type")
            if media_type not in ("movie", "tv"):
                media_type = "movie" if meta.get("title") else "tv"
            genre_list = meta.get("genres") or []
            if genre_list:
                genres = [g.get("name", "") for g in genre_list if g.get("name")]
            else:
                names = _genre_names(media_type)
                genres = [names[i] for i in (meta.get("genre_ids") or []) if i in names]
        else:
            rating = None
            year = None
            overview = ""
            media_type = None
            genres = []
        it = dict(it)
        it["poster_url"] = poster
        it["backdrop_url"] = fanart
        it["rating"] = rating
        it["year"] = year
        it["overview"] = overview
        it["media_type"] = media_type
        it["genres"] = genres
        out.append(it)
    return out


def run_addon(addon_id: str, third_arg: str):
    import xbmc
    import xbmcaddon
    import xbmcplugin
    xbmcplugin.reset()
    xbmc.reset_playback()
    old_current_addon = xbmcaddon.current_addon()
    xbmcaddon.set_current_addon(addon_id)
    plugin_url = f"plugin://{addon_id}/"
    addon_dir = os.path.join(ADDONS_DIR, addon_id)
    default_py = os.path.join(addon_dir, "default.py")
    old_argv = list(sys.argv)
    old_path = list(sys.path)
    # isolate addon package: remove cached modules from previous addon runs
    for key in list(sys.modules.keys()):
        if key == "resources" or key.startswith("resources.") or key == "service" or key.startswith("addon") or key == "scrapers" or key.startswith("scrapers."):
            del sys.modules[key]
    sys.path.insert(0, addon_dir)
    sys.argv = [plugin_url, "1", third_arg]
    ns = {"__name__": "__main__", "__file__": default_py}
    with open(default_py, "r", encoding="utf-8") as f:
        code = f.read()
    try:
        exec(compile(code, default_py, "exec"), ns)
    except xbmc.PlaybackDone:
        # Stream-URL wurde erfasst - der Player wartet in Kodi auf das Ende
        # der Wiedergabe, hier gibt es nichts abzuwarten.
        pass
    finally:
        sys.argv = old_argv
        sys.path = old_path
        xbmcaddon.set_current_addon(old_current_addon)
    if not xbmcplugin.RESOLVED_URL and xbmc.PLAYBACK_URL:
        xbmcplugin.RESOLVED_URL = xbmc.PLAYBACK_URL
    items = list(xbmcplugin.DIRECTORY_ITEMS)
    return items


def _has_wg_conf() -> bool:
    if not os.path.exists(VPN_CONF):
        return False
    try:
        txt = open(VPN_CONF).read()
    except Exception:
        return False
    return "[Interface]" in txt and "[Peer]" in txt and "PrivateKey" in txt


@app.get("/vpn/status")
def vpn_status():
    has_config = _has_wg_conf()
    connected = False
    ip = ""
    if VPN_ENABLED:
        proxy = get_proxies()
        if proxy is not None:
            try:
                r = requests.get("https://api.ipify.org?format=json", proxies=proxy, timeout=10)
                r.raise_for_status()
                data = r.json()
                connected = True
                ip = data.get("ip", "")
            except Exception:
                connected = False
                ip = ""
    return {"enabled": VPN_ENABLED, "connected": connected, "ip": ip, "has_config": has_config}


@app.post("/vpn/toggle")
def vpn_toggle(body: dict):
    global VPN_ENABLED
    enabled = body.get("enabled") if isinstance(body, dict) else body
    if isinstance(enabled, str):
        enabled = enabled.strip().lower() in ("1", "true", "yes", "on")
    VPN_ENABLED = bool(enabled)
    return vpn_status()


_NEXT_PAGE_RE = re.compile(r"(Nächste Seite|Next page|Weiter|String_30279)", re.I)


def _collect_pages(addon_id: str, first_url: str, max_pages: int = 5):
    """Folgt 'Nächste Seite'-Ordnern und gibt alle Eintraege zurueck."""
    result = []
    seen_items = set()
    visited_pages = set()
    url = first_url
    for _ in range(max_pages):
        if url in visited_pages:
            break
        visited_pages.add(url)
        try:
            page = run_addon(addon_id, url)
        except Exception:
            break
        next_url = ""
        for it in page:
            title = str(it.get("title") or "")
            item_url = str(it.get("url") or "")
            if _NEXT_PAGE_RE.search(title) and item_url.startswith("plugin://"):
                if not next_url:
                    next_url = item_url
                continue
            if item_url and item_url in seen_items:
                continue
            seen_items.add(item_url)
            result.append(it)
        url = next_url
        if not url:
            break
    return result


ADDON_CATALOG_SITES = [
    "animetoast", "aniworld", "burningseries", "einschalten", "filmo",
    "filmpalast", "hdfilme", "internetarchive", "kellerkino", "kinoger",
    "megakino", "moflix-stream", "movie2k", "netzkino", "serienstream",
    "streamcloud",
]


_EPG_SOURCES = [
    "https://open-epg.com/files/germany.xml.gz",
    "https://epgshare01.online/epgshare01/epg_ripper_DE1.xml.gz",
]
_EPG_CACHE_PATH = os.path.join(
    os.path.dirname(BASE_DIR), ".flixam_epg_cache.json"
)


def _epg_norm(value: str) -> str:
    import unicodedata
    v = str(value or "").lower()
    v = re.sub(r"\[i\].*?\[/i\]", "", v)
    v = "".join(
        c for c in unicodedata.normalize("NFKD", v)
        if not unicodedata.combining(c)
    )
    v = v.replace("ae", "a").replace("oe", "o").replace("ue", "u").replace("ss", "s")
    v = re.sub(r"\.(de|at|ch|com|info|tv)$", "", v)
    v = re.sub(r"\b(hd|sd|raw|backup|store)\b", "", v)
    return re.sub(r"[^a-z0-9]", "", v)


def _epg_load() -> dict:
    """EPG-Dateien laden und auf einen Tag cachen."""
    import gzip
    import time as _time
    import xml.etree.ElementTree as ET
    try:
        if os.path.isfile(_EPG_CACHE_PATH):
            data = json.load(open(_EPG_CACHE_PATH, "r", encoding="utf-8"))
            if _time.time() - float(data.get("time") or 0) < 20 * 3600:
                return data.get("channels") or {}
    except Exception:
        pass

    channels = {}
    for url in _EPG_SOURCES:
        try:
            r = requests.get(url, timeout=90)
            if r.status_code != 200:
                continue
            xml_data = gzip.decompress(r.content) if url.endswith(".gz") else r.content
            root = ET.fromstring(xml_data)
            names = {}
            cid_to_name = {}
            cid_to_icon = {}
            for ch in root.findall("channel"):
                cid = str(ch.get("id") or "")
                display = []
                for dn in ch.findall("display-name"):
                    t = str(dn.text or "").strip()
                    if t:
                        display.append(t)
                if not display:
                    continue
                cid_to_name[cid] = display[0]
                icon_el = ch.find("icon")
                if icon_el is not None:
                    cid_to_icon[cid] = str(icon_el.get("src") or "")
                for name in display:
                    key = _epg_norm(name)
                    if key:
                        names[key] = display[0]
            programmes = {}
            for pr in root.findall("programme"):
                cid = str(pr.get("channel") or "")
                if cid not in cid_to_name:
                    continue
                title_el = pr.find("title")
                title = str(title_el.text or "").strip() if title_el is not None else ""
                if not title:
                    continue
                desc_el = pr.find("desc")
                desc = str(desc_el.text or "").strip() if desc_el is not None else ""
                start = str(pr.get("start") or "")
                stop = str(pr.get("stop") or "")
                programmes.setdefault(cid_to_name[cid], []).append((start, stop, title, desc, cid_to_icon.get(cid, "")))
            for name, entries in programmes.items():
                channels.setdefault(_epg_norm(name), []).extend(entries)
        except Exception:
            continue
    try:
        json.dump(
            {"time": _time.time(), "channels": channels},
            open(_EPG_CACHE_PATH, "w", encoding="utf-8"),
        )
    except Exception:
        pass
    return channels


@app.get("/tmdb/resolve-title")
def tmdb_resolve_title(title: str = Query("")):
    """Titel ueber die TMDB-Suche wiederauffindbar machen (Cover/URL)."""
    if not title.strip():
        return {}
    cache_key = f"resolve-title|{title}"
    if cache_key in _TMDB_CACHE:
        return _TMDB_CACHE[cache_key]
    # Quell-Tags und Jahresangaben aus dem Titel entfernen.
    query = re.sub(r"\[I\].*?\[/I\]", "", title)
    query = re.sub(r"\(\d{4}\)\s*$", "", query).strip()
    query = query.replace("?", "").strip()
    out = {}
    try:
        data = _tmdb_get("search/multi", {"query": query}) or {}
        for r in (data.get("results") or []):
            if r.get("media_type") not in ("movie", "tv"):
                continue
            item = _tmdb_to_item(
                r, "movie" if r.get("media_type") == "movie" else "tv"
            )
            if item:
                out = item
                break
    except Exception:
        pass
    _TMDB_CACHE[cache_key] = out
    return out


@app.get("/vavoo/program/info")
def vavoo_program_info(title: str = Query("")):
    """TMDB-Metadaten zu einer laufenden Sendung (nur Anzeige, keine EPG)."""
    if not title.strip():
        return {}
    cache_key = f"vavoo|program|{title}"
    if cache_key in _TMDB_CACHE:
        return _TMDB_CACHE[cache_key]
    out = {}
    try:
        search = _tmdb_get("search/multi", {"query": title.strip()}) or {}
        pick = None
        for r in (search.get("results") or []):
            if r.get("media_type") in ("movie", "tv") and r.get("backdrop_path"):
                pick = r
                break
        if pick:
            mt = pick["media_type"]
            mid = str(pick.get("id") or "")
            detail = _tmdb_get(f"{mt}/{mid}", {}) or {}
            genres = [
                g.get("name") for g in (detail.get("genres") or [])
                if g.get("name")
            ]
            rating = detail.get("vote_average")
            fsk = ""
            try:
                if mt == "movie":
                    rel = _tmdb_get(f"movie/{mid}/release_dates", {}) or {}
                    for country in (rel.get("results") or []):
                        if country.get("iso_3166_1") == "DE":
                            for rd in (country.get("release_dates") or []):
                                cert = str(rd.get("certification") or "")
                                if cert:
                                    fsk = cert
                                    break
                else:
                    cr = _tmdb_get(f"tv/{mid}/content_ratings", {}) or {}
                    for country in (cr.get("results") or []):
                        if country.get("iso_3166_1") == "DE":
                            fsk = str(country.get("rating") or "")
                            break
            except Exception:
                pass
            out = {
                "backdrop_url": (
                    "https://image.tmdb.org/t/p/w780" + pick["backdrop_path"]
                ),
                "poster_url": (
                    "https://image.tmdb.org/t/p/w500" + pick["poster_path"]
                    if pick.get("poster_path") else ""
                ),
                "rating": round(float(rating), 1) if rating else None,
                "genres": genres[:3],
                "overview": str(detail.get("overview") or "")[:400],
                "year": str(pick.get("release_date") or pick.get("first_air_date") or "")[:4],
                "fsk": fsk,
            }
    except Exception:
        pass
    _TMDB_CACHE[cache_key] = out
    return out


@app.get("/vavoo/epg")
def vavoo_epg():
    """Laufendes Programm für die Vavoo-Sender (Open-EPG / epgshare01)."""
    from datetime import datetime
    channels = _epg_load()
    if not channels:
        return {"programs": {}, "count": 0}
    vavoo = (vavoo_channels().get("channels") or [])
    now = datetime.now()
    out = {}
    for ch in vavoo:
        title = ch.get("title") or ""
        key = _epg_norm(title)
        entries = channels.get(key)
        if not entries:
            # Teilweise Uebereinstimmung (z. B. "Sky Bundesliga 1 HD (Backup)")
            if len(key) >= 6:
                for k, v in channels.items():
                    if (len(k) >= 6 and (k in key or key in k)):
                        entries = v
                        break
        if not entries:
            continue
        current = None
        idx = -1
        for i, entry in enumerate(entries):
            start, stop, name, desc, icon = entry
            try:
                s = datetime.strptime(start[:14], "%Y%m%d%H%M%S")
                e = datetime.strptime(stop[:14], "%Y%m%d%H%M%S")
            except (TypeError, ValueError):
                continue
            if s <= now < e:
                current = {
                    "title": name,
                    "start": s.strftime("%H:%M"),
                    "end": e.strftime("%H:%M"),
                    "description": desc[:300],
                    "icon": icon,
                    "progress": max(
                        0.0,
                        min(1.0, (now - s).total_seconds()
                            / max(1.0, (e - s).total_seconds())),
                    ),
                }
                idx = i
                break
        if current:
            upcoming = []
            for entry in entries[idx + 1: idx + 4]:
                st, sp, nm, ds, ic = entry
                upcoming.append({
                    "title": nm,
                    "start": str(st)[8:10] + ":" + str(st)[10:12],
                    "end": str(sp)[8:10] + ":" + str(sp)[10:12],
                })
            current["upcoming"] = upcoming
            out[title] = current
    return {"programs": out, "count": len(out)}


@app.get("/vavoo/channels")
def vavoo_channels():
    """Live-TV-Senderliste aus dem Vavoo-Addon (DE)."""
    cache_key = "vavoo|channels"
    if cache_key in _TMDB_CACHE:
        return {"channels": _TMDB_CACHE[cache_key]}
    try:
        items = run_addon(
            "plugin.video.xstream",
            "plugin://plugin.video.xstream/?site=vavootv",
        )
    except Exception:
        return {"channels": []}
    out = []
    seen = set()
    for it in items:
        title = re.sub(r"\[COLOR[^\]]*\]|\[/COLOR\]", "",
                       str(it.get("title") or "")).strip()
        url = str(it.get("url") or "")
        if not title or not url or "refresh_channels" in url:
            continue
        if title in seen:
            continue
        seen.add(title)
        out.append({"title": title, "url": url})
    _TMDB_CACHE[cache_key] = out
    return {"channels": out, "count": len(out)}


@app.get("/addon/catalog/sites")
def addon_catalog_sites():
    """Alle xStream-Sites mit echtem Bestands-Katalog."""
    return {"sites": ADDON_CATALOG_SITES}


@app.get("/addon/catalog")
def addon_catalog(site: str = Query(""), type: str = Query("movie"),
                  pages: int = 15):
    """Bestands-Katalog einer Site: alle Filme oder Serien, die dort liegen."""
    if site not in ADDON_CATALOG_SITES:
        return {"items": []}
    cache_key = f"addon|catalog|{site}|{type}|{pages}"
    if cache_key in _TMDB_CACHE:
        return {"items": _TMDB_CACHE[cache_key]}
    addon_id = "plugin.video.xstream"
    base = f"plugin://{addon_id}/"
    try:
        root = run_addon(addon_id, base + f"?site={quote(site)}")
        wanted = ("filme", "movies", "alle filme") if type == "movie" \
            else ("serien", "shows", "tv", "alle serien")
        menu = next(
            (i for i in root
             if any(w in str(i.get("title") or "").lower() for w in wanted)),
            None,
        )
        if not menu:
            menu = next(
                (i for i in root
                 if any(w in str(i.get("title") or "").lower()
                        for w in ("startseite", "home", "neu"))),
                None,
            )
        start_url = ""
        if menu:
            menu_url = str(menu.get("url") or "")
            level = run_addon(addon_id, menu_url)
            has_entries = any(
                "function=showHosters" in str(i.get("url") or "")
                or "function=showSeasons" in str(i.get("url") or "")
                for i in level
            )
            if has_entries:
                start_url = menu_url
            else:
                target = next(
                    (i for i in level
                     if "alle" in str(i.get("title") or "").lower()
                     or "all" in str(i.get("title") or "").lower()),
                    level[0] if level else None,
                )
                start_url = str((target or {}).get("url") or "")
        elif root:
            start_url = str(root[0].get("url") or "")
        if not start_url:
            return {"items": []}
        found = _collect_pages(addon_id, start_url,
                               max_pages=max(1, min(pages, 30)))
    except Exception:
        return {"items": []}

    out = []
    seen = set()
    for it in found:
        item_url = str(it.get("url") or "")
        if not ("function=showHosters" in item_url
                or "function=showSeasons" in item_url
                or item_url.startswith(("http://", "https://"))):
            continue
        title = re.sub(r"\[I\].*?\[/I\]", "", str(it.get("title") or "")).strip()
        title = re.sub(r"\s*\(\d{4}\)\s*$", "", title).strip()
        if not title or title.lower().startswith("nächste Seite"):
            continue
        key = re.sub(r"[^a-z0-9]", "", title.lower())
        if not key or key in seen:
            continue
        seen.add(key)
        year = str(it.get("year") or it.get("sYear") or "") or None
        art = it.get("art") if isinstance(it.get("art"), dict) else {}
        poster = str(art.get("thumb") or art.get("poster")
                     or it.get("thumb") or it.get("trumb") or "")
        if not poster and "trumb=" in item_url:
            poster = unquote_plus(item_url.split("trumb=", 1)[1].split("&", 1)[0])
        out.append({
            "title": title,
            "year": year,
            "poster_url": poster,
            "url": str(it.get("url") or ""),
            "media_type": type,
            "source": site,
        })
    # Einige Quellen (z. B. filmpalast.to) sind vom Host nicht erreichbar oder
    # blocken Hotlinks -> TMDB-Poster als Fallback.
    from concurrent.futures import ThreadPoolExecutor

    def tmdb_poster(item):
        try:
            data = _tmdb_get("search/multi", {"query": item["title"]}) or {}
            for r in (data.get("results") or []):
                path = r.get("poster_path") or r.get("backdrop_path")
                if path:
                    size = "w500" if r.get("poster_path") else "w780"
                    return "https://image.tmdb.org/t/p/" + size + path
        except Exception:
            pass
        return ""

    with ThreadPoolExecutor(max_workers=8) as pool:
        posters = list(pool.map(tmdb_poster, out))
    for item, poster in zip(out, posters):
        if poster:
            item["poster_url"] = poster

    _TMDB_CACHE[cache_key] = out
    return {"items": out, "count": len(out)}


@app.get("/addon/browse")
def addon_browse(addon: str = Query("xstream"), url: str = Query(None), query: str = Query(None)):
    addon_id = "plugin.video.xstream" if addon == "xstream" else "plugin.video.xship"
    plugin_url = f"plugin://{addon_id}/"
    if url:
        third = url
    else:
        third = plugin_url
        if query:
            if "?" in query:
                third = query
            else:
                third = f"{plugin_url}?{query}"
    items = _collect_pages(addon_id, third)
    items = _enrich_items(items)
    return {"items": items, "count": len(items)}


@app.get("/addon/search")
def addon_search(addon: str = Query("xstream"), q: str = Query(""),
                 year: str = Query(None), genre: str = Query(None),
                 type: str = Query(None)):
    addon_id = "plugin.video.xstream" if addon == "xstream" else "plugin.video.xship"
    plugin_url = f"plugin://{addon_id}/"
    if addon == "xstream":
        third = f"{plugin_url}?site=globalSearch&searchterm={quote(q)}"
    else:
        third = f"{plugin_url}?action=movies&query={quote(q)}&page=1"
    items = run_addon(addon_id, third)
    items = _enrich_items(items)
    total = len(items)

    # Filter: Jahr / Genre / Medientyp (basierend auf TMDB-Metadaten)
    genre_name = (genre or "").strip()
    if genre_name.isdigit():
        for type_key in ("movie", "tv"):
            genre_name = _genre_names(type_key).get(int(genre_name), genre_name)
            if genre_name not in ("", str(genre)):
                break
    wanted_type = (type or "").strip().lower()
    if wanted_type in ("film", "filme"):
        wanted_type = "movie"
    elif wanted_type in ("serie", "serien"):
        wanted_type = "tv"
    wanted_year = str(year).strip() if year else ""

    if wanted_year or genre_name or wanted_type in ("movie", "tv"):
        filtered = []
        for it in items:
            if wanted_type and it.get("media_type") != wanted_type:
                continue
            if wanted_year and str(it.get("year") or "") != wanted_year:
                # 1 Jahr Toleranz (z.B. Adding steigt 2022/2023)
                try:
                    if abs(int(str(it.get("year"))) - int(wanted_year)) > 1:
                        continue
                except (TypeError, ValueError):
                    continue
            if genre_name and genre_name.lower() not in [
                str(g).lower() for g in (it.get("genres") or [])
            ]:
                continue
            filtered.append(it)
        items = filtered
    return {"items": items, "query": q, "total": total}


@app.get("/tmdb/genres")
def tmdb_genres(type: str = Query("movie")):
    """Genre-Liste fuer die Suchfilter (TMDB, deutsch)."""
    type_ = "tv" if str(type).lower() in ("tv", "serie", "serien") else "movie"
    names = _genre_names(type_)
    return {
        "genres": [
            {"id": k, "name": v}
            for k, v in sorted(names.items(), key=lambda kv: kv[1]) if v
        ]
    }


@app.get("/tmdb/details")
def tmdb_details(title: str = Query(""), year: str = Query(None), type: str = Query(None)):
    """Vollstaendige TMDB-Details fuer ein Item (Cast, FSK, Laufzeit ...)."""
    if not title or not TMDB_API_KEY:
        return {}
    cache_key = f"details|{_clean_title(title)}|{year or ''}|{type or ''}"
    if cache_key in _TMDB_CACHE:
        return _TMDB_CACHE[cache_key]
    search_title = f"{title} ({year})" if year and str(year) not in title else title
    base = _tmdb_search(search_title)
    if not base or not base.get("id"):
        return {}
    mt = "tv" if type in ("tv", "serie", "serien") else (
        "movie" if type in ("movie", "film", "filme") else
        (base.get("media_type") if base.get("media_type") in ("movie", "tv")
         else ("tv" if base.get("name") else "movie"))
    )
    data = _tmdb_get(
        f"{mt}/{base['id']}",
        {
            "language": "de-DE",
            "append_to_response": "credits,release_dates,content_ratings,videos",
        },
    ) or {}

    def img(path, size="w500"):
        return f"https://image.tmdb.org/t/p/{size}{path}" if path else ""

    credits = data.get("credits") or {}
    cast = [
        {
            "id": c.get("id"),
            "name": c.get("name") or "",
            "character": c.get("character") or "",
            "profile_url": img(c.get("profile_path"), "w185"),
        }
        for c in (credits.get("cast") or [])[:20]
    ]
    crew = credits.get("crew") or []
    directors = [c.get("name") for c in crew if c.get("job") == "Director" and c.get("name")]
    writers = [
        c.get("name") for c in crew
        if c.get("job") in ("Writer", "Screenplay", "Novel") and c.get("name")
    ]

    # FSK / Jugendfreigabe (deutsche Freigabe zuerst, sonst content_ratings)
    fsk = ""
    for r in (data.get("release_dates") or {}).get("results", []):
        if r.get("iso_3166_1") == "DE":
            for d in r.get("release_dates", []):
                if d.get("certification"):
                    fsk = str(d["certification"])
                    break
        if fsk:
            break
    if not fsk:
        for r in (data.get("content_ratings") or {}).get("results", []):
            if r.get("iso_3166_1") == "DE" and r.get("rating"):
                fsk = str(r["rating"])
                break
    if fsk and not fsk.upper().startswith("FSK"):
        fsk = f"FSK {fsk}"

    trailer = ""
    for v in (data.get("videos") or {}).get("results", []):
        if v.get("site") == "YouTube" and v.get("type") == "Trailer":
            trailer = v.get("key") or ""
            break

    runtime = data.get("runtime") or 0
    if not runtime and data.get("episode_run_time"):
        runtime = data["episode_run_time"][0]
    release = data.get("release_date") or data.get("first_air_date") or ""
    result = {
        "title": data.get("title") or data.get("name") or base.get("title") or base.get("name") or title,
        "original_title": data.get("original_title") or data.get("original_name") or "",
        "tagline": data.get("tagline") or "",
        "overview": data.get("overview") or "",
        "release_date": release,
        "year": release.split("-")[0] if release else (year or ""),
        "runtime": runtime,
        "fsk": fsk,
        "genres": [g.get("name", "") for g in (data.get("genres") or []) if g.get("name")],
        "rating": data.get("vote_average"),
        "votes": data.get("vote_count"),
        "popularity": data.get("popularity"),
        "status": data.get("status") or "",
        "budget": data.get("budget") or 0,
        "revenue": data.get("revenue") or 0,
        "imdb_id": data.get("imdb_id") or "",
        "homepage": data.get("homepage") or "",
        "director": ", ".join(directors),
        "writer": ", ".join(writers),
        "production_companies": [p.get("name", "") for p in (data.get("production_companies") or [])],
        "production_countries": [p.get("name", "") for p in (data.get("production_countries") or [])],
        "spoken_languages": [l.get("english_name") or l.get("name", "") for l in (data.get("spoken_languages") or [])],
        "cast": cast,
        "trailer": trailer,
        "poster_url": img(data.get("poster_path")),
        "backdrop_url": img(data.get("backdrop_path"), "w1280"),
        "media_type": mt,
        "number_of_seasons": data.get("number_of_seasons"),
        "number_of_episodes": data.get("number_of_episodes"),
    }

    # Serien: alle Staffeln mit ihren Folgen (jeweils direkt abspielbar)
    seasons = []
    if mt == "tv":
        series_title = result["title"]
        for season in (data.get("seasons") or [])[:12]:
            number = season.get("season_number")
            if number is None:
                continue
            sdata = _tmdb_get(
                f"tv/{base['id']}/season/{number}", {"language": "de-DE"}
            ) or {}
            episodes = []
            for e in (sdata.get("episodes") or [])[:40]:
                ep_no = e.get("episode_number")
                if ep_no is None:
                    continue
                episodes.append({
                    "season": number,
                    "episode": ep_no,
                    "title": e.get("name") or f"Folge {ep_no}",
                    "overview": e.get("overview") or "",
                    "still_url": img(e.get("still_path"), "w500"),
                    "air_date": e.get("air_date") or "",
                    "runtime": e.get("runtime") or 0,
                    "rating": e.get("vote_average"),
                    "url": (
                        f"plugin://flixam/search/{quote_plus(series_title)}"
                        f"?season={number}&episode={ep_no}"
                    ),
                })
            seasons.append({
                "season": number,
                "name": season.get("name") or f"Staffel {number}",
                "poster_url": img(season.get("poster_path")),
                "air_date": season.get("air_date") or "",
                "episode_count": len(episodes),
                "episodes": episodes,
            })
    result["seasons"] = seasons
    _TMDB_CACHE[cache_key] = result
    return result


@app.get("/tmdb/person")
def tmdb_person(id: str = Query(None), name: str = Query("")):
    """Person + vollstaendige Filmografie (Film- und Serienrollen)."""
    if not TMDB_API_KEY:
        return {}
    person_id = str(id).strip() if id else ""
    if not person_id and name:
        found = _tmdb_get("search/person", {"query": name, "language": "de-DE", "page": 1}) or {}
        results = found.get("results") or []
        best = next(
            (p for p in results if p.get("known_for_department") == "Acting"),
            results[0] if results else None,
        )
        person_id = str(best.get("id") or "") if best else ""
    if not person_id:
        return {}
    cache_key = f"person|{person_id}"
    if cache_key in _TMDB_CACHE:
        return _TMDB_CACHE[cache_key]
    data = _tmdb_get(
        f"person/{person_id}",
        {
            "language": "de-DE",
            "append_to_response": "movie_credits,tv_credits",
        },
    ) or {}
    if not data:
        return {}

    def img(path, size="w500"):
        return f"https://image.tmdb.org/t/p/{size}{path}" if path else ""

    items = []
    seen = set()
    for mt, key in (("movie", "movie_credits"), ("tv", "tv_credits")):
        credits = data.get(key) or {}
        for c in credits.get("cast") or []:
            item = _tmdb_to_item(c, mt)
            if not item or not item.get("title"):
                continue
            dedupe = f"{mt}|{item['title']}|{item.get('year') or ''}"
            if dedupe in seen:
                continue
            seen.add(dedupe)
            item["character"] = c.get("character") or ""
            item["episode_count"] = c.get("episode_count")
            items.append(item)
    # Beliebte / neuere Titel zuerst
    items.sort(
        key=lambda i: (
            i.get("year") or "",
            i.get("rating") or 0,
        ),
        reverse=True,
    )
    result = {
        "id": data.get("id"),
        "name": data.get("name") or name,
        "profile_url": img(data.get("profile_path"), "h632"),
        "known_for": data.get("known_for_department") or "Acting",
        "birthday": data.get("birthday") or "",
        "deathday": data.get("deathday") or "",
        "place_of_birth": data.get("place_of_birth") or "",
        "biography": data.get("biography") or "",
        "popularity": data.get("popularity"),
        "item_count": len(items),
        "items": items,
    }
    _TMDB_CACHE[cache_key] = result
    return result


def _home_sections():
    today = date.today().isoformat()
    soon = (date.today() + timedelta(days=120)).isoformat()
    return [
        ("Neu im Kino", "movie/now_playing", "movie", {}),
        ("Neue Serien", "tv/popular", "tv", {}),
        ("Beliebt diese Woche", "trending/all/week", None, {}),
        ("Top bewertet", "movie/top_rated", "movie", {}),
        ("Kommt bald", "discover/movie", "movie", {
            "primary_release_date.gte": today,
            "primary_release_date.lte": soon,
            "sort_by": "popularity.desc",
        }),
        ("Action", "discover/movie", "movie", {"with_genres": "28", "sort_by": "popularity.desc"}),
        ("Komödie", "discover/movie", "movie", {"with_genres": "35", "sort_by": "popularity.desc"}),
        ("Drama", "discover/movie", "movie", {"with_genres": "18", "sort_by": "popularity.desc"}),
        ("Horror", "discover/movie", "movie", {"with_genres": "27", "sort_by": "popularity.desc"}),
    ]


@app.get("/trailer/stream")
def trailer_stream(key: str = Query("")):
    """Löst einen YouTube-Trailer zu einer direkt abspielbaren URL auf."""
    if not key:
        return {}
    cache_key = f"trailer|{key}"
    if cache_key in _TMDB_CACHE:
        return _TMDB_CACHE[cache_key]
    try:
        result = subprocess.run(
            [
                "yt-dlp",
                "--extractor-args",
                "youtube:player_client=android",
                "--no-warnings",
                "-g",
                f"https://www.youtube.com/watch?v={key}",
            ],
            capture_output=True,
            text=True,
            timeout=70,
        )
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip().startswith("http")]
        if lines:
            out = {
                "stream_url": lines[0],
                "headers": {
                    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/148.0 Safari/537.36",
                    "Referer": "https://www.youtube.com/",
                },
            }
            _TMDB_CACHE[cache_key] = out
            return out
    except Exception:
        pass
    return {}


@app.get("/tmdb/providers")
def tmdb_providers():
    """Bekannte Streaminganbieter in DE (aus Watch-Provider-Daten)."""
    cache_key = "watchproviders|DE"
    if cache_key in _TMDB_CACHE:
        return {"providers": _TMDB_CACHE[cache_key]}
    data = _tmdb_get("movie/550/watch/providers", {}) or {}
    de = ((data.get("results") or {}).get("DE") or {})
    providers = {}
    for key in ("flatrate", "ads", "free", "rent", "buy"):
        for p in de.get(key) or []:
            pid = p.get("provider_id")
            if not pid or pid in providers:
                continue
            providers[pid] = {
                "id": pid,
                "name": p.get("provider_name") or "",
                "logo_url": (
                    "https://image.tmdb.org/t/p/w92" + p["logo_path"]
                    if p.get("logo_path") else ""
                ),
                "priority": p.get("display_priority", 999),
            }
    result = sorted(providers.values(), key=lambda p: (p["priority"], p["name"]))
    _TMDB_CACHE[cache_key] = result
    return {"providers": result}


ORIGINAL_NETWORKS = [
    {"id": 2552, "name": "Apple TV+"},
    {"id": 213, "name": "Netflix"},
    {"id": 2739, "name": "Disney+"},
    {"id": 1024, "name": "Prime Video"},
    {"id": 49, "name": "HBO / Max"},
    {"id": 4330, "name": "Paramount+"},
]


@app.get("/tmdb/series/network")
def tmdb_series_network(id: str = Query(""), limit: int = 60,
                        year: str = Query("")):
    """Alle Serien eines Netzwerks, optional nach Jahr (fuer "mehr")."""
    if not id:
        return {"items": []}
    cache_key = f"series|network|{id}|{limit}|{year}"
    if cache_key in _TMDB_CACHE:
        return {"items": _TMDB_CACHE[cache_key]}
    out = []
    seen = set()
    from datetime import date as _date
    # Zwei Sortierungen kombinieren: neueste AND bekannte Originale,
    # sonst fehlen Titel, die nur auf spaeteren Datum-Seiten liegen.
    if year.isdigit():
        sort_plan = (("popularity.desc", 15),)
    else:
        sort_plan = (("first_air_date.desc", 10), ("popularity.desc", 5))
    for sort_by, pages in sort_plan:
        for page in range(1, pages + 1):
            params = {
                "with_networks": id,
                "sort_by": sort_by,
                "page": page,
            }
            if year.isdigit():
                params["first_air_date_year"] = year
                params["sort_by"] = "popularity.desc"
            data = _tmdb_get("discover/tv", params) or {}
            results = data.get("results") or []
            if not results:
                break
            for r in results:
                item = _tmdb_to_item(r, "tv")
                if not item or not item.get("title") or not item.get("poster_url"):
                    continue
                try:
                    y = int(item.get("year") or 9999)
                    if y > _date.today().year:
                        continue
                    if year.isdigit() and y != int(year):
                        continue
                except (TypeError, ValueError):
                    continue
                if item["title"] not in seen:
                    seen.add(item["title"])
                    out.append(item)
            if len(out) >= limit:
                break
            if page >= min(int(data.get("total_pages") or 1), pages):
                break
        if len(out) >= limit:
            break
    out = out[:limit]
    _TMDB_CACHE[cache_key] = out
    return {"items": out}


@app.get("/tmdb/series/new")
def tmdb_series_new(originals: bool = True, limit: int = 12):
    """Neueste Serien - standardmaessig nur Eigenproduktionen der Dienste."""
    cache_key = f"series|new|{originals}|{limit}"
    if cache_key in _TMDB_CACHE:
        return {"groups": _TMDB_CACHE[cache_key]}
    from concurrent.futures import ThreadPoolExecutor

    targets = ORIGINAL_NETWORKS if originals else [
        {"id": None, "name": "Neu im Streaming"}
    ]

    def fetch(net):
        params = {"sort_by": "first_air_date.desc", "page": 1}
        if net["id"]:
            params["with_networks"] = net["id"]
        else:
            params.update({
                "with_watch_providers": 8,
                "watch_region": "DE",
            })
        data = _tmdb_get("discover/tv", params) or {}
        out = []
        seen = set()
        from datetime import date as _date
        for r in (data.get("results") or []):
            item = _tmdb_to_item(r, "tv")
            if not item or not item.get("title"):
                continue
            if not item.get("poster_url"):
                continue
            try:
                if int(item.get("year") or 9999) > _date.today().year:
                    continue
            except (TypeError, ValueError):
                continue
            if item["title"] not in seen:
                seen.add(item["title"])
                out.append(item)
        return {"id": net["id"], "name": net["name"], "items": out[:limit]}

    groups = []
    with ThreadPoolExecutor(max_workers=5) as pool:
        for group in pool.map(fetch, targets):
            if group["items"]:
                groups.append(group)
    _TMDB_CACHE[cache_key] = groups
    return {"groups": groups}


@app.get("/tmdb/provider/recent")
def tmdb_provider_recent(id: str = Query(""), limit: int = 40,
                         year: str = Query("")):
    """Neueste Titel eines Anbieters - optional alle Filme eines Jahres."""
    if not id:
        return {"items": []}
    cache_key = f"provider|recent|{id}|{limit}|{year}"
    if cache_key in _TMDB_CACHE:
        return {"items": _TMDB_CACHE[cache_key]}
    out = []
    seen = set()
    if year.isdigit():
        plan = (("discover/movie", "movie", "popularity.desc", 15),)
    else:
        plan = (
            ("discover/movie", "movie", "release_date.desc", 3),
            ("discover/tv", "tv", "first_air_date.desc", 3),
        )
    for path, media_type, sort_by, pages in plan:
        for page in range(1, pages + 1):
            params = {
                "with_watch_providers": id,
                "watch_region": "DE",
                "sort_by": sort_by,
                "page": page,
            }
            if year.isdigit() and media_type == "movie":
                params["primary_release_year"] = year
            data = _tmdb_get(path, params) or {}
            results = data.get("results") or []
            if not results:
                break
            for r in results:
                item = _tmdb_to_item(r, media_type)
                if not item or not item.get("title"):
                    continue
                if year.isdigit() and item.get("year") != year:
                    continue
                if item["title"] not in seen:
                    seen.add(item["title"])
                    out.append(item)
            if len(out) >= limit:
                break
            if page >= min(int(data.get("total_pages") or 1), pages):
                break
        if len(out) >= limit:
            break
    out = out[:limit]
    _TMDB_CACHE[cache_key] = out
    return {"items": out}


@app.get("/tmdb/providers/recent")
def tmdb_providers_recent(limit: int = 8):
    """Neueste Titel pro Streaminganbieter (DE), nach Release-Datum sortiert."""
    cache_key = f"providers|recent|{limit}"
    if cache_key in _TMDB_CACHE:
        return {"groups": _TMDB_CACHE[cache_key]}
    providers = (tmdb_providers().get("providers") or [])[:12]
    from concurrent.futures import ThreadPoolExecutor

    def fetch(p):
        items = []
        seen = set()
        for path, media_type, sort_by in (
            ("discover/movie", "movie", "release_date.desc"),
            ("discover/tv", "tv", "first_air_date.desc"),
        ):
            data = _tmdb_get(path, {
                "with_watch_providers": p.get("id"),
                "watch_region": "DE",
                "sort_by": sort_by,
                "page": 1,
            }) or {}
            for r in (data.get("results") or []):
                item = _tmdb_to_item(r, media_type)
                if item and item.get("title") and item["title"] not in seen:
                    seen.add(item["title"])
                    items.append(item)
        return {
            "id": p.get("id"),
            "name": p.get("name") or "",
            "logo_url": p.get("logo_url") or "",
            "items": items[:limit],
        }

    groups = []
    with ThreadPoolExecutor(max_workers=6) as pool:
        for group in pool.map(fetch, providers):
            if group["items"]:
                groups.append(group)
    _TMDB_CACHE[cache_key] = groups
    return {"groups": groups}


@app.get("/tmdb/provider")
def tmdb_provider(id: str = Query(""), type: str = Query("all")):
    """Alle Filme/Serien eines Streaminganbieters (DE)."""
    if not id:
        return {"items": []}
    cache_key = f"watchprovider|{id}|{type}"
    if cache_key in _TMDB_CACHE:
        return {"items": _TMDB_CACHE[cache_key]}
    out = []
    seen = set()
    # discover Endpunkte direkt aufrufen (unser _tmdb_get baut die URL)
    queries = []
    if type in ("all", "movie"):
        queries.append(("discover/movie", "movie"))
    if type in ("all", "tv"):
        queries.append(("discover/tv", "tv"))
    for path, media_type in queries:
        for page in (1, 2, 3):
            data = _tmdb_get(path, {
                "with_watch_providers": id,
                "watch_region": "DE",
                "sort_by": "popularity.desc",
                "page": page,
            }) or {}
            results = data.get("results") or []
            if not results:
                break
            for r in results:
                item = _tmdb_to_item(r, media_type)
                if item and item.get("title") and item["title"] not in seen:
                    seen.add(item["title"])
                    out.append(item)
            if page >= min(int(data.get("total_pages") or 1), 3):
                break
    _TMDB_CACHE[cache_key] = out
    return {"items": out, "total": len(out)}


@app.get("/home")
def home(force: bool = Query(False)):
    """Startseite: Hero + Neuheiten-Reihen (TMDB), mit playbaren Such-URLs."""
    import time as _time
    if not force and _HOME_CACHE["data"] and _time.time() - _HOME_CACHE["time"] < 1800:
        return _HOME_CACHE["data"]

    trending = _tmdb_get("trending/all/week", {"language": "de-DE"}) or {}
    hero = None
    for res in trending.get("results", []) or []:
        if res.get("backdrop_path"):
            hero = _tmdb_to_item(res)
            break

    sections = []
    for title, path, media_type, extra in _home_sections():
        params = {"language": "de-DE", "page": 1, **extra}
        data = _tmdb_get(path, params) or {}
        items = [_tmdb_to_item(r, media_type) for r in (data.get("results") or [])]
        data2 = _tmdb_get(path, {**params, "page": 2}) or {}
        items += [_tmdb_to_item(r, media_type) for r in (data2.get("results") or [])]
        seen_titles = set()
        unique = []
        for it in items:
            if it and it.get("title") and it["title"] not in seen_titles:
                seen_titles.add(it["title"])
                unique.append(it)
        sections.append({"title": title, "items": unique[:40]})

    result = {"hero": hero, "sections": sections}
    _HOME_CACHE["data"] = result
    _HOME_CACHE["time"] = _time.time()
    return result


@app.get("/home/all")
def home_all(section: str = Query("")):
    """Alle Titel einer Home-Kategorie (alle TMDB-Seiten), gecacht."""
    config = next((c for c in _home_sections() if c[0] == section), None)
    if not config:
        return {"items": [], "section": section}
    cache_key = f"homeall|{section}"
    if cache_key in _TMDB_CACHE:
        return {"items": _TMDB_CACHE[cache_key], "section": section}
    title, path, media_type, extra = config
    items = []
    seen = set()
    total_pages = 1
    for page in range(1, 21):
        data = _tmdb_get(path, {"language": "de-DE", "page": page, **extra}) or {}
        if page == 1:
            try:
                total_pages = min(int(data.get("total_pages") or 1), 20)
            except (TypeError, ValueError):
                total_pages = 1
        results = data.get("results") or []
        if not results:
            break
        for r in results:
            item = _tmdb_to_item(r, media_type)
            if item and item.get("title") and item["title"] not in seen:
                seen.add(item["title"])
                items.append(item)
        if page >= total_pages:
            break
    _TMDB_CACHE[cache_key] = items
    return {"items": items, "section": section, "total": len(items)}


@app.get("/addon/episodes")
def addon_episodes(addon: str = Query("xstream"), url: str = Query("")):
    """Alle Folgen einer Serie ueber alle Staffeln in einer Liste.

    'url' ist die showSeasons-URL des Serieneintrags.
    """
    addon_id = "plugin.video.xstream" if addon == "xstream" else "plugin.video.xship"
    if not url:
        return {"items": []}
    seasons = run_addon(addon_id, url)
    episodes = []
    seen = set()
    for season in seasons:
        season_url = str(season.get("url") or "")
        if not season_url.startswith("plugin://"):
            continue
        season_title = str(season.get("title") or "")
        try:
            found = run_addon(addon_id, season_url)
        except Exception:
            continue
        for ep in found:
            ep = dict(ep)
            ep_url = str(ep.get("url") or "")
            if not ep_url or ep_url in seen:
                continue
            seen.add(ep_url)
            title = str(ep.get("title") or "")
            info = ep.get("info") or {}
            # Staffel-/Folgennummer aus den Addon-Daten ergaenzen, falls der
            # Titel sie nicht schon enthaelt (z.B. "S01E01 - ...").
            if not re.match(r"^S\d{1,2}E\d{1,3}\b", title, re.I):
                s = info.get("season") or info.get("seasonnumber") or ""
                e = info.get("episode") or info.get("episodenumber") or ""
                if s != "" and e != "":
                    try:
                        ep["title"] = f"S{int(s):02d}E{int(e):02d} - {title}".strip()
                    except (TypeError, ValueError):
                        pass
            episodes.append(ep)
    return {"items": _enrich_items(episodes), "season_count": len(seasons)}


def _split_stream_headers(raw: str):
    """Trennt Kodi-Format 'url|Header=Wert&...' in (url, headers)."""
    from urllib.parse import unquote_plus
    headers = {}
    if "|" in raw:
        url, header_str = raw.split("|", 1)
        for pair in header_str.split("&"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                # Kodi kodiert Header-Werte (Leerzeichen als '+', '/' als '%2F')
                headers[unquote_plus(k.strip())] = unquote_plus(v.strip())
        return url.strip(), headers
    return raw.strip(), headers


def _resolve_plugin_play_url(url: str, depth: int = 0):
    """Führt eine plugin://-Play-URL im Addon aus und sammelt das Ergebnis.

    Kodi-Addons rufen bei 'play' typischerweise xbmcplugin.setResolvedUrl()
    auf; manche liefern stattdessen DIRECTORY_ITEMS mit direkten Links.
    """
    if depth > 2 or not url.lower().startswith("plugin://"):
        return ""
    addon_id = url.split("plugin://", 1)[1].split("/", 1)[0]
    try:
        items = run_addon(addon_id, url)
    except Exception:
        items = []
    try:
        import xbmcplugin
        resolved = xbmcplugin.RESOLVED_URL or ""
    except Exception:
        resolved = ""
    if resolved:
        return resolved
    for it in items:
        candidate = str(it.get("url") or "")
        if candidate.startswith(("http://", "https://")):
            return candidate
        if candidate.lower().startswith("plugin://"):
            deeper = _resolve_plugin_play_url(candidate, depth + 1)
            if deeper:
                return deeper
    return ""


def _flatten_hls_master(url: str, headers: dict) -> str:
    """Master-Playlist durch die erste Variante ersetzen (stabiler bei mpv)."""
    if ".m3u8" not in url:
        return url
    try:
        r = requests.get(url, headers=headers, timeout=15)
        if r.status_code != 200 or "#EXT-X-STREAM-INF" not in r.text:
            return url
        lines = [
            line.strip() for line in r.text.splitlines()
            if line.strip() and not line.startswith("#")
        ]
        if not lines:
            return url
        return urljoin(url, lines[0])
    except Exception:
        return url


def _resolve_episode_url(series_url: str, season: int, episode: int):
    """Aus einer showSeasons-URL die URL einer konkreten Folge finden."""
    try:
        seasons = run_addon("plugin.video.xstream", series_url)
    except Exception:
        return ""
    season_url = ""
    for s in seasons:
        query = dict(parse_qsl(urlsplit(str(s.get("url") or "")).query))
        sn = query.get("season") or query.get("sSeasonNr") or ""
        title = str(s.get("title") or "")
        match = re.search(r"(\d+)\s*$", re.sub(r"\[I\].*?\[/I\]", "", title))
        try:
            if (sn and int(sn) == season) or (match and int(match.group(1)) == season):
                season_url = str(s.get("url") or "")
                break
        except (TypeError, ValueError):
            continue
    if not season_url:
        return ""
    try:
        episodes = run_addon("plugin.video.xstream", season_url)
    except Exception:
        return ""
    for e in episodes:
        query = dict(parse_qsl(urlsplit(str(e.get("url") or "")).query))
        en = query.get("episode") or query.get("sEpisodeNr") or ""
        title = str(e.get("title") or "")
        match = re.search(r"S\d{1,2}E(\d{1,3})\b", title, re.I)
        try:
            if (en and int(en) == episode) or (match and int(match.group(1)) == episode):
                return str(e.get("url") or "")
        except (TypeError, ValueError):
            continue
    return ""


def _resolve_flixam_search_candidates(url: str) -> list[str]:
    """plugin://flixam/search/<Titel> -> alle passenden Addon-Play-URLs (gewichtet).

    Es werden mehrere Kandidaten geliefert, damit /resolve bei einem defekten
    Hoster (z. B. DoodStream mit Captcha) auf die naechste Quelle ausweichen
    kann, statt "Kein abspielbarer Stream" zu melden.
    """
    if not url.lower().startswith("plugin://flixam/search/"):
        return []
    raw = url.split("plugin://flixam/search/", 1)[1]
    title_part, _, query = raw.partition("?")
    title = unquote_plus(title_part).strip()
    if not title:
        return []
    params = dict(parse_qsl(query))
    wanted_year = params.get("year", "")
    wanted_type = params.get("type", "")
    wanted_source = params.get("source", "").strip().lower()
    try:
        wanted_season = int(params.get("season") or 0)
        wanted_episode = int(params.get("episode") or 0)
    except (TypeError, ValueError):
        wanted_season = wanted_episode = 0

    def attempt(search_title: str) -> list[str]:
        search_url = (
            f"plugin://plugin.video.xstream/?site=globalSearch"
            f"&searchterm={quote(search_title)}"
        )
        try:
            candidates = run_addon("plugin.video.xstream", search_url)
        except Exception:
            return []
        clean = re.sub(r"\[I\].*?\[/I\]", "", _clean_title(search_title))
        tokens = set(clean.split())

        def score(item):
            raw_title = str(item.get("title") or "").lower()
            item_url = str(item.get("url") or "").lower()
            t = re.sub(r"\[I\].*?\[/I\]", "", _clean_title(str(item.get("title") or "")))
            s = 0
            if wanted_source and (
                wanted_source in raw_title
                or wanted_source.replace(" ", "") in item_url
                or wanted_source.replace("-", "") in item_url
            ):
                s += 80
            if t == clean:
                s += 100
            elif clean and (clean in t or t in clean):
                s += 60
            else:
                s += 20 * len(tokens & set(t.split()))
            if wanted_year and str(item.get("year") or "") == wanted_year:
                s += 15
            if wanted_type and item.get("media_type") == wanted_type:
                s += 10
            if "function=showHosters" in str(item.get("url") or ""):
                s += 5
            return s

        ranked = sorted(candidates, key=score, reverse=True)
        if not ranked or score(ranked[0]) < 20:
            return []
        if wanted_source:
            source_ranked = [
                c for c in ranked
                if wanted_source in str(c.get("title") or "").lower()
                or wanted_source.replace("-", "") in str(c.get("url") or "").lower()
            ]
            if source_ranked:
                ranked = source_ranked
        # Serien-Folge: passende Staffel/Folge im Addon aufloesen
        if wanted_season and wanted_episode:
            episode_urls = []
            for candidate in ranked:
                if score(candidate) < 15:
                    break
                if "function=showSeasons" in str(candidate.get("url") or ""):
                    episode_url = _resolve_episode_url(
                        str(candidate.get("url")), wanted_season, wanted_episode
                    )
                    if episode_url:
                        episode_urls.append(episode_url)
            if episode_urls:
                return episode_urls
        out = []
        for candidate in ranked:
            if score(candidate) < 15:
                break
            candidate_url = str(candidate.get("url") or "")
            if candidate_url and candidate_url not in out:
                out.append(candidate_url)
            if len(out) >= 10:
                break
        return out

    found = attempt(title)
    if not found and (":" in title or "(" in title):
        # z.B. "Die Tribute von Panem: Sunrise on the Reaping"
        found = attempt(re.split(r"[:(]", title, 1)[0].strip())
    return found


def _resolve_flixam_search_url(url: str) -> str:
    """Rueckwaertskompatibel: nur der bestbewertete Kandidat."""
    candidates = _resolve_flixam_search_candidates(url)
    return candidates[0] if candidates else ""


# --- Downloads (nur Linux-Desktop; ffmpeg lokal) ---------------------------
DOWNLOAD_DIR = os.path.join(
    os.path.dirname(BASE_DIR), "flixam_downloads"
)
_DOWNLOADS = {}
_DOWNLOAD_PROCS = {}
_DOWNLOAD_LOCK = threading.Lock()


def _download_name(title: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9ÄÖÜäöüß._ -]", "", title).strip()
    safe = re.sub(r"\s+", " ", safe)[:120] or "download"
    return safe + ".mp4"


def _download_worker(key: str, stream_url: str, headers: dict) -> None:
    path = os.path.join(DOWNLOAD_DIR, key)
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-loglevel", "error"]
    header_str = "".join(
        f"{k}: {str(v).replace(chr(10), ' ').replace(chr(13), ' ')}\r\n"
        for k, v in (headers or {}).items()
    )
    if header_str:
        cmd += ["-headers", header_str]
    cmd += [
        "-i", stream_url,
        "-c", "copy",
        "-bsf:a", "aac_adtstoasc",
        "-movflags", "+faststart",
        "-progress", "pipe:1",
        "-nostats",
        path,
    ]
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        with _DOWNLOAD_LOCK:
            _DOWNLOAD_PROCS[key] = proc
        duration = 0.0
        try:
            probe_cmd = ["ffprobe", "-v", "error"]
            if header_str:
                probe_cmd += ["-headers", header_str]
            probe_cmd += [
                "-show_entries", "format=duration", "-of", "csv=p=0",
                stream_url,
            ]
            probe = subprocess.run(
                probe_cmd, capture_output=True, text=True, timeout=30,
            )
            duration = float((probe.stdout or "0").strip() or 0)
        except Exception:
            pass
        with _DOWNLOAD_LOCK:
            _DOWNLOADS[key]["duration"] = duration
        for line in proc.stdout or []:
            line = line.strip()
            if line.startswith("out_time_ms="):
                try:
                    elapsed = int(line.split("=", 1)[1]) / 1_000_000
                    with _DOWNLOAD_LOCK:
                        _DOWNLOADS[key]["elapsed"] = elapsed
                        if duration > 0:
                            _DOWNLOADS[key]["progress"] = min(
                                0.99, elapsed / duration
                            )
                except (ValueError, TypeError):
                    pass
        code = proc.wait(timeout=7200)
        with _DOWNLOAD_LOCK:
            _DOWNLOADS[key]["progress"] = 1.0 if code == 0 else 0.0
            _DOWNLOADS[key]["status"] = "done" if code == 0 else "error"
            if code != 0:
                _DOWNLOADS[key]["error"] = (
                    (proc.stderr.read() or "")[-400:]
                )
    except Exception as e:
        with _DOWNLOAD_LOCK:
            _DOWNLOADS[key]["status"] = "error"
            _DOWNLOADS[key]["error"] = str(e)[:400]
    finally:
        with _DOWNLOAD_LOCK:
            _DOWNLOAD_PROCS.pop(key, None)


@app.post("/download/start")
def download_start(body: dict):
    url = (body.get("url", "") or "").strip()
    title = (body.get("title", "") or "").strip() or "Download"
    if not url:
        return {"ok": False, "error": "Keine URL"}
    resolved = resolve({"url": url})
    stream_url = resolved.get("stream_url") or ""
    if not stream_url:
        return {"ok": False, "error": "Kein Stream gefunden"}
    key = _download_name(title)
    with _DOWNLOAD_LOCK:
        if key in _DOWNLOADS and _DOWNLOADS[key]["status"] == "running":
            return {"ok": True, "key": key, "already": True}
        _DOWNLOADS[key] = {
            "title": title,
            "key": key,
            "status": "running",
            "progress": 0.0,
            "elapsed": 0.0,
            "error": "",
        }
    t = threading.Thread(
        target=_download_worker,
        args=(key, stream_url, resolved.get("headers") or {}),
        daemon=True,
    )
    t.start()
    return {"ok": True, "key": key}


@app.get("/download/status")
def download_status():
    with _DOWNLOAD_LOCK:
        return {"items": [dict(v) for v in _DOWNLOADS.values()]}


@app.get("/download/file/{name}")
def download_file(name: str):
    target = os.path.realpath(os.path.join(DOWNLOAD_DIR, name))
    if not target.startswith(os.path.realpath(DOWNLOAD_DIR) + os.sep):
        return {"detail": "not found"}
    if not os.path.isfile(target):
        return {"detail": "not found"}
    return FileResponse(target, media_type="video/mp4")


@app.delete("/download/{name}")
def download_delete(name: str):
    target = os.path.realpath(os.path.join(DOWNLOAD_DIR, name))
    if target.startswith(os.path.realpath(DOWNLOAD_DIR) + os.sep):
        try:
            os.remove(target)
        except OSError:
            pass
    with _DOWNLOAD_LOCK:
        proc = _DOWNLOAD_PROCS.pop(name, None)
        _DOWNLOADS.pop(name, None)
    if proc is not None:
        try:
            proc.terminate()
        except OSError:
            pass
    return {"ok": True}


@app.post("/resolve")
def resolve(body: dict):
    url = (body.get("url", "") or "").strip()
    headers = {}
    stream_url = ""

    # Hero-/TMDB-Items nutzen flixam://tmdb/<Titel>, das Frontend uebersetzt
    # das zu plugin://flixam/tmdb/<Titel>. Beide Formen wie den Such-Pfad
    # behandeln - sonst sucht _resolve_plugin_play_url ein Addon "flixam",
    # das es nicht gibt, und der Stream bleibt leer.
    for prefix in ("plugin://flixam/tmdb/", "flixam://tmdb/"):
        if url.lower().startswith(prefix):
            url = "plugin://flixam/search/" + url[len(prefix):]
            break

    # Hero-/Entdeckungs-Items nutzen plugin://flixam/search/<Titel>.
    # Alle passenden Quellen der Reihe nach probieren: Ist der Hoster der
    # ersten Quelle defekt (z. B. DoodStream/Captcha), wird die naechste
    # Quelle verwendet, statt "Kein abspielbarer Stream" zu melden.
    if url.lower().startswith("plugin://flixam/search/"):
        candidate_sets = [_resolve_flixam_search_candidates(url)]
        # Gespeicherte Items koennen eine feste Quelle enthalten. Ist genau
        # diese Quelle defekt, ohne Einschaenkung erneut suchen.
        if "source=" in url:
            base, _, query = url.partition("?")
            params = dict(parse_qsl(query))
            params.pop("source", None)
            fallback_url = base + ("?" + urlencode(params) if params else "")
            candidate_sets.append(_resolve_flixam_search_candidates(fallback_url))
    else:
        candidate_sets = [[url]]

    import resolveurl
    for candidates in candidate_sets:
        for candidate in candidates or [""]:
            current = candidate
            # plugin://-Play-URL: Addon ausfuehren und setResolvedUrl einsammeln
            if current.lower().startswith("plugin://"):
                current = _resolve_plugin_play_url(current)
            if not current.lower().startswith(("http://", "https://")):
                continue
            with _vpn_proxy_context() as proxies:
                resolved = resolveurl.resolve(current)
            candidate_stream = resolved if isinstance(resolved, str) else (resolved or "")
            # Echter Stream-Link: wenn kein Resolve-Provider ihn aufloeste,
            # direkt durchreichen (inkl. Header im Kodi-Format).
            if not candidate_stream:
                candidate_stream = current
            candidate_stream, candidate_headers = _split_stream_headers(candidate_stream)
            candidate_stream = _flatten_hls_master(candidate_stream, candidate_headers)
            if candidate_stream:
                stream_url = candidate_stream
                headers = candidate_headers
                break
        if stream_url:
            break

    result = {"stream_url": stream_url, "headers": headers}
    if not stream_url:
        result["message"] = "Kein abspielbarer Stream gefunden"
    return result


VPN_DIR = os.path.join(os.path.dirname(BASE_DIR), "vpn")
VPN_CONF = os.path.join(VPN_DIR, "wg0.conf")


def _clean_wireguard_conf(text: str) -> str:
    lines = text.splitlines()
    out = []
    for line in lines:
        stripped = line.strip()
        if re.match(r"^\s*DNS\s*=", line, re.I):
            continue
        if re.match(r"^\s*MTU\s*=", line, re.I):
            continue
        if re.match(r"^\s*Address\s*=", line, re.I):
            val = line.split("=", 1)[1]
            addrs = [a.strip() for a in val.split(",")]
            addrs = [a for a in addrs if ":" not in a]
            if not addrs:
                continue
            out.append("Address = " + ", ".join(addrs))
            continue
        if re.match(r"^\s*AllowedIPs\s*=", line, re.I):
            val = line.split("=", 1)[1]
            ips = [a.strip() for a in val.split(",")]
            ips = [a for a in ips if ":" not in a]
            if not ips:
                continue
            out.append("AllowedIPs = " + ", ".join(ips))
            continue
        out.append(line)
    return "\n".join(out)


def ensure_proxy_sections(conf_text: str) -> str:
    text = _clean_wireguard_conf(conf_text)
    # Keep only the first [Interface] and first [Peer] block
    sections = re.split(r"(?=^\[)", text, flags=re.M)
    iface = None
    peer = None
    others = []
    for sec in sections:
        sec = sec.strip()
        if not sec:
            continue
        if sec.startswith("[Interface]") and iface is None:
            iface = sec
        elif sec.startswith("[Peer]") and peer is None:
            peer = sec
        elif sec.startswith("[Socks5]") or sec.startswith("[http]"):
            continue
        else:
            others.append(sec)
    parts = []
    if iface:
        parts.append(iface)
    if peer:
        parts.append(peer)
    parts.extend(others)
    text = "\n\n".join(parts)
    if "[Socks5]" not in text:
        text = text.rstrip() + "\n\n[Socks5]\nBindAddress = 127.0.0.1:1080\n"
    if "[http]" not in text:
        text = text.rstrip() + "\n\n[http]\nBindAddress = 127.0.0.1:8080\n"
    return text.strip() + "\n"


def _is_conf_incomplete():
    if not os.path.exists(VPN_CONF):
        return True
    try:
        txt = open(VPN_CONF).read().strip()
    except Exception:
        return True
    if not txt or "[Interface]" not in txt or "[Peer]" not in txt:
        return True
    if "PrivateKey" not in txt or "REPLACE" in txt:
        return True
    return False


@app.post("/vpn/import")
def vpn_import(body: dict):
    text = (body.get("config_text") or "") if isinstance(body, dict) else ""
    if not text.strip():
        # leerer Import darf keine laufende Konfiguration überschreiben
        return {"status": "needs_config", "message": "Kein Config-Text empfangen"}
    os.makedirs(VPN_DIR, exist_ok=True)
    cleaned = ensure_proxy_sections(text)
    with open(VPN_CONF, "w") as f:
        f.write(cleaned)
    return {"status": "ok", "created": True}


@app.post("/vpn/auto-generate")
def vpn_auto_generate():
    if not _is_conf_incomplete():
        return {"status": "ok", "created": False}
    return {"status": "needs_config", "message": "Bitte Standard-WireGuard-.conf importieren"}


@app.get("/health")
def health():
    return {"status": "ok"}


TMDB_API_KEY = os.environ.get("TMDB_API_KEY", "").strip()
ENV_PATH = os.path.join(BASE_DIR, ".env")


@app.post("/settings/tmdb")
def settings_tmdb(body: dict):
    global TMDB_API_KEY
    key = body.get("api_key", "") if isinstance(body, dict) else ""
    TMDB_API_KEY = str(key).strip()
    os.environ["TMDB_API_KEY"] = TMDB_API_KEY
    lines = []
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH, "r") as f:
            lines = [l for l in f.read().splitlines() if not l.strip().startswith("TMDB_API_KEY=")]
    if TMDB_API_KEY:
        lines.append("TMDB_API_KEY=" + TMDB_API_KEY)
    with open(ENV_PATH, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    return {"status": "ok", "api_key_set": bool(TMDB_API_KEY)}


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
