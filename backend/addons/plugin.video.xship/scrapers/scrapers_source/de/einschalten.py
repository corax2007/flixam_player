
# einschalten
# 2024-09-05
# edit 2026-07-26

import json
from resources.lib.requestHandler import cRequestHandler
from resources.lib.utils import isBlockedHoster
from resources.lib.control import getSetting

SITE_IDENTIFIER = 'einschalten'
SITE_DOMAIN = 'einschalten.in'
SITE_NAME = SITE_IDENTIFIER.upper()

class source:
    def __init__(self):
        self.priority = getSetting('provider.' + SITE_IDENTIFIER + '.priority', 100) # je kleiner der Wert um so höher die Priorität
        self.language = ['de']
        self.domain = getSetting('provider.' + SITE_IDENTIFIER + '.domain', SITE_DOMAIN)
        self.base_link = 'https://' + self.domain
        self.search_link = self.base_link + '/search?query=%s'
        self.sources = []

    def run(self, titles, year, season=0, episode=0, imdb='', hostDict=None):
        from resources.lib.utils import getExtIDS
        ids = getExtIDS(imdb, season)  # trakt.tv season=0 movie result else shows result
        id = ids['tmdb']
        sUrl = self.base_link + '/api/movies/' + str(id) + '/watch'
        sHtmlContent = cRequestHandler(sUrl).request()
        if not 'streamUrl' in sHtmlContent: return self.sources
        jResult = json.loads(sHtmlContent)
        releaseName = jResult['releaseName']
        if '720p' in releaseName: quality = '720p'
        elif '1080p' in releaseName: quality = '1080p'
        else: quality = 'SD'
        streamUrl = jResult['streamUrl']

        isBlocked, hoster, url, prioHoster = isBlockedHoster(streamUrl, provider=SITE_IDENTIFIER)
        if isBlocked: return self.sources
        self.sources.append({'source': hoster, 'quality': quality, 'language': 'de', 'url': url, 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})
        return self.sources

    def resolve(self, url):
        return  url

