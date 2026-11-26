# edit 2026-08-17

import json, re, requests
from resources.lib.utils import isBlockedHoster
from resources.lib.control import getSetting
from resources.lib.utils import getExtIDS

requests.packages.urllib3.disable_warnings()
session = requests.Session()


SITE_IDENTIFIER = 'filmo'
SITE_DOMAIN = 'filmo.to'
SITE_NAME = SITE_IDENTIFIER.upper()

class source:
    def __init__(self):
        self.priority = getSetting('provider.' + SITE_IDENTIFIER + '.priority', 100) # je kleiner der Wert um so höher die Priorität
        self.language = ['de']
        self.domain = getSetting('provider.' + SITE_IDENTIFIER + '.domain', SITE_DOMAIN)
        self.base_link = 'https://' + self.domain+ '/'
        self.search_link = self.base_link+'movies/%s'
        self.sources = []

    def run(self, titles, year, season=0, episode=0, imdb=''):
        if season >=1: return self.sources

        LANG_FLAGS = {
            'de': ('(DE)', '1'),
            'gb': ('(EN)', '2'),
            'us': ('(EN)', '2'),
            'jp': ('(JPN)', '3'),
        }
        _RE_CHIP = re.compile(
            r'data-p="([^"]+)"[^>]*>.*?provider-chip__name"[^>]*>\s*([^<]+?)\s*<'
            r'(.*?)(?=data-p="|</div></div>|$)', re.DOTALL)

        ids = getExtIDS(imdb, season)   # trakt.tv
        m = re.search(r'\d{4}$', ids['slug'])
        if m is not None and m.group()== str(year):
            sYear = ids['slug'].split('-')[-1]
            sSlug = ids['slug'].split('-'+sYear)[0]
            sUrl = self.search_link % sSlug
            get_resp = session.get(sUrl)    #, data=data)
            sHtmlContent = get_resp.text

            mToken = re.compile(r'<meta name="csrf-token" content="([^"]+)"').search(sHtmlContent)

            for sRow in re.compile(r'<div\s+class="provider-row"').split(sHtmlContent)[1:]:
                mFlag = re.compile(r'class="fi fi-(\w+)"').search(sRow)
                sFlag = mFlag.group(1).lower() if mFlag else ''
                sLabel, sLangPref = LANG_FLAGS.get(sFlag, ('', ''))
                ## nur DE durchsuchen
                if sLabel != '(DE)': continue
                URL_MINT = self.base_link + 'n'

                for sPayload, sHosterName, sRest in _RE_CHIP.findall(sRow):
                    sHosterName = sHosterName.strip()
                    if sHosterName == 'Byse': continue  # Byse - Probleme in Resolver

                    data = {
                        'p': sPayload
                    }
                    headers = {
                        'X-Requested-With': 'XMLHttpRequest',
                        'Referer': sUrl,
                        'X-CSRF-TOKEN': mToken.group(1),
                    }

                    sResponse = session.post(URL_MINT, data=data, headers=headers)
                    try:
                        sMintToken = json.loads(sResponse.text).get('x', '')
                    except:
                        continue
                    if not sMintToken: continue
                    get_resp = session.get('%s/%s' % (URL_MINT, sMintToken))  # , data=data)
                    sFinalHtml = get_resp.text
                    sStreamUrl = get_resp.url

                    if SITE_DOMAIN in sStreamUrl:
                        mExtern = re.compile(r'href="(https?://(?!(?:www\.)?%s)[^"]+)"' % re.escape(SITE_DOMAIN)).search(sFinalHtml or '')
                        if not mExtern: continue
                        sStreamUrl = mExtern.group(1)

                    # if sStreamUrl: print(sHosterName+'  '+sStreamUrl + '  ' + sLabel)
                    # else:
                    #     print(sHosterName+'  sFinalHtml: ' + sFinalHtml + ' | sStreamUrl:  keine sStreamUrl  ' + sLabel)
                    #     continue

                    isBlocked, hoster, url, prioHoster = isBlockedHoster(sStreamUrl, provider=SITE_IDENTIFIER)
                    if isBlocked: continue
                    self.sources.append({'source': hoster, 'quality': '720p', 'language': 'de', 'url': url, 'direct': True, 'priority': int(self.priority), 'prioHoster': prioHoster})

            return self.sources

    def resolve(self, url):
        return url
