import json
import os
import re
import glob
import time

# --- Playback-Brücke -----------------------------------------------------
# Der echte Kodi-Player meldet nach setResolvedUrl/play den Abbruch ueber
# Monitor.abortRequested(). In der Mock-Umgebung gibt es keine echte
# Wiedergabe, daher wuerde cPlayer.startPlayer() endlos warten. Sobald eine
# Stream-URL erfasst ist, wird die Addon-Ausfuehrung kontrolliert beendet.
PLAYBACK_URL = None
_PLAYBACK_DONE = False


class PlaybackDone(BaseException):
    """Beendet den Addon-Lauf, sobald die Stream-URL erfasst wurde."""
    pass


def reset_playback():
    global PLAYBACK_URL, _PLAYBACK_DONE
    PLAYBACK_URL = None
    _PLAYBACK_DONE = False


def abort_playback(url=None):
    global PLAYBACK_URL, _PLAYBACK_DONE
    if url:
        PLAYBACK_URL = url
    _PLAYBACK_DONE = True

LOGDEBUG = 0
LOGINFO = 1
LOGWARNING = 2
LOGERROR = 3
LOGFATAL = 4
LOGNOTICE = LOGINFO
ISO_639_1 = "de"
PLAYLIST_VIDEO = 1

SUPPORTED_VIDEO_EXTS = "mp4|mkv|avi|mov|wmv|flv|webm|m4v|m2ts|ts|3gp|mts"

def getSupportedMedia(media="video"):
    return SUPPORTED_VIDEO_EXTS

def getFreeMem():
    return 8192

def getLanguage(lang=ISO_639_1):
    return lang or "de"

def getRegion(what=None):
    return "DE"

def getUserAgent():
    return "Kodi/21.0.0 (X11; Linux x86_64) flixam-player"

def convertLanguage(code, lang=None):
    return lang or code

def log(msg, level=LOGINFO):
    print(f"[KODI-LOG {level}] {msg}")

def translatePath(path):
    base = os.path.expanduser("~/flixam_player/backend/kodi_data")
    os.makedirs(base, exist_ok=True)
    return path.replace("special://profile/", base + "/").replace("special://temp/", "/tmp/")

def getCondVisibility(condition):
    return False

def executebuiltin(command):
    print(f"[KODI-BUILTIN] {command}")

def executeJSONRPC(jsonrpccommand):
    return json.dumps({"id": 1, "jsonrpc": "2.0", "result": {"value": False}})

def getInfoLabel(label):
    if "BuildVersion" in label:
        return "21.0.0"
    return ""

def sleep(ms):
    time.sleep(ms / 1000.0)

class Monitor:
    def abortRequested(self):
        return _PLAYBACK_DONE
    def waitForAbort(self, timeout=0):
        if _PLAYBACK_DONE:
            raise PlaybackDone()
        time.sleep(timeout)
        return False


class Player:
    def __init__(self):
        pass
    def play(self, *a, **k):
        # Addons, die nicht setResolvedUrl nutzen, rufen direkt Player.play()
        # auf. Auch dort die URL sichern und den Lauf beenden.
        if a and isinstance(a[0], str) and a[0].startswith(("http://", "https://", "plugin://")):
            abort_playback(a[0])
    def stop(self):
        pass


_LOCALIZED_STRINGS = None


def _load_localized_strings():
    """Deutsche Addon-Strings aus den strings.po-Dateien lesen."""
    global _LOCALIZED_STRINGS
    if _LOCALIZED_STRINGS is not None:
        return _LOCALIZED_STRINGS
    mapping = {}
    pattern = os.path.join(os.path.dirname(__file__), "..", "addons", "plugin.video.*",
                           "resources", "language", "*de*", "strings.po")
    for path in glob.glob(pattern):
        try:
            text = open(path, encoding="utf-8").read()
            for m in re.finditer(
                r'msgctxt\s+"#(\d+)"\s+msgid\s+"[^"]*"\s+msgstr\s+"([^"]*)"', text, re.S
            ):
                code = int(m.group(1))
                value = m.group(2)
                if code not in mapping and value:
                    mapping[code] = value
        except Exception:
            pass
    _LOCALIZED_STRINGS = mapping
    return mapping


def getLocalizedString(code):
    try:
        key = int(code)
    except (TypeError, ValueError):
        return f"String_{code}"
    return _load_localized_strings().get(key) or f"String_{key}"


def getSkinDir():
    return "skin.estuary"


class PlayList:
    def __init__(self, type=1):
        self.type = type
    def size(self):
        return 0


class Keyboard:
    def __init__(self, line="", heading=""):
        pass
    def doModal(self):
        pass
    def isConfirmed(self):
        return False
    def getText(self):
        return ""


class Actor:
    def __init__(self, name="", title="", thumbnail="", *args, **kwargs):
        self.name = name
        self.title = title
        self.thumbnail = thumbnail
        self.role = kwargs.get("role", "")
        self.order = kwargs.get("order", 0)


class VideoStreamDetail:
    pass


class AudioStreamDetail:
    pass


class SubtitleStreamDetail:
    pass
