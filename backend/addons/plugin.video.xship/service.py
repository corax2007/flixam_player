
# 2022-10-09
# edit 2026.06.19

import sys, re, datetime, os
import requests
from random import choice
from xbmcaddon import Addon
from xbmcvfs import translatePath
from urllib.parse import urlparse
try:
    from resources.lib.tools import logger
    isLogger=True
except:
    isLogger=False
    pass


addonInfo = Addon().getAddonInfo
addonPath = translatePath(addonInfo('path'))
addonVersion = addonInfo('version')
setSetting = Addon().setSetting
_getSetting = Addon().getSetting


# Domains auf die Sites NICHT redirecten sollen — wenn der Domain-Check einen
# Redirect dahin sieht, wird der Eintrag verworfen statt gespeichert.
# Zwei Listen (Struktur uebernommen aus xStream):
#   - WRONG_DOMAINS_EXACT: nur exakte Domain-Matches (kein Pattern-Block,
#     verhindert Falsch-Positives wie z.B. "mysite-maps.cc")
#   - WRONG_DOMAIN_PATTERNS: Substring-Match — fuer DNS-Block-Familien wo
#     ALLE Subdomains/Variationen geblockt werden sollen.
WRONG_DOMAINS_EXACT = (
    'site-maps.cc',                    # Generischer Stub-Page Redirect
)

WRONG_DOMAIN_PATTERNS = (
    'cuii.info',                       # CUII DNS-Sperre Deutschland (alle Subdomains)
    'drei.at',                         # Drei.at DNS-Sperre Oesterreich
    'magenta',                         # Magenta DNS-Sperre
    'telekom',                         # Telekom DNS-Sperre
    'vodafone',                        # Vodafone DNS-Sperre (CUII)
    'alliance4creativity',             # ACE Anti-Piracy Takedown (alle Sub-Variants)
    'streamingunity',                  # Streamingunity-Familie (alle TLD-Varianten)
)


def _isWrongDomain(domain):
    """Pruefen ob eine Domain als wrongDomain gilt.

    Returns True bei exaktem Match in WRONG_DOMAINS_EXACT oder bei
    Substring-Match in WRONG_DOMAIN_PATTERNS.
    """
    if not domain:
        return False
    if domain in WRONG_DOMAINS_EXACT:
        return True
    for pat in WRONG_DOMAIN_PATTERNS:
        if pat in domain:
            return True
    return False


# ResolveURL Auto-Update
RESOLVE_ADDON_DATA_PATH = translatePath(os.path.join('special://home/userdata/addon_data/script.module.resolveurl'))
RESOLVE_SHA = os.path.join(RESOLVE_ADDON_DATA_PATH, "update_sha")

def getSetting(Name, default=''):
    result = _getSetting(Name)
    if result: return result
    else: return default

# Html Cache beim KodiStart loeschen
def delHtmlCache():
    try:
        from resources.lib.requestHandler import cRequestHandler
        from time import time
        deltaDay = int(getSetting('cacheDeltaDay', '7'))
        deltaTime = 60*60*24*deltaDay # Tage
        currentTime = int(time())
        # einmalig
        if getSetting('delHtmlCache') == 'true':
            cRequestHandler('').clearCache()
            setSetting('lastdelhtml', str(currentTime))
            setSetting('delHtmlCache', 'false')
        # alle x Tage
        elif currentTime >= int(getSetting('lastdelhtml', '0')) + deltaTime:
            cRequestHandler('').clearCache()
            setSetting('lastdelhtml', str(currentTime))
    except:
        pass

