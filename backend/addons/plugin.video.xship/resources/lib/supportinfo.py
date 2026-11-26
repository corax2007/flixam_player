
# edit 2025-06-17

import xbmc
from xbmcgui import Dialog
from xbmcaddon import Addon
from os import path, chdir
from resources.lib.control import translatePath, bold

def getRepofromAddonsDB(addonID):
    from sqlite3 import dbapi2 as database
    from glob import glob
    chdir(path.join(translatePath('special://database/')))
    addonsDB = path.join(translatePath('special://database/'), sorted(glob("Addons*.db"), reverse=True)[0])
    dbcon = database.connect(addonsDB)
    dbcur = dbcon.cursor()
    select = ("SELECT origin FROM installed WHERE addonID = '%s'") % addonID
    dbcur.execute(select)
    match = dbcur.fetchone()
    dbcon.close()
    if match and len(match) > 0:
         repo = match[0]
    else:
        repo = ''
    return repo


# Aufgeführte Plattformen zum Anzeigen der Systemplattform
def platform():
    if xbmc.getCondVisibility('system.platform.android'):
        return 'Android'
    elif xbmc.getCondVisibility('system.platform.linux'):
        return 'Linux'
    elif xbmc.getCondVisibility('system.platform.linux.Raspberrypi'):
        return 'Linux/RPi'
    elif xbmc.getCondVisibility('system.platform.windows'):
        return 'Windows'
    elif xbmc.getCondVisibility('system.platform.uwp'):
        return 'Windows UWP'
    elif xbmc.getCondVisibility('system.platform.osx'):
        return 'OSX'
    elif xbmc.getCondVisibility('system.platform.atv2'):
        return 'ATV2'
    elif xbmc.getCondVisibility('system.platform.ios'):
        return 'iOS'
    elif xbmc.getCondVisibility('system.platform.darwin'):
        return 'iOS'
    elif xbmc.getCondVisibility('system.platform.xbox'):
        return 'XBOX'
    elif xbmc.getCondVisibility('System.HasAddon(service.coreelec.settings)'):
        return 'CoreElec'
    elif xbmc.getCondVisibility('System.HasAddon(service.libreelec.settings)'):
        return 'LibreElec'
    elif xbmc.getCondVisibility('System.HasAddon(service.osmc.settings)'):
        return 'OSMC'

def getDNS(dns):
    status='Beschäftigt'
    loop = 1
    while status == 'Beschäftigt':
        if loop ==20: break # abbruch
        status=xbmc.getInfoLabel(dns)   # 'Network.DNS1Address'
        xbmc.sleep(10)
        loop += 1
    return status

# Support Informationen anzeigen
def pluginInfo():
    import json
    try:
        status = json.loads(xbmc.executeJSONRPC('{"jsonrpc":"2.0","method":"Addons.GetAddonDetails","id":1,"params": {"addonid":"%s", "properties": ["enabled"]}}' % 'service.xS.versioncheck'))
        versioncheck_active = status.get("result", {}).get("addon", {}).get("enabled", False)
    except:
        versioncheck_active = False
    
    repo_xship = getRepofromAddonsDB(Addon().getAddonInfo('id'))
    if repo_xship =='':
        if versioncheck_active:
            repo_xship = 'Installation durch "xS Version Check"'
        else: repo_xship = 'manuelle Installation'

    repo_resolver = getRepofromAddonsDB('script.module.resolveurl')
    if repo_resolver == '':
        if versioncheck_active:
            repo_resolver = 'Installation durch "xS Version Check"'
        else:
            repo_resolver = 'manuelle Installation'

    Dialog().textviewer('xShip Support Informationen',
                    #'Geräte Informationen:' + '\n'
                    'Kodi Version:  ' + xbmc.getInfoLabel('System.BuildVersion')[:4] + ' (Code Version: ' + xbmc.getInfoLabel('System.BuildVersionCode') + ')' + '\n'  # Kodi Version
                        + 'System Plattform:   {0}'.format(platform().title()) + '\n'  # System Plattform
                        + 'FreeMem: ' + str(xbmc.getFreeMem()) + 'MB \n'
                        + 'aktiver Skin: ' + xbmc.getSkinDir() + '\n'
                        + '\n'  # Absatz
                        + 'Plugin Informationen zu ' + bold(Addon().getAddonInfo('name')) + ':\n'  #
                        + 'Version:  ' + Addon().getAddonInfo('id') + ' - ' + Addon().getAddonInfo('version') + '\n'  # xShip ID und Version
                        + 'installiert aus Repository:  ' + repo_xship + '\n'
                        + '\n'
                        + 'Plugin Informationen zu ' + bold(Addon('script.module.resolveurl').getAddonInfo('name')) + ':\n'
                        + 'Version:  ' + Addon('script.module.resolveurl').getAddonInfo('id') + ' - ' + Addon('script.module.resolveurl').getAddonInfo('version') + '\n'  # Resolver ID und Version
                        + 'installiert aus Repository:  ' + repo_resolver + '\n'
                        + '\n'  # Absatz
                        # + 'DNS Informationen' + '\n'  # DNS Informationen
                        + 'aktiver DNS Nameserver1:' + ' ' + getDNS('Network.DNS1Address') + '\n'
                        + 'aktiver DNS Nameserver2:' + ' ' + getDNS('Network.DNS2Address') + '\n'
                        )
