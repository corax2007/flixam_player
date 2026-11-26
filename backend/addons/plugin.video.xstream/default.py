# -*- coding: utf-8 -*-
# Python 3

def _errorPlace(aFrames, sAddonPath):
    """Ort eines Fehlers fuer das Fehlerfenster: Datei ab dem Addon-Ordner und Zeile des letzten Schritts der
    Aufrufkette, der in diesem Addon liegt — dort beginnt die Suche, auch wenn der Fehler erst in Pythons
    Bibliothek oder in einem anderen Addon ausgeloest wurde."""
    import os
    sRoot = os.path.normcase(os.path.abspath(sAddonPath))
    for frame in reversed(aFrames):
        sFile = os.path.normcase(os.path.abspath(frame.filename))
        if sFile.startswith(sRoot + os.sep):
            return '%s:%d' % (sFile[len(sRoot) + 1:].replace(os.sep, '/'), frame.lineno)
    # kein Schritt unter dem Addon-Ordner (der Ordner ist ueber einen anderen Pfad eingebunden): der letzte
    # Schritt ueberhaupt, nur mit dem Dateinamen
    return '%s:%d' % (os.path.basename(aFrames[-1].filename), aFrames[-1].lineno) if aFrames else ''


def main():
    from xstream import parseUrl
    from resources.lib.tools import infoDialog
    from os.path import join
    import sys
    import platform
    import os

    from resources.lib.config import cConfig
    from resources.lib.logger import logger
    from xbmcvfs import translatePath

    _addonPath_ = translatePath(cConfig().getAddonInfo('path'))
    sys.path.append(join(_addonPath_, 'sites'))    
    

    try:
        parseUrl()
    except Exception as e:
        if str(e) == 'UserAborted':
            logger.info('User aborted list creation')
        else:
            import traceback
            import xbmc
            import xbmcgui
            logger.error(traceback.format_exc())
            # Kopf: Kodis eigener Text „Fehler" (257 ist eine Nummer von Kodi, das Addon hat keinen Text
            # dazu — bis zum 11.11.2026 blieb der Kopf deshalb leer). Darunter „Klasse: Meldung" und der Ort
            # im Addon; bis dahin stand dort ein Python-Tupel mit der drittletzten Zeile der Fehlerausgabe,
            # oft einer Zeile aus Pythons Bibliothek. Die Meldung laeuft durch die Maske des Logs: der Text
            # einer Ausnahme kann eine Adresse mit Schluessel oder einen Pfad mit dem Kontonamen tragen.
            sText = logger.mask('%s: %s' % (e.__class__.__name__, e))
            sPlace = _errorPlace(traceback.extract_tb(e.__traceback__), _addonPath_)
            xbmcgui.Dialog().ok(xbmc.getLocalizedString(257), sText + ('\n' + sPlace if sPlace else ''))

if __name__ == "__main__":
    main()
