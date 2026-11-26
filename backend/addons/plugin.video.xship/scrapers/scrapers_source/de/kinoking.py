# kinoking
# 2026-02-15
# edit 2026-08-20

import json, re
import concurrent.futures
from resources.lib.requestHandler import cRequestHandler
from resources.lib.utils import isBlockedHoster
from resources.lib.control import getSetting
from scrapers.modules import cleantitle
from scrapers.modules.tools import cParser

SITE_IDENTIFIER = 'kinoking'
SITE_DOMAIN = 'kinoking.cc'
SITE_NAME = SITE_IDENTIFIER.upper()

class source:
    def __init__(self):
        self.priority = getSetting('provider.' + SITE_IDENTIFIER + '.priority', 100) # je kleiner der Wert um so höher die Priorität
        self.language = ['de']
        self.domain = getSetting('provider.' + SITE_IDENTIFIER + '.domain', SITE_DOMAIN)
        self.base_link = 'https://' + self.domain

        self.search_link = self.base_link + '/index.php?search=%s'
        self.sources = []

    def run(self, titles, year, season=0, episode=0, imdb='', hostDict=None):
        t = [cleantitle.get(i) for i in set(titles) if i]
        links = []
        hoster = []
        for sSearchText in set(titles):
            try:
                URL_SEARCH = self.search_link % sSearchText
                # URL_SEARCH = 'https://kinoking.cc/index.php?search=spider-man'
                oRequest = cRequestHandler(URL_SEARCH, caching=True)
                oRequest.cacheTime = 60 * 60 * 24
                sHtmlContent = oRequest.request()

                if season == 0: mediatype = 'movie'
                else: mediatype = 'series'
                pattern = r'data-id="(\d+)".*?data-type="(movie|series).*?[^>].*?data-title="([^"]*)"[^>]'
                isMatch, aResult = cParser.parse(sHtmlContent, pattern)
                filtered_results = {(id, sName) for id, sType, sName in aResult if sType == mediatype}
                for id, sName in filtered_results:
                    if cleantitle.get(sName) in t:
                        if season == 0:
                            url = self.base_link + '/movie.php?id=%s' % id
                        else:
                            url = self.base_link + '/series.php?id=%s' % id
                        if url not in links:
                            links.append(url)
                if len(links) > 0: break
            except:
                continue

        if len(links) == 0: return self.sources

        if season == 0:
            self.list = []
            with concurrent.futures.ThreadPoolExecutor() as executor:
                futures = [executor.submit(self.chk_year, i, year) for i in links]
                concurrent.futures.wait(futures)
            if len(self.list) > 0: hoster = self.list
        else:
            try:
                sHtmlContent = cRequestHandler(links[0]).request()
                pattern = r'const allEpisodesData = (\[.*?\]);'
                isMatch, sJson = cParser.parseSingleResult(sHtmlContent, pattern)
                episodes=json.loads(sJson)
                for ep in episodes:
                    if ep.get('season_number') == season and ep.get('episode_number') == episode:
                        sVideoLinks = ep.get('video_links', '')
                        if sVideoLinks:
                            aLinks = [l.strip() for l in sVideoLinks.split(',') if l.strip()]
                            for sLink in aLinks:
                                if 'youtube' in sLink: continue
                                if sLink.startswith('//'): sLink = 'https:' + sLink
                                hoster.append(sLink)

                # episodeId = re.search(r'playEpisode\((\d+)', sHtmlContent).group(1)
                # api_url = self.base_link + '/api/episode-navigation.php?episode_id=%s' % episodeId
                # req = cRequestHandler(api_url).request()
                # jreq = json.loads(req)['links']
                # hoster.append(jreq[episode - 1])
            except:
                pass

        count = 0
        max_search = 0

        for link in set(hoster):
            # print(link)
            if 'cinesrc' in link: continue  # gibt keinen Resolver
            max_search += 1
            if max_search == 8: break
            # print(link)
            isBlocked, sDomain, sUrl, prioHoster = isBlockedHoster(link)
            if isBlocked: continue
            self.sources.append({'source': sDomain, 'quality': 'HD', 'language': 'de', 'url': sUrl, 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})
            count += 1
            if count >= 3: break  # Max 3 funktionierende Quellen
        return self.sources

    def resolve(self, url):
        return url

    def chk_year(self, url, year):
        try:
            oRequest = cRequestHandler(url)
            oRequest.cacheTime = 60 * 60
            sHtmlContent = oRequest.request()
            found_year = re.search(r'<title>.*?(\d{4})', sHtmlContent).group(1)
            if int(found_year) == year:
                pattern = r'<a href="(\?id=\d+&link=[^"]+)'
                isMatch, aResult = cParser.parse(sHtmlContent, pattern)
                if isMatch:
                    for sLink in aResult:
                        sLink = self.base_link + '/movie.php' + sLink if sLink.startswith('?') else sLink
                        sHtml = cRequestHandler(sLink, caching=True).request()
                        pattern2 = r'target\.innerHTML.*?src="([^"]+)"'
                        isMatch2, aResult2 = cParser.parse(sHtml, pattern2)
                        if isMatch2:
                            self.list.append(aResult2[0])
        except:
            pass
