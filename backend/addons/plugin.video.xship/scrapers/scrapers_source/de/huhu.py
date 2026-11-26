# huhu
# edit 2026-08-01

import json
from resources.lib.utils import isBlockedHoster
from resources.lib.control import getSetting
from resources.lib.requestHandler import cRequestHandler
from resources.lib.utils import getExtIDS

SITE_IDENTIFIER = 'huhu'
SITE_DOMAIN = 'www.huhu.to'
SITE_NAME = SITE_IDENTIFIER.upper()

class source:
    def __init__(self):
        self.priority = getSetting('provider.' + SITE_IDENTIFIER + '.priority', 100) # je kleiner der Wert um so höher die Priorität
        self.language = ['de']
        self.domain = getSetting('provider.' + SITE_IDENTIFIER + '.domain', SITE_DOMAIN)
        self.base_link = 'https://' + self.domain+ '/'

    def run(self, titles, year, season=0, episode=0, imdb=''):
        sources = []
        ids = getExtIDS(imdb, season)   # trakt.tv season=0 movie result else shows result
        id = ids['tmdb']

        mediatype = 'series'
        if season == 0: mediatype = 'movie'
        data = {
            'language': 'de', 'region': 'DE',
            'type': mediatype, 'ids': {'tmdb_id': id}, 'name': ''
        }
        if mediatype == 'series':
            data['episode'] = {'ids': {}, 'season': season, 'episode': episode}

        oRequest = cRequestHandler(self.base_link + 'mediaurl-source.json', caching=False, ignoreErrors=True, method='POST', data=json.dumps(data))
        oRequest.addHeaderEntry('Content-Type', 'application/json; charset=utf-8')
        oRequest.addHeaderEntry('Referer', self.base_link)
        oRequest.removeNewLines(False)
        response = oRequest.request()
        data = json.loads(response)

        data = [i for i in data if i['languages']==['de']]
        for i in data:
            try:
                url = i['url']
                if 'filemoon' in url: continue
                language = i.get('languages', ['de'])[0]
                quality = i.get('tag', '720p')
                info = i.get('name', '')
                isBlocked, hoster, sUrl, prioHoster = isBlockedHoster(url)
                if isBlocked: continue
                sources.append({'source': hoster, 'quality': quality, 'language': language, 'url': sUrl, 'info': info, 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})
            except:
                pass
        return sources

    def resolve(self, url):
        return url
