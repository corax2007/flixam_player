# -*- coding: utf-8 -*-
# Python 3

import sys

from urllib.parse import parse_qsl, urlsplit, urlencode


class ParameterHandler:
    # True, solange eine Sammelsuche (globale Suche, Weitere Quellen) die Seiten durchsucht: ein neuer ParameterHandler
    # beginnt dann leer statt mit den Parametern des Aufrufs. Die Seiten bauen ihre Treffer mit ParameterHandler(); mit
    # den Parametern des Aufrufs der Suche truege jeder Treffer sie in seiner Adresse weiter, bis zur abspielbaren Folge:
    # das Bild des angeklickten Eintrags (trumb — die Lupe bzw. das Poster des TMDB-Eintrags), searchTitle und vom TMDB
    # Browser dazu media_type, tmdb_url und tmdb_page. Bis zum 12.11.2026 zeigte ein Treffer ohne eigenes Bild
    # (BurningSeries liefert in der Suche keins) deshalb das Poster des angeklickten TMDB-Eintrags, z.B. "Castlevania:
    # Nocturne" das von "Nocturne", und die Adresse einer Folge hing am Weg zu ihr — Kodi fuehrt Gesehen-Haken und
    # Fortsetzen-Punkt je Adresse. Klassenattribut, weil die Suchen der Seiten in eigenen Threads laufen; gesetzt und
    # zurueckgenommen in xstream.py (_searchGlobal, searchAlter).
    _ignoreCall = False

    def __init__(self):
        params = dict()
        if not ParameterHandler._ignoreCall and len(sys.argv) >= 3 and len(sys.argv[2]) > 0:
            params = dict(parse_qsl(urlsplit(sys.argv[2]).query))
        self.__params = params
        # Namen, die aus dem Aufruf stammen und seither nicht gesetzt wurden (siehe inherited)
        self.__inherited = set(params)

    def getAllParameters(self):
        return self.__params

    def getValue(self, paramName):
        # returns value of one parameter as string, if parameter does not exists "False" is returned
        if self.exist(paramName):
            return self.__params[paramName]
        return False

    def exist(self, paramName):
        return paramName in self.__params

    def setParam(self, paramName, paramValue):
        # set the value of the parameter with the name "paramName" to "paramValue"
        # if there is no such parameter, the parameter is created
        paramValue = str(paramValue)
        self.__params.update({paramName: paramValue})
        self.__inherited.discard(paramName)

    def inherited(self):
        """Namen der Parameter, die unveraendert aus dem Aufruf stammen — die Seite hat sie nicht gesetzt.

        Ein Site-File baut die Eintraege einer Liste mit ParameterHandler() und setzt je Eintrag, was dieser braucht;
        was der Aufruf der Liste mitbrachte (das Genre, den Buchstaben, die Adresse der Liste), haengt sonst an jedem
        Eintrag. Am Wert laesst sich Geerbtes nicht erkennen (eine Seite kann denselben Namen selbst setzen, auch mit
        demselben Wert), deshalb wird gemerkt, was gesetzt wurde. gui.py laesst das Geerbte bei Film- und
        Serien-Eintraegen weg (__createItemUrl).
        """
        return set(k for k in self.__inherited if k in self.__params)

    def copy(self, without=()):
        """Kopie mit denselben Parametern, ohne die Namen in without; was geerbt ist, bleibt als geerbt gemerkt."""
        return ParameterHandler.from_dict({k: v for k, v in self.__params.items() if k not in without}, self.__inherited)

    def to_dict(self):
        """Serialize parameters to a plain dict for caching."""
        return dict(self.__params)

    @classmethod
    def from_dict(cls, data, inherited=()):
        """Reconstruct a ParameterHandler from a cached dict (inherited: Namen, die als geerbt gelten, siehe inherited)."""
        obj = cls.__new__(cls)
        obj.__params = dict(data) if data else {}
        obj.__inherited = set(k for k in inherited if k in obj.__params)
        return obj

    def getParameterAsUri(self):
        # Die Werte gehen unveraendert in die Adresse (urlencode) und kommen beim naechsten Aufruf ueber parse_qsl genauso
        # wieder heraus. Bis zum 02.11.2026 lief jeder Wert vorher durch unquote_plus — '+' wurde Leerzeichen, '%XX' wurde
        # aufgeloest: netzkino verlor die Kodierung seines Stream-Pfads (Leerzeichen in der Adresse), filmo das Plus im Titel
        # „Du+Ich", internetarchive bekam Vorschaubilder mit '/' statt '%2F' (Messung ueber alle 16 Sites, 02.11.2026).
        # Sites, die Adressen erst vor dem Abruf kodieren (movie2k, kellerkino, animetoast), bleiben richtig.
        outParams = dict()
        if 'params' in self.__params:
            del self.__params['params']
        if 'function' in self.__params:
            del self.__params['function']
        if 'title' in self.__params:
            del self.__params['title']
        if 'site' in self.__params:
            del self.__params['site']

        if len(self.__params) > 0:
            for param in self.__params:
                if len(self.__params[param]) < 1:
                    continue
                outParams[param] = self.__params[param]
            return urlencode(outParams)
        return 'params=0'