# Scraper(Seiten) ein- / ausschalten
#  [(providername, domainname), ...]     providername identisch mit dateiname
def _getPluginData():
    from os import path, listdir
    sPluginFolder = path.join(addonPath, 'scrapers', 'scrapers_source', 'de')
    if sPluginFolder not in sys.path:
        sys.path.append(sPluginFolder)
    items = listdir(sPluginFolder)
    aFileNames=[]
    aPluginsData = []
    for sItemName in items:
        if sItemName.endswith('.py'): aFileNames.append(sItemName[:-3])
    for fileName in aFileNames:
        if fileName ==  '__init__': continue
        try:
            plugin = __import__(fileName, globals(), locals())
            aPluginsData.append({'domain': plugin.SITE_DOMAIN, 'provider': plugin.SITE_IDENTIFIER})
        except:
            pass
        finally:
            # Modul sofort entladen -- nur domain/provider werden gebraucht
            sys.modules.pop(fileName, None)
    # Scraper-Pfad entfernen (nicht dauerhaft in sys.path)
    try:
        sys.path.remove(sPluginFolder)
    except ValueError:
        pass
    return aPluginsData


def check_domains():
    """Prueft alle Provider-Domains parallel per HTTP HEAD.
    Ergebnisse werden in Kodi-Settings geschrieben
    (domain_status: 'ok', 'cf_blocked', 'dead')."""
    import time
    CHECK_INTERVAL = 60 * 90  # 90 Minuten in Sekunden
    currentTime = int(time.time())
    lastCheck = int(getSetting('lastDomainCheck', 0))
    if currentTime >= lastCheck + CHECK_INTERVAL:
        setSetting('lastDomainCheck', str(currentTime))
        domains = _getPluginData()
        import threading
        threads = []
        try:
            for item in domains:
                _domain = item['domain']
                _provider = item['provider']
                t = threading.Thread(target=_checkdomain, args=(_domain, _provider))
                threads += [t]
                t.start()
        except:
            pass
        for count, t in enumerate(threads):
            t.join(timeout=10)

def RandomUA():
    #Random User Agents aktualisiert 20.03.2026
    FF_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:148.0) Gecko/20100101 Firefox/148.0'
    OPERA_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 OPR/129.0.0.0'
    ANDROID_USER_AGENT = 'Mozilla/5.0 (Linux; Android 15; SM-S938U Build/AP3A.241005.015; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/146.0.0.0 Mobile Safari/537.36'
    EDGE_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36 Edg/145.0.0.0'
    CHROME_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
    SAFARI_USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15'

    _User_Agents = [FF_USER_AGENT, OPERA_USER_AGENT, EDGE_USER_AGENT, CHROME_USER_AGENT, SAFARI_USER_AGENT]
    return choice(_User_Agents)


