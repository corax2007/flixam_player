# movie2k
# 2022-11-04 (fix: URL-Limit vor isBlockedHoster, verhindert 3-Minuten-Lauf)
# edit 2026-05-22

# import re
# import json
from resources.lib.control import getSetting
from resources.lib.requestHandler import cRequestHandler
from scrapers.modules.tools import cParser
from resources.lib.utils import isBlockedHoster
from scrapers.modules import cleantitle, dom_parser, source_utils

SITE_IDENTIFIER = 'movie2k'
SITE_DOMAIN = 'movie2k.cx'
SITE_NAME = SITE_IDENTIFIER.upper()

class source:
    def __init__(self):
        self.priority = getSetting('provider.' + SITE_IDENTIFIER + '.priority', 100) # je kleiner der Wert um so höher die Priorität
        self.language = ['de']
        self.domain = getSetting('provider.' + SITE_IDENTIFIER + '.domain', SITE_DOMAIN)
        self.base_link = 'https://' + self.domain
        self.search_link = self.base_link + '/search?q=%s'
        self.sources = []

    def run(self, titles, year, season=0, episode=0, imdb='', hostDict=None):
        _RE_ENTRY = (r'<td valign="top">\s*<h2[^>]*>\s*(?:<!--[^>]*-->\s*)?'
                     r'<a href="([^"]+)"[^>]*>(.*?)</a>(.*?)</h2>\s*')

        try:
            t = [cleantitle.get(i) for i in titles if i]
            aEntries = []
            for title in titles:
                query = self.search_link % title.replace(' ', '%20')  # quote(title)
                oRequest = cRequestHandler(query)
                oRequest.cacheTime = 60 * 60 * 24 * 7
                sHtmlContent = oRequest.request()
                isMatch, aResult = cParser.parse(sHtmlContent, _RE_ENTRY)
                if not isMatch: continue
                seen = []
                for aEntry in aResult:
                    if aEntry[0] in seen: continue
                    if 'SERIE' in aEntry[1]: sName=aEntry[1].split('</strong>')[1].strip()
                    else: sName=aEntry[1].strip()
                    if not cleantitle.get(sName) in t: continue
                    seen.append(aEntry[0])
                    aEntries.append(aEntry[0])

                total = len(aEntries)
                if total >= 1: break

            for link in aEntries:
                if season == 0: sUrl = self.base_link + link
                else: sUrl = self.base_link + link + '&season=%s'% season
                sHtmlContent = cRequestHandler(sUrl, caching=False).request()
                if season == 0:
                    isMatch, aResult = cParser.parse(sHtmlContent, r'<option value="(http[^"]+)"[^>]*data-quality="([^"]*)"')
                    if not isMatch: return self.sources
                    for sHosterUrl, sQuality in aResult:
                        isBlocked, hoster, url, prioHoster = isBlockedHoster(sHosterUrl, provider=SITE_IDENTIFIER)
                        if isBlocked: continue
                        self.sources.append({'source': hoster, 'quality': sQuality, 'language': 'de', 'url': url, 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})
                else:
                    r = dom_parser.parse_dom(sHtmlContent, 'select', attrs={'id': 'episode-select'})
                    r = dom_parser.parse_dom(r[0].content, 'option')
                    episodes = [(i.attrs['value'], i.content) for i in r]
                    sEpisodeId = [i[0] for i in episodes if 'E%s' % episode in i[1]][0]
                    isMatch, sContainer = cParser.parseSingleResult(sHtmlContent, r'data-episode-id="%s"(.*?)</table>' % cParser.escape(sEpisodeId))
                    if not isMatch: return self.sources
                    isMatch, aResult = cParser.parse(sContainer, r'''loadMirror\('(http[^']+)'\)"\s*data-host="[^"]+"\s*data-mirror="true"''')
                    if not isMatch: return self.sources
                    for sHosterUrl in aResult:
                        isBlocked, hoster, url, prioHoster = isBlockedHoster(sHosterUrl, provider=SITE_IDENTIFIER)
                        if isBlocked: continue
                        self.sources.append({'source': hoster, 'quality': '720p', 'language': 'de', 'url': url, 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})

        except Exception:
            return self.sources

        return self.sources


    def resolve(self, url):
        return url
