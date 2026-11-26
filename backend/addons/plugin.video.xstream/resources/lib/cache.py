# -*- coding: utf-8 -*-
# Python 3

import ast
import threading
import time
import xbmcgui

# Eigener Namensraum im Hauptfenster (Window 10000). Alle Addons teilen sich
# dieses Fenster, deshalb duerfen wir beim Leeren NUR unsere eigenen Werte
# anfassen: ein pauschales clearProperties() loeschte auch fremde Properties
# (z.B. den Monitor des YouTube-Plugins, wodurch dessen Wiedergabe abbrach) und
# unsere eigenen (die lastSearchText-/sessionUA-Merker der Site-Files). Deshalb
# tragen alle Cache-Werte den Prefix und ihre Schluessel eine Index-Liste, und
# clear() raeumt nur diese ab. Der Prefix wird intern angehaengt — fuer die
# Aufrufer bleiben die Schluessel unveraendert (md5-Hash bzw. <addon>_main).
_PREFIX = 'xstream.cache.'
_INDEX = 'xstream.cache.__keys__'

# Grenze fuer die Eintraege mit Lebensdauer (die Seiten des requestHandlers), in Zeichen. Die Werte liegen im
# Speicher von Kodi und blieben bis zum 11.11.2026 dort, bis Kodi beendet wurde: wer lange stoeberte, liess Kodi
# wachsen (nachgestellt am 10.11.2026: 450 Seiten = 71 Mio. Zeichen, Kodi 21.3 wuchs um 106 MB, Kodi 22 um 119 MB).
# Seitdem raeumt jedes Schreiben, was abgelaufen ist, und verdraengt ueber der Grenze die aeltesten Eintraege.
# 32 Mio. Zeichen sind rund 200 Seiten und rund 50 MB in Kodi.
_LIMIT = 32000000
# Index: je Eintrag eine Zeile. Mit Lebensdauer „Schluessel<TAB>Ablaufzeit<TAB>Zeichen" — so laesst sich raeumen,
# ohne die Werte selbst zu lesen. Nur der Schluessel = ohne Lebensdauer (das Start-Flag des Dienstes): der
# Eintrag bleibt, bis clear() ihn abraeumt.
# Die Sperre gilt fuer die Threads eines Aufrufs. Zwei Aufrufe zugleich (jeder ein eigener Interpreter) koennen
# sich weiter eine Index-Zeile ueberschreiben; der Wert wird dann beim Lesen nach Ablauf geraeumt.
_lock = threading.Lock()


class cCache(object):
    _win = None

    def __init__(self):
        # see https://kodi.wiki/view/Window_IDs
        self._win = xbmcgui.Window(10000)

    def __del__(self):
        del self._win

    def _entries(self):
        """Index als Dict: Schluessel -> (Ablaufzeit, Zeichen), oder None fuer einen Eintrag ohne Lebensdauer."""
        entries = {}
        raw = self._win.getProperty(_INDEX)
        for line in raw.split('\n') if raw else ():
            parts = line.split('\t')
            if not parts[0]:
                continue
            entries[parts[0]] = None
            if len(parts) == 3:
                try:
                    entries[parts[0]] = (float(parts[1]), int(parts[2]))
                except ValueError:
                    pass
        return entries

    def _save_entries(self, entries):
        self._win.setProperty(_INDEX, '\n'.join(k if v is None else '%s\t%.0f\t%d' % (k, v[0], v[1])
                                                for k, v in entries.items()))

    def get(self, key, cache_time):
        prop = _PREFIX + key
        cachedata = self._win.getProperty(prop)
        if not cachedata:
            return None
        try:
            stamp, data = ast.literal_eval(cachedata)
        except (ValueError, SyntaxError, TypeError):
            # Beschaedigter Eintrag: wegraeumen statt bei jedem Aufruf zu knallen.
            self._win.clearProperty(prop)
            return None
        if cache_time < 0 or time.time() - stamp < cache_time:
            return data
        self._win.clearProperty(prop)
        return None

    def set(self, key, data, ttl=None):
        """ttl = Lebensdauer in Sekunden; ohne ttl bleibt der Eintrag bis clear()."""
        now = time.time()
        value = repr((now, data))
        with _lock:
            self._win.setProperty(_PREFIX + key, value)
            entries = self._entries()
            if ttl is None:
                if key in entries and entries[key] is None:
                    return
                entries[key] = None
            else:
                entries[key] = (now + ttl, len(value))
                total = 0
                for k, v in list(entries.items()):
                    if v is None:
                        continue
                    if v[0] <= now and k != key:
                        self._win.clearProperty(_PREFIX + k)
                        del entries[k]
                    else:
                        total += v[1]
                if total > _LIMIT:
                    # die aeltesten zuerst; der Eintrag von eben bleibt
                    for k, v in sorted(((k, v) for k, v in entries.items() if v is not None and k != key),
                                       key=lambda kv: kv[1][0]):
                        if total <= _LIMIT:
                            break
                        self._win.clearProperty(_PREFIX + k)
                        del entries[k]
                        total -= v[1]
            self._save_entries(entries)

    def clear(self):
        with _lock:
            for key in self._entries():
                self._win.clearProperty(_PREFIX + key)
            self._win.clearProperty(_INDEX)