def _checkdomain(_domain, _provider):
    """Prueft eine einzelne Provider-Domain per HTTP HEAD.
    Schreibt Ergebnis in Kodi-Settings: check (true/false), domain, health (ok/cf_blocked/dead).
    health-Setting wird von sync_providers() gelesen und in provider.domain_status gespeichert."""
    try:
        sourcefile = translatePath('special://home/addons/plugin.video.xship/scrapers/scrapers_source/de/%s.py' % _provider)
        pattern_date = r"edit.*?(\d{4}-\d{2}-\d{2})"
        pattern = r"SITE_DOMAIN.*?'([^']+)"
        date = datetime.date.today()
        current_day = date.strftime("%Y-%m-%d")
        with open(sourcefile, 'r') as f:
            # Read the file contents into a single variable
            contents = f.read()
        source_domain = re.search(pattern, contents).group(1)
        old_day = re.search(pattern_date, contents).group(1)
        requests.packages.urllib3.disable_warnings()  # weil verify = False - ansonst Fehlermeldungen im kodi log

        status_code = None
        health_status = 'unknown'  # Domain-Health fuer DB
        domain = getSetting('provider.' + _provider + '.domain', _domain)
        base_link = 'https://' + domain
        try:
            UA = RandomUA()
            headers = {
                "referer": base_link,
                "user-agent": UA,
            }
            r = requests.head(base_link, verify=False, headers=headers, allow_redirects=True, timeout=2)
            status_code = r.status_code
            if 300 <= status_code < 400:
                url = r.headers['Location']
                domain = urlparse(url).hostname
                health_status = 'ok'
                if source_domain != domain and not _isWrongDomain(domain):
                    new_contents = contents.replace(source_domain, domain)
                    new_contents = new_contents.replace(old_day, current_day)
                    with open(sourcefile, 'w') as f:
                        # actually write the lines
                        f.write(new_contents)
                setSetting('provider.' + _provider + '.domain', domain)

            elif status_code == 200:
                domain = urlparse(r.url).hostname
                health_status = 'ok'
                if source_domain != domain and not _isWrongDomain(domain):
                    new_contents = contents.replace(source_domain, domain)
                    new_contents = new_contents.replace(old_day, current_day)
                    with open(sourcefile, 'w') as f:
                        # actually write the lines
                        f.write(new_contents)

                setSetting('provider.' + _provider + '.domain', domain)
            else:
                if status_code in (403, 503, 520):
                    # Cloudflare-blockiert: 403 Forbidden, 503 Service Unavailable, 520 CF Error
                    health_status = 'cf_blocked'
                else:
                    health_status = 'dead'

                if source_domain != domain and not _isWrongDomain(domain):
                    setSetting('provider.' + _provider + '.domain', source_domain)  # falls es ein Domainupdate im Scrapersource gibt

        except:
            # Timeout oder Connection-Error → Domain nicht erreichbar
            health_status = 'dead'
            if source_domain != domain and not _isWrongDomain(domain):
                setSetting('provider.' + _provider + '.domain', source_domain)  # falls es ein Domainupdate im Scrapersource gibt

        finally:
            # Bekannte Fehl-Redirects (ISP-Sperren, CUII etc.)
            if _isWrongDomain(domain):
                setSetting('provider.' + _provider + '.domain', '')
                health_status = 'dead'
                if isLogger: logger.info(' -> [service]: Provider: %s / wrongDomain pre-check: %s, skipped' % (_provider, domain))
            # else:
            #     setSetting('provider.' + _provider + '.domain', domain)

            # Domain-Health als Kodi-Setting speichern (fuer sync_providers() → DB)
            setSetting('provider.' + _provider + '.health', health_status)
            if isLogger: logger.info(' -> [service]: Provider: %s / Statuscode: %s / Domain: %s, Health: %s' % (_provider, status_code, domain, health_status))
    except:
        pass


# Download Media Files
def downloadMedia():
    from os import path
    from xbmcvfs import delete
    from resources.lib.utils import download_url, unzip
    dest = translatePath(path.join(addonPath, 'resources'))
    contr = translatePath(path.join(addonPath, 'resources', 'media', 'next.png'))
    if not path.exists(contr):
        url = 'https://raw.githubusercontent.com/xsupdater/xsupdater/backup/media.zip'
        src = translatePath(path.join('special://temp', url.split('/')[-1]))
        download_url(url, src)
        src = translatePath(path.join('special://temp', url.split('/')[-1]))
        dirs = 'media'
        unzip(src, dest, folder=None)
        delete(src)


def ensure_youtube_api_keys():
    """Write bundled YouTube API keys to api_keys.json if not already configured.
    Only writes if no user key exists — never overwrites an existing configured key."""
    import json, base64, os
    try:
        yt_keys_path = translatePath('special://home/userdata/addon_data/plugin.video.youtube/api_keys.json')

        # If file exists, check whether a user key is already present
        if os.path.exists(yt_keys_path):
            try:
                with open(yt_keys_path, 'r') as f:
                    existing = json.load(f)
                if existing.get('keys', {}).get('user', {}).get('api_key', ''):
                    return  # user key already configured — do not touch
            except Exception:
                pass  # unreadable — fall through and write fresh

        # Write bundled fallback keys to api_keys.json.
        # JSON structure is visible as-is; values prefixed 'b64:' are decoded before writing.
        _template = """{
    "keys": {
        "user": {
            "api_key":       "b64:REPLACE_WITH_YOUR_YOUTUBE_API_KEY",
            "client_id":     "b64:REPLACE_WITH_YOUR_OAUTH_CLIENT_ID",
            "client_secret": "b64:REPLACE_WITH_YOUR_OAUTH_CLIENT_SECRET"
        },
        "developer": {}
    }
}"""

        def _resolve(obj):
            if isinstance(obj, dict):
                return {k: _resolve(v) for k, v in obj.items()}
            if isinstance(obj, str) and obj.startswith('b64:'):
                return base64.b64decode(obj[4:].encode()).decode()
            return obj

        yt_dir = os.path.dirname(yt_keys_path)
        if not os.path.exists(yt_dir):
            os.makedirs(yt_dir)

        with open(yt_keys_path, 'w') as f:
            json.dump(_resolve(json.loads(_template)), f, indent=4)
        if isLogger:
            logger.info('[service]: YouTube api_keys.json written')
    except Exception as e:
        if isLogger:
            logger.warning('[service]: Failed to write YouTube api_keys.json: %s' % str(e))


