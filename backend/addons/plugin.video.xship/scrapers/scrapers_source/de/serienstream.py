
#2023-03-20
# edit 2026-07-22

from resources.lib.control import  getSetting, urljoin, setSetting
from resources.lib.requestHandler import cRequestHandler
from scrapers.modules import cleantitle, dom_parser
from resources.lib.utils import isBlockedHoster
from scrapers.modules.tools import cParser

# import datetime
#date = datetime.date.today()
#current_year = int(date.strftime("%Y"))
try:
    from scrapers.modules.jsnprotect import cHelper
except:
    pass

SITE_IDENTIFIER = 'serienstream'
SITE_DOMAIN = '186.2.175.5'
SITE_NAME = SITE_IDENTIFIER.upper()

class source:
    def __init__(self):
        self.priority = getSetting('provider.' + SITE_IDENTIFIER + '.priority', 100)  # je kleiner der Wert um so höher die Priorität
        self.language = ['de']
        self.domain = getSetting('provider.' + SITE_IDENTIFIER + '.domain', SITE_DOMAIN)
        self.base_link = 'https://' + self.domain
        self.search_link = '/suche?term=%s&tab=shows'
        #self.search_link = '/ajax/seriesSearch?keyword=%s'
        # https://s.to/ajax/seriesSearch?keyword=rick%20and
        # https://186.2.175.5/ajax/seriesSearch?keyword=rick%20and
        self.sources = []

    def run(self, titles, year, season=0, episode=0, imdb='', hostDict=None):
        if season == 0: return self.sources
        try:
            # t = [cleantitle.get(i) for i in titles]
            # t = [cleantitle.get(i) for i in titles if i]
            #t = {'borgengefährlicheseilschaften', 'theburg'}
            if imdb:
                url = urljoin(self.base_link, self.search_link % imdb)
            else:
                url = urljoin(self.base_link, self.search_link % titles[0])

            oRequest = cRequestHandler(url)
            oRequest.cacheTime = 60*60*24*7
            sHtmlContent = oRequest.request()

            r = dom_parser.parse_dom(sHtmlContent, "div", attrs={"class": "results-group"})
            r = [i.content for i in r if i.attrs['data-group'] == 'shows']
            links = dom_parser.parse_dom(r, "a")
            links = list(set([(i.attrs["href"]) for i in links]))
            if len(links)==0: return self.sources
            elif len(links) == 1: url=links[0]
            else:
                t = [cleantitle.get(i) for i in titles if i]
                url = None
                for link in links:
                    if cleantitle.get(link.rsplit('/', 1)[-1]) in t:
                        url = link
                        break
                if not url:
                    url = links[0]

            if url:
                self.run2(url, year, season=season, episode=episode, hostDict=hostDict, imdb=imdb)
                return self.sources
        except:
            return self.sources
        return self.sources

    def run2(self, url, year, season=0, episode=0, hostDict=None, imdb=None):
        try:
            url = urljoin(self.base_link, url)
            url += '/staffel-%d/episode-%d' % (int(season), int(episode))
            sHtmlContent = cRequestHandler(url).request()
            # lr = dom_parser.parse_dom(sHtmlContent, 'div', attrs={'id': 'episode-links'})
            # pattern = r'data-play-url="([^"]+)"[^>]*data-provider-name="([^"]+)"[^>]*data-language-label="([^"]+)"'
            pattern = r'data-play-url="([^"]+)"[^>]*data-provider-name="([^"]+)"[^>]*data-language-label="(Deutsch)"'
            isMatch, matches = cParser.parse(sHtmlContent, pattern, ignoreCase=True)
            if not isMatch: # kein deutsch
                pattern = r'data-play-url="([^"]+)"[^>]*data-provider-name="([^"]+)"[^>]*data-language-label="([^"]+)"'
                isMatch, matches = cParser.parse(sHtmlContent, pattern, ignoreCase=True)
            if not isMatch: return self.sources

            import requests
            requests.packages.urllib3.disable_warnings()
            s = requests.Session()
            headers = {'User-Agent': cRequestHandler.RandomUA()}

            login, password = self._getLogin()
            URL_LOGIN = self.base_link + '/login'
            # URL_LOGIN = 'https://serienstream.to/login'
            payload = {'email': login, 'password': password}
            res = requests.get(URL_LOGIN, verify=False)
            s.post(URL_LOGIN, data=payload, cookies=res.cookies, verify=False)

            for play_url, provider_name, language in matches:
                redirect_url = urljoin(self.base_link, play_url)
                response = s.get(redirect_url, headers=headers, allow_redirects=True, verify=False, timeout=10)  #  headers=headers,
                sUrl=response.url
                quality = 'HD' # temp
                isBlocked, hoster, url, prioHoster = isBlockedHoster(sUrl, isResolve=True)
                if isBlocked: continue
                if language == 'Deutsch': language='de'
                self.sources.append({'source': provider_name, 'quality': quality, 'language': language, 'url': url , 'info': '', 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})
            return True
        except:
            return False

    def resolve(self, url):
        return url

    @staticmethod
    def _getLogin():
        login = getSetting(SITE_IDENTIFIER + '.user')
        password = getSetting(SITE_IDENTIFIER + '.pass')
        # Login ist optional — wenn Settings leer, wird mit leeren Strings gepostet
        return login, password

        # if login == '' or password == '':
        #     try:
        #         login = cHelper.UserName
        #         password = cHelper.PassWord
        #         setSetting('serienstream.user', login)
        #         setSetting('serienstream.pass', password)
        #         return login, password
        #     except:
        #         import xbmcgui, xbmcaddon
        #         AddonName = xbmcaddon.Addon().getAddonInfo('name')
        #         xbmcgui.Dialog().ok(AddonName,
        #                             "In den Einstellungen die Kontodaten (Login) für %s eintragen / überprüfen\nBis dahin wird %s von der Suche ausgeschlossen. Es erfolgt kein erneuter Hinweis!" % (
        #                             SITE_NAME, SITE_NAME))
        #         setSetting('provider.' + SITE_IDENTIFIER, 'false')
        #         exit()
        # else:
        #     return login, password