def _resolverUpdateAuto():
    """Resolver Update im Hintergrund beim Kodi-Start.

    Logik:
    - xStream installiert+aktiv?  → skip (xStream uebernimmt das Update)
    - sonst                       → Update + Notifications (erfolgreich/Fehler/kein Update)
    """
    try:
        # xStream aktiv → der uebernimmt das Update, xShip haelt sich raus
        import xbmc
        if xbmc.getCondVisibility('System.AddonIsEnabled(plugin.video.xstream)'):
            if isLogger:
                logger.info('[service]: xStream active — skipping resolver update (xStream handles it)')
            return

        # xShip uebernimmt das Update
        if not os.path.isfile(RESOLVE_SHA) or getSetting('githubUpdateResolver') == 'true':
            from resources.lib import updateManager
            from resources.lib.control import infoDialog
            status = updateManager.resolverUpdate()
            if status is True:
                infoDialog('ResolveURL Update erfolgreich.', icon='INFO', time=6000)
            elif status is False:
                infoDialog('Fehler bei ResolveURL Update.', icon='ERROR', sound=True)
            # status is None = kein Update verfuegbar → beim Auto-Update keine Notify (nur Noise beim Start)
    except Exception:
        if isLogger:
            import traceback
            logger.error('[service]: Resolver update error: %s' % traceback.format_exc())

def set_voe__prefer_hls(): # Resolver - set voe VoeResolver_prefer_hls true
    ## from xbmcaddon import Addon
    resolver = Addon(id='script.module.resolveurl')
    resolver.setSetting('VoeResolver_prefer_hls', 'true')


if __name__ == "__main__":
    import xbmc
    monitor = xbmc.Monitor()

    # InputStream Adaptive beim Start sicherstellen (wie 0.9er): fehlt es, nachinstallieren
    # und den Bestaetigungsdialog automatisch wegklicken. Beim Abspielen ist ISA dann da.
    from xbmc import getCondVisibility, executebuiltin
    if not getCondVisibility("System.HasAddon(inputstream.adaptive)"):
        executebuiltin('InstallAddon(inputstream.adaptive)')
        executebuiltin('SendClick(11)')

    # ResolveURL-Update + Domain-Check parallel
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=1) as executor:
        # Resolver-Update im Hintergrund (skippt wenn xStream aktiv, sonst mit Notifys)
        resolver_future = executor.submit(_resolverUpdateAuto)
        # Domain-Check parallel im Main-Thread
        check_domains()
        delHtmlCache()
        set_voe__prefer_hls()
        # Auf Resolver warten (max 13s: Commits-API 4s + ZIP-Download 8s + 1s Puffer)
        try:
            resolver_future.result(timeout=13)
        except Exception:
            if isLogger:
                logger.debug('[service]: Resolver update timed out or failed, continuing')

    # # Precache-Monitoring: alle 10s pruefen ob xShip aktiv + Precache noetig
    # # Thread laeuft hier im service.py-Invoker (persistent) — blockiert nichts
    # while not monitor.waitForAbort(10):
    #     try:
    #         from resources.lib.precacher import start_if_needed
    #         start_if_needed()
    #     except:
    #         pass

