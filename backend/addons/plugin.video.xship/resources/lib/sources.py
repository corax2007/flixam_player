

# edit 2026-04-08

import sys
import re,json,random,time
from concurrent.futures import ThreadPoolExecutor
from resources.lib import log_utils, control
from resources.lib.utils import get_titles
from resources.lib.control import py2_decode, py2_encode, quote_plus, parse_qsl
import resolveurl as resolver
# from functools import reduce
from resources.lib.control import getKodiVersion

if int(getKodiVersion()) >= 20: from resources.lib.listitem import ListItemInfoTag

# für self.sysmeta - zur späteren verwendung als meta
_params = dict(parse_qsl(sys.argv[2].replace('?',''))) if len(sys.argv) > 1 else dict()


def _bold(text):
    # Alias auf den zentralen Helper (control.bold) -- selbe Toggle-Logik fuer alle Dateien.
    return control.bold(text)


class sources:
    def __init__(self):
        self.getConstants()
        self.sources = []
        self.current = int(time.time())
        if 'sysmeta' in _params: self.sysmeta = _params['sysmeta'] # string zur späteren verwendung als meta
        self.watcher = False
        self.executor = ThreadPoolExecutor(max_workers=20)
        self.url = None

    def get(self, params):
        data = json.loads(params['sysmeta'])
        self.mediatype = data.get('mediatype')
        self.aliases = data.get('aliases') if 'aliases' in data else []

        title = py2_encode(data.get('title'))
        originaltitle = py2_encode(data.get('originaltitle')) if 'originaltitle' in data else title
        year = data.get('year') if 'year' in data else None
        imdb = data.get('imdb_id') if 'imdb_id' in data else data.get('imdbnumber') if 'imdbnumber' in data else None
        if not imdb and 'imdb' in data: imdb = data.get('imdb')
        tmdb = data.get('tmdb_id') if 'tmdb_id' in data else None
        #if tmdb and not imdb: print 'hallo' #TODO
        season = data.get('season') if 'season' in data else 0
        episode = data.get('episode') if 'episode' in data else 0
        premiered = data.get('premiered') if 'premiered' in data else None
        meta = params['sysmeta']
        select = data.get('select') if 'select' in data else None
        return title, year, imdb, season, episode, originaltitle, premiered, meta, select

    def play(self, params):
        title, year, imdb, season, episode, originaltitle, premiered, meta, select = self.get(params)
        try:
            url = None
            #Liste der gefundenen Streams
            items = self.getSources(title, year, imdb, season, episode, originaltitle, premiered)
            select = control.getSetting('hosts.mode') if select == None else select
            ## unnötig
            #select = '1' if control.getSetting('downloads') == 'true' and not (control.getSetting('download.movie.path') == '' or control.getSetting('download.tv.path') == '') else select

            # # TODO überprüfen wofür mal gedacht
            # if control.window.getProperty('PseudoTVRunning') == 'True':
            #     return control.resolveUrl(int(sys.argv[1]), True, control.item(path=str(self.sourcesDirect(items))))

            if len(items) > 0:
                # Auswahl Verzeichnis
                if select == '1' and 'plugin' in control.infoLabel('Container.PluginName'):
                    control.window.clearProperty(self.itemsProperty)
                    control.window.setProperty(self.itemsProperty, json.dumps(items))
                    
                    control.window.clearProperty(self.metaProperty)
                    control.window.setProperty(self.metaProperty, meta)
                    control.sleep(2)
                    return control.execute('Container.Update(%s?action=addItem&title=%s)' % (sys.argv[0], quote_plus(title)))
                # Auswahl Dialog
                elif select == '0' or select == '1':
                    url = self.sourcesDialog(items)
                    if  url == 'close://': return
                # Autoplay
                else:
                    url = self.sourcesDirect(items)

            if url == None: return self.errorForSources()

            try: meta = json.loads(meta)
            except: pass

            from resources.lib.player import player
            player().run(title, url, meta)
        except Exception as e:
            log_utils.log('Error %s' % str(e), log_utils.LOGERROR)


# Liste gefundene Streams Indexseite|Hoster
    def addItem(self, title):
        control.playlist.clear()

        items = control.window.getProperty(self.itemsProperty)
        items = json.loads(items)
        if items == None or len(items) == 0: control.idle() ; sys.exit()

        sysaddon = sys.argv[0]
        syshandle = int(sys.argv[1])
        systitle = sysname = quote_plus(title)

        meta = control.window.getProperty(self.metaProperty)
        meta = json.loads(meta)
#TODO
        if meta['mediatype'] == 'movie':
            # downloads = True if control.getSetting('downloads') == 'true' and control.exists(control.translatePath(control.getSetting('download.movie.path'))) else False
            downloads = True if control.getSetting('downloads') == 'true' and control.getSetting('download.movie.path') else False
        else:
            # downloads = True if control.getSetting('downloads') == 'true' and control.exists(control.translatePath(control.getSetting('download.tv.path'))) else False
            downloads = True if control.getSetting('downloads') == 'true' and control.getSetting('download.tv.path') else False

        addonPoster, addonBanner = control.addonPoster(), control.addonBanner()
        addonFanart, settingFanart = control.addonFanart(), control.getSetting('fanart')

        if 'backdrop_url' in meta and 'http' in meta['backdrop_url']: fanart = meta['backdrop_url']
        elif 'fanart' in meta and 'http' in meta['fanart']: fanart = meta['fanart']
        else: fanart = addonFanart

        if 'cover_url' in meta and 'http' in meta['cover_url']: poster = meta['cover_url']
        elif 'poster' in meta and 'http' in meta['poster']: poster = meta['poster']
        else:  poster = addonPoster
        sysimage = poster

        if 'season' in meta and 'episode' in meta:
            sysname += quote_plus(' S%02dE%02d' % (int(meta['season']), int(meta['episode'])))
        elif 'year' in meta:
            sysname += quote_plus(' (%s)' % meta['year'])

        for i in range(len(items)):
            try:
                label = items[i]['label']
                syssource = quote_plus(json.dumps([items[i]]))

                item = control.item(label=label, offscreen=True)
                item.setProperty('IsPlayable', 'true')
                item.setArt({'poster': poster, 'banner': addonBanner})
                if settingFanart == 'true': item.setProperty('Fanart_Image', fanart)

                cm = []
                cm.append(("Medien-Info", 'RunPlugin(%s?action=mediaInfo&source=%s)' % (sysaddon, syssource)))
                cm.append(('Einstellungen Plugin', 'RunPlugin(%s?action=addonSettings)' % sysaddon))
                cm.append(('Einstellungen ResolveURL', 'RunPlugin(%s?action=resolverSettings)' % sysaddon))
                item.addContextMenuItems(cm)

                url = "%s?action=playItem&title=%s&source=%s" % (sysaddon, systitle, syssource)

                ## https://codedocs.xyz/AlwinEsch/kodi/group__python__xbmcgui__listitem.html  # ga0b71166869bda87ad744942888fb5f14
                name = '%s%sStaffel: %s   Episode: %s' % (title, "\n", meta['season'], meta['episode']) if 'season' in meta else title
                plot = meta['plot'] if 'plot' in meta and len(meta['plot'].strip()) >= 1 else ''
                plot = '[COLOR blue]%s[/COLOR]%s%s' % (name, "\n\n", py2_encode(plot))

                if 'duration' in meta:
                    infolable = {'plot': plot,'duration': meta['duration']}
                else:
                    infolable = {'plot': plot}

                # TODO
                # if 'cast' in meta and meta['cast']: item.setCast(meta['cast'])
                # # # remove unsupported InfoLabels
                meta.pop('cast', None)  # ersetzt durch item.setCast(i['cast'])
                meta.pop('number_of_seasons', None)
                meta.pop('imdb_id', None)
                meta.pop('tvdb_id', None)
                meta.pop('tmdb_id', None)

                video_streaminfo = {}
                audio_streaminfo = {}
                if "4k" in items[i]['quality'].lower():
                    video_streaminfo.update({'width': 3840, 'height': 2160})
                elif "1080p" in items[i]['quality'].lower():
                    video_streaminfo.update({'width': 1920, 'height': 1080})
                elif "hd" in items[i]['quality'].lower() or "720p" in items[i]['quality'].lower():
                    video_streaminfo.update({'width': 1280, 'height': 720})
                else:
                    # video_streaminfo.update({"width": 720, "height": 576})
                    video_streaminfo.update({})
                probe = items[i].get('_probe')
                if probe:
                    if probe.get('width') > 5: video_streaminfo.update({'width': probe.get('width'), 'height': probe.get('height')})
                    video_streaminfo.update({'codec': probe.get('video_codec')})
                    if probe.get('has_audio')and probe.get('audio_codec'):
                        audio_streaminfo.update({'codec': probe.get('audio_codec').split(',')[0]})
                    else:
                        audio_streaminfo.update({'codec': ''})

                    if probe.get('duration'):
                        dp = probe['duration'].split(':')
                        try:
                            if len(dp) == 3:
                                dur_secs = int(dp[0]) * 3600 + int(dp[1]) * 60 + int(dp[2])
                            elif len(dp) == 2:
                                dur_secs = int(dp[0]) * 60 + int(dp[1])
                            else:
                                dur_secs = 0
                            if dur_secs > 0:
                                infolable['duration'] = dur_secs
                        except (ValueError, IndexError):
                            pass
                else:
                    ## Quality Video Stream from source.append quality - items[i]['quality']
                    # video_streaminfo ={}
                    # if "4k" in items[i]['quality'].lower():
                    #     video_streaminfo.update({'width': 3840, 'height': 2160})
                    # elif "1080p" in items[i]['quality'].lower():
                    #     video_streaminfo.update({'width': 1920, 'height': 1080})
                    # elif "hd" in items[i]['quality'].lower() or "720p" in items[i]['quality'].lower():
                    #     video_streaminfo.update({'width': 1280,'height': 720})
                    # else:
                    #     # video_streaminfo.update({"width": 720, "height": 576})
                    #     video_streaminfo.update({})

                    ## Codec for Video Stream from extra info - items[i]['info']
                    if 'hevc' in items[i]['label'].lower():
                        video_streaminfo.update({'codec': 'hevc'})
                    elif '265' in items[i]['label'].lower():
                        video_streaminfo.update({'codec': 'h265'})
                    elif 'mkv' in items[i]['label'].lower():
                        video_streaminfo.update({'codec': 'mkv'})
                    elif 'mp4' in items[i]['label'].lower():
                        video_streaminfo.update({'codec': 'mp4'})
                    else:
                        # video_streaminfo.update({'codec': 'h264'})
                        video_streaminfo.update({'codec': ''})

                    ## Quality & Channels Audio Stream from extra info - items[i]['info']
                    # audio_streaminfo = {}
                    if 'dts' in items[i]['label'].lower():
                        audio_streaminfo.update({'codec': 'dts'})
                    elif 'plus' in items[i]['label'].lower() or 'e-ac3' in items[i]['label'].lower():
                        audio_streaminfo.update({'codec': 'eac3'})
                    elif 'dolby' in items[i]['label'].lower() or 'ac3' in items[i]['label'].lower():
                        audio_streaminfo.update({'codec': 'ac3'})
                    else:
                        # audio_streaminfo.update({'codec': 'aac'})
                        audio_streaminfo.update({'codec': ''})

                    ## Channel update ##
                    if '7.1' in items[i].get('info','').lower():
                        audio_streaminfo.update({'channels': 8})
                    elif '5.1' in items[i].get('info','').lower():
                        audio_streaminfo.update({'channels': 6})
                    else:
                        # audio_streaminfo.update({'channels': 2})
                        audio_streaminfo.update({'channels': ''})

                if int(getKodiVersion()) <= 19:
                    item.setInfo(type='Video', infoLabels=infolable)
                    item.addStreamInfo('video', video_streaminfo)
                    item.addStreamInfo('audio', audio_streaminfo)
                else:
                    info_tag = ListItemInfoTag(item, 'video')
                    info_tag.set_info(infolable)
                    stream_details = {
                        'video': [video_streaminfo],
                        'audio': [audio_streaminfo]}
                    info_tag.set_stream_details(stream_details)
                    # info_tag.set_cast(aActors)

                control.addItem(handle=syshandle, url=url, listitem=item, isFolder=False)
            except:
                pass

        control.idle()  # ok
        control.content(syshandle, 'videos')
        control.plugincategory(syshandle, control.addonVersion)
        control.endofdirectory(syshandle, cacheToDisc=True)


    def playItem(self, title, source):
        isDebug = False
        if isDebug: log_utils.log('start playItem', log_utils.LOGWARNING)
        try:
            meta = control.window.getProperty(self.metaProperty)
            meta = json.loads(meta)
            item = json.loads(source)[0]
            if item['source'] == None: raise Exception()
            # control.idle() #ok
            header = control.addonInfo('name')
            progressDialog = control.progressDialog if control.getSetting('progress.dialog') == '0' else control.progressDialogBG
            progressDialog.create(header, '')
            progressDialog.update(0)

            future = self.executor.submit(self.sourcesResolve, item)

            # edit for captcha
            waiting_time = start_time =30
            if item['provider'] == 'burningseries': waiting_time = start_time = int(control.getSetting('captcha.timeout', '120'))
            while waiting_time > 0:
                try:
                    if control.abortRequested: return sys.exit()
                    if progressDialog.iscanceled(): return progressDialog.close()
                except:
                    pass
                if future.done(): break
                control.sleep(1)
                waiting_time = waiting_time - 1
                progressDialog.update(int(100 - 100. / start_time * waiting_time), str(item['label']))
                if control.condVisibility('Window.IsActive(virtualkeyboard)') or \
                        control.condVisibility('Window.IsActive(yesnoDialog)'):
                        # or control.condVisibility('Window.IsActive(PopupRecapInfoWindow)'):
                    waiting_time = waiting_time + 1  # dont count down while dialog is presented
                if future.done(): break

            try: progressDialog.close()
            except: pass

            control.execute('Dialog.Close(virtualkeyboard)')
            control.execute('Dialog.Close(yesnoDialog)')

            if isDebug: log_utils.log('playItem url: %s' % self.url, log_utils.LOGWARNING)
            if self.url == None:
                #self.errorForSources()
                return

            from resources.lib.player import player
            player().run(title, self.url, meta)
            return self.url
        except Exception as e:
            log_utils.log('Error %s' % str(e), log_utils.LOGERROR)


    def getSources(self, title, year, imdb, season, episode, originaltitle, premiered, quality='HD', timeout=30):
        #TODO
        control.idle() #ok
        progressDialog = control.progressDialog if control.getSetting('progress.dialog') == '0' else control.progressDialogBG
        progressDialog.create(control.addonInfo('name'), '')
        progressDialog.update(0)
        progressDialog.update(0, "Quellen werden vorbereitet")
        content_typ = 'movies' if season == 0 or season == '' or season == None else 'shows'
        titles = get_titles(title, originaltitle, imdb, content_typ)

        sourceDict = [(i[0], i[1], i[1].priority) for i in self.provider_sources]
        random.shuffle(sourceDict)
        sourceDict = sorted(sourceDict, key=lambda i: int(i[2]))    # Reihenfolge Provider

        futures = {self.executor.submit(self._getSource, titles, year, season, episode, imdb, provider[0], provider[1]): provider[0] for provider in sourceDict}

        try: timeout = int(control.getSetting('scrapers.timeout'))
        except: pass
        
        quality = control.getSetting('hosts.quality')
        if quality == '': quality = '0'

        source_4k = 0
        source_1080 = 0
        source_720 = 0
        source_sd = 0
        total = 0
        total_format = '[COLOR %s]%s[/COLOR]' if control.getSetting('bold_labels') == 'false' else '[COLOR %s][B]%s[/B][/COLOR]'
        pdiag_format = ' 4K: %s | 1080p: %s | 720p: %s | SD: %s | %s: %s                                         '.split('|')


        for i in range(0, 4 * timeout):
            try:
                if control.abortRequested: return sys.exit()
                try:
                    if progressDialog.iscanceled(): break
                except:
                    pass

                if len(self.sources) > 0:
                    if quality in ['0']:
                        source_4k = len([e for e in self.sources if e['quality'] == '4K'])
                        source_1080 = len([e for e in self.sources if e['quality'] in ['1440p','1080p']])
                        source_720 = len([e for e in self.sources if e['quality'] in ['720p','HD']])
                        source_sd = len([e for e in self.sources if e['quality'] not in ['4K','1440p','1080p','720p','HD']])
                    elif quality in ['1']:
                        source_1080 = len([e for e in self.sources if e['quality'] in ['1440p','1080p']])
                        source_720 = len([e for e in self.sources if e['quality'] in ['720p','HD']])
                        source_sd = len([e for e in self.sources if e['quality'] not in ['4K','1440p','1080p','720p','HD']])
                    elif quality in ['2']:
                        source_1080 = len([e for e in self.sources if e['quality'] in ['1080p']])
                        source_720 = len([e for e in self.sources if e['quality'] in ['720p','HD']])
                        source_sd = len([e for e in self.sources if e['quality'] not in ['4K','1440p','1080p','720p','HD']])
                    elif quality in ['3']:
                        source_720 = len([e for e in self.sources if e['quality'] in ['720p','HD']])
                        source_sd = len([e for e in self.sources if e['quality'] not in ['4K','1440p','1080p','720p','HD']])
                    else:
                        source_sd = len([e for e in self.sources if e['quality'] not in ['4K','1440p','1080p','720p','HD']])
                    
                    total = source_4k + source_1080 + source_720 + source_sd

                source_4k_label = total_format % ('red', source_4k) if source_4k == 0 else total_format % ('lime', source_4k)
                source_1080_label = total_format % ('red', source_1080) if source_1080 == 0 else total_format % ('lime', source_1080)
                source_720_label = total_format % ('red', source_720) if source_720 == 0 else total_format % ('lime', source_720)
                source_sd_label = total_format % ('red', source_sd) if source_sd == 0 else total_format % ('lime', source_sd)
                source_total_label = total_format % ('red', total) if total == 0 else total_format % ('lime', total)

                try:
                    info = [name.upper() for future, name in futures.items() if not future.done()]
                    string4 = "Total"
                    if quality in ['0']:
                        line1 = '|'.join(pdiag_format) % (source_4k_label, source_1080_label, source_720_label, source_sd_label, str(string4), source_total_label)
                    elif quality in ['1']:
                        line1 = '|'.join(pdiag_format[1:]) % (source_1080_label, source_720_label, source_sd_label, str(string4), source_total_label)
                    elif quality in ['2']:
                        line1 = '|'.join(pdiag_format[1:]) % (source_1080_label, source_720_label, source_sd_label, str(string4), source_total_label)
                    elif quality in ['3']:
                        line1 = '|'.join(pdiag_format[2:]) % (source_720_label, source_sd_label, str(string4), source_total_label)
                    else:
                        line1 = '|'.join(pdiag_format[3:]) % (source_sd_label, str(string4), source_total_label)

                    if (i / 2) < timeout:
                        string = "Verbleibende Indexseiten: %s"
                    else:
                        string = 'Waiting for: %s'

                    if len(info) > 6: line = line1 + string % (str(len(info)))
                    elif len(info) > 1: line = line1 + string % (', '.join(info))
                    elif len(info) == 1: line = line1 + string % (''.join(info))
                    else: line = line1 + 'Suche beendet!'

                    percent = int(100 * float(i) / (2 * timeout) + 1)
                    progressDialog.update(max(1, percent), line)

                    if len(info) == 0: break
                    elif str(control.getSetting('hosts.limit')) == 'true':
                        if total >= int(control.getSetting('hosts.limit.num')): break

                    # if total >= 3 or len(info) == 0: break

                except Exception as e:
                    log_utils.log('Exception Raised: %s' % str(e), log_utils.LOGERROR)

                control.sleep(1)
            except:
                pass

        time.sleep(1)   # sek

        try: progressDialog.close()
        except: pass
        self.sourcesFilter()
        return self.sources


    def _getSource(self, titles, year, season, episode, imdb, source, call):
        try:
            sources = call.run(titles, year, season, episode, imdb)  # kasi self.hostDict
            if sources == None or sources == []: raise Exception()
            sources = [json.loads(t) for t in set(json.dumps(d, sort_keys=True) for d in sources)]
            for i in sources:
                i.update({'provider': source})
                if not 'priority' in i: i.update({'priority': 100})
                if not 'prioHoster' in i: i.update({'prioHoster': 100})
            self.sources.extend(sources)
        except:
            pass


    def sourcesFilter(self):
        # # only german
        _de = ('de', 'deu', 'ger', 'deutsch', 'german', 'german dub', 'ger-sub')
        self.sources = [i for i in self.sources if i['language'].strip().lower() in _de]
        if not self.sources:
            return
        quality = control.getSetting('hosts.quality')
        if quality == '': quality = '0'
        for i in range(len(self.sources)):
            q = self.sources[i]['quality']
            if q.lower() == 'hd': self.sources[i].update({'quality': '720p'})

        random.shuffle(self.sources)
        #self.sources = sorted(self.sources, key=lambda k: k['prioHoster'], reverse=False)

        filter = []
        if quality in ['0']: filter += [i for i in self.sources if i['quality'] == '4K']
        if quality in ['0', '1']: filter += [i for i in self.sources if i['quality'] == '1440p']
        if quality in ['0', '1', '2']: filter += [i for i in self.sources if i['quality'] == '1080p']
        if quality in ['0', '1', '2', '3']: filter += [i for i in self.sources if i['quality'] == '720p']
        #filter += [i for i in self.sources if i['quality'] in ['SD', 'SCR', 'CAM']]
        filter += [i for i in self.sources if i['quality'] not in ['4k', '1440p', '1080p', '720p']]
        self.sources = filter

        # Deduplizieren: nur 1 Quelle pro (provider, hoster, quality, info) behalten
        # Scraper liefern oft mehrere CDN-Mirrors fuer den gleichen Hoster
        if control.getSetting('deduped') == 'true':
            seen_keys = set()
            deduped = []
            for s in self.sources:
                key = (s.get('provider', ''), s.get('source', ''), s.get('quality', ''), s.get('info', ''))
                if key not in seen_keys:
                    seen_keys.add(key)
                    deduped.append(s)
            self.sources = deduped
        # control.idle()
        self.sources_new = []
        progressDialog = control.progressDialog
        progressDialog.create(control.addonInfo('name'), '')
        # Button Cancel deaktivieren
        from xbmc import sleep
        from xbmcgui import Window
        WINDOW_PROGRESS = Window(10101)
        sleep(100)
        CANCEL_BUTTON = WINDOW_PROGRESS.getControl(10)
        CANCEL_BUTTON.setEnabled(False)
        progressDialog.update(100, "Streams - Mediadaten werden ermittelt")
        count_max = len(self.sources)
        futures = {self.executor.submit(self._get_resolution, source): source for source in self.sources}
        while True:
            count = len([1 for future in futures if not future.done()])
            x = int(100*count/count_max)
            progressDialog.update(x, "Streams - Mediadaten werden ermittelt")
            if count == 0:
                break
            else:
                sleep(200)

        progressDialog.close()
        CANCEL_BUTTON.setEnabled(True)
        control.busy()

        self.sources = self.sources_new
        # self.sources.sort(key=lambda k: (int(k['quality'].split('x')[0]), int(k['quality'].split('x')[1])), reverse=True)
        self.sources.sort(key=lambda k: ((k['_probe']['width']), k['_probe']['height']), reverse=True)
        sort_type = int(control.getSetting('hosts.sort'))
        if sort_type == 1:  # nach Provider
            self.sources = sorted(self.sources, key=lambda k: k['provider'])
        elif sort_type == 2:    # Priorität Provider
            self.sources = sorted(self.sources, key=lambda k: k['priority'], reverse=False)
        elif sort_type == 3:    # Priorität Resolver (Hoster)
            self.sources = sorted(self.sources, key=lambda k: k['prioHoster'], reverse=False)

        # if str(control.getSetting('hosts.limit')) == 'true':
        #     self.sources = self.sources[:int(control.getSetting('hosts.limit.num'))]
        # else:
        #     self.sources = self.sources[:20]

        for i in range(len(self.sources)):
            self.sources[i]['label'] = self._build_label(i, self.sources[i])
        self.sources = [i for i in self.sources if 'label' in i]
        return self.sources


    def _get_resolution(self, source):
        # # _getmediainfo
        import time
        from resources.lib import mediainfo
        class _NullDialog:
            def update(self, *a, **kw): pass
            def iscanceled(self): return False
            def close(self): pass

        try:
            source_name = source.get('source')
            provider = source.get('provider')
            quality = source.get('quality', '')
            prioHoster = source.get('prioHoster')
            info = source.get('info', '')
            #if provider == 'kinokiste':
            #    import pydevd
            #    pydevd.settrace('localhost', port=12345, stdoutToServer=True, stderrToServer=True)

            resolution = 0
            if quality == '720p': resolution = 1
            elif quality == '1080p': resolution = 2
            info_str = mediainfo.getMediaInfo(source['url'], _NullDialog(), time.time() + 5)
            probe = self._parse_probe_info(info_str)
            if probe:   #  and probe.get('file_size_gb'):
                if not probe.get('height') or not probe['height'] > 0:
                    probe.setdefault('width', resolution)
                    probe.setdefault('height', resolution)

            elif 'Keine Auflösungsinfo' in info_str or 'Stream-Typ konnte nicht erkannt werden' in info_str:
                probe = {}
                probe.setdefault('width', resolution)
                probe.setdefault('height', resolution)
                if prioHoster != 999:
                    info =  source.get('info', '')+ '| ' +'Keine Auflösung'
            else:
                log_utils.log('[BG-Probe] Keine MediaInfo: %s / %s' % (provider, source_name), log_utils.LOGWARNING)
                return
            source.update({'info': info})
        except:
            return
        source.update({'_probe': probe})
        self.sources_new.append(source)


    @staticmethod
    def _build_label(idx, item):
        """Baut Label fuer eine Source — einzige Methode fuer Foreground, BG-Probe und Cache."""
        p = item.get('provider', '?')
        s = item.get('source', '?') # .split('.', 1)[0] # Hoster vollständig anzeigen !!!
        q = item.get('quality', 'SD')
        l = item.get('language', '')
        lang_tag = ''
        _de = ('de', 'deu', 'ger', 'deutsch', 'german', 'german dub', 'ger-sub')
        if l and l.strip().lower() not in _de: lang_tag = l.strip().upper()

        probe = item.get('_probe')

        if probe and probe.get('height') and probe['height'] > 5:   # kasi 0-5 für 720p und so
            # Probe-Daten: echte Aufloesung/Bitrate
            q_display = '%d x %d' % (probe.get('width', 0), probe['height'])
            parts = [_bold(q_display)]
            if probe.get('bitrate'): parts.append(probe['bitrate'])
            # Audio
            has_audio = probe.get('has_audio', True)
            audio = probe.get('audio_lang', '')
            # if not has_audio: # kasi
            #     parts.append('[KEIN AUDIO]')
            if audio and 'DE' not in audio.upper():
                parts.append('[%s]' % audio)
            # Sprache: erst language-Feld, dann Fallback auf info-Feld
            if not lang_tag:
                src_info = item.get('info', '')
                if src_info:
                    lang_part = src_info.rsplit('|', 1)[-1].strip().lower()
                    if lang_part and lang_part not in _de:
                        lang_tag = lang_part.upper()
            if lang_tag:
                parts.append('[%s]' % lang_tag)
            label = '%02d | %s | %s | %s' % (idx+1, _bold(p.upper()), s.upper(), ' | '.join(parts))
        else:
            # Keine Probe: deklarierte Qualitaet + info
            try: f = (' | '.join(['[I]%s [/I]' % info.strip() for info in item.get('info', '').split('|')]))
            except: f = ''
            label = '%02d | %s | ' % (idx+1, _bold(p))
            if q in ('4K', '1440p', '1080p', '720p'): label += '%s | %s' % (s, _bold('[I]%s [/I]' % q))
            elif 'x' in q: label += '%s | %s' % (s, _bold('[I]%s [/I]' % q))
            else:  label += '%s' % s
            if f: label += ' | %s' % f
            if lang_tag: label += ' | %s' % lang_tag
            label = label.replace('| 0 |', '|').replace(' | [I]0 [/I]', '')
            label = re.sub(r'\[I\]\s+\[/I\]', ' ', label)
            label = re.sub(r'\|\s+\|', '|', label)
            label = re.sub(r'\|(?:\s+|)$', '', label)
            label = label.upper()

        if item.get('prioHoster', 0) >= 999:
            label += ' | [COLOR red]CAPTCHA[/COLOR]'
        return label


    @staticmethod
    def _parse_probe_info(info_str):
        """Parst getMediaInfo()-Ergebnis in strukturierte Daten."""
        result = {}
        if not info_str:
            return result
        for line in info_str.split('\n'):
            if 'sung:' in line:  # Auflösung / Aufloesung
                m = re.search(r'(\d+)x(\d+)', line)
                if m:
                    result['width'] = int(m.group(1))
                    result['height'] = int(m.group(2))
            elif 'Video-Codec:' in line:
                result['video_codec'] = line.split(':', 1)[1].strip()
            elif 'Bitrate:' in line:
                result['bitrate'] = line.split(':', 1)[1].strip()
            elif 'Dauer:' in line:
                # "Dauer:  1:32:45" oder "Dauer:  45:30 (geschätzt)"
                m = re.search(r'(\d+:\d{2}(?::\d{2})?)', line)
                if m:
                    result['duration'] = m.group(1)
            elif 'Dateigr' in line:  # Dateigröße / Dateigroesse
                m = re.search(r'([\d.]+)\s*(GB|MB)', line)
                if m:
                    val = float(m.group(1))
                    if m.group(2) == 'MB':
                        val /= 1024.0
                    result['file_size_gb'] = val
            elif 'Audio:' in line:
                audio = line.split(':', 1)[1].strip()
                if '!! Kein Audio' in audio:
                    result['has_audio'] = False
                else:
                    result['has_audio'] = True
                    # Sprache extrahieren (z.B. "AAC, Stereo -- Deutsch" -> "DE")
                    # Multi-Track: alle Sprachen sammeln (z.B. "DE/EN")
                    # Manche Streams nutzen englische Sprachnamen (German statt Deutsch)
                    _LANG_NORMALIZE = {
                        'GE': 'DE', 'SP': 'ES', 'JA': 'JA', 'CH': 'ZH',
                        'DU': 'NL', 'CZ': 'CS', 'GR': 'EL',
                    }
                    if ' -- ' in audio:
                        lang_part = audio.split(' -- ', 1)[1].strip()
                        lang_code = lang_part[:2].upper()
                        lang_code = _LANG_NORMALIZE.get(lang_code, lang_code)
                        if 'audio_lang' in result:
                            if lang_code not in result['audio_lang']:
                                result['audio_lang'] += '/%s' % lang_code
                        else:
                            result['audio_lang'] = lang_code
                    else:
                        result['audio_codec'] = audio
        return result




    def sourcesResolve(self, item, info=False):
        try:
            self.url = None
            url = item['url']
            direct = item['direct']
            local = item.get('local', False)
            provider = item['provider']
            call = [i[1] for i in self.provider_sources if i[0] == provider][0]
            url = call.resolve(url)

            if not direct == True:
                try:
                    hmf = resolver.HostedMediaFile(url=url, include_disabled=True, include_universal=False, include_popups=False)
                    if not hmf.valid_url():
                        hmf = resolver.HostedMediaFile(url=url, include_disabled=True, include_universal=False, include_popups=True)
                    if hmf.valid_url():
                        url = hmf.resolve()
                        if url == False or url == None or url == '': url = None  # raise Exception()
                except:
                    url = None
            elif item.get('prioHoster', 0) >= 999:
                try:
                    hmf = resolver.HostedMediaFile(url=url, include_disabled=True, include_universal=False, include_popups=True)
                    if hmf.valid_url():
                        url = hmf.resolve()
                        if url == False or url == None or url == '': url = None
                except:
                    url = None

            if url == None or (not '://' in str(url) and not local):
                log_utils.log('Kein Video Link gefunden: Provider %s / %s / %s ' % (item['provider'], item['source'], str(item['source'])), log_utils.LOGERROR)
                raise Exception()

            # if not utils.test_stream(url):
            #     log_utils.log('URL Test Error: %s' % url, log_utils.LOGERROR)
            #     raise Exception()

            # url = utils.m3u8_check(url)

            if url:
                self.url = url
                return url
            else:
                raise Exception()
        except:
            if info: self.errorForSources()
            return


    def sourcesDialog(self, items):
        labels = [i['label'] for i in items]

        select = control.selectDialog(labels)
        if select == -1: return 'close://'

        next = [y for x,y in enumerate(items) if x >= select]
        prev = [y for x,y in enumerate(items) if x < select][::-1]

        items = [items[select]]
        items = [i for i in items+next+prev][:40]

        header = control.addonInfo('name')
        header2 = header.upper()

        progressDialog = control.progressDialog if control.getSetting('progress.dialog') == '0' else control.progressDialogBG
        progressDialog.create(header, '')
        progressDialog.update(0)

        block = None

        try:
            for i in range(len(items)):
                try:
                    if items[i]['source'] == block: raise Exception()

                    future = self.executor.submit(self.sourcesResolve, items[i])

                    try:
                        if progressDialog.iscanceled(): break
                        progressDialog.update(int((100 / float(len(items))) * i), str(items[i]['label']))
                    except:
                        progressDialog.update(int((100 / float(len(items))) * i), str(header2) + str(items[i]['label']))

                    waiting_time = 30
                    while waiting_time > 0:
                        try:
                            if control.abortRequested: return sys.exit() #xbmc.Monitor().abortRequested()
                            if progressDialog.iscanceled(): return progressDialog.close()
                        except:
                            pass

                        if future.done(): break
                        control.sleep(1)

                        waiting_time = waiting_time - 1

                        if control.condVisibility('Window.IsActive(virtualkeyboard)') or \
                                control.condVisibility('Window.IsActive(yesnoDialog)') or \
                                control.condVisibility('Window.IsActive(ProgressDialog)'):
                            waiting_time = waiting_time + 1 #dont count down while dialog is presented ## control.condVisibility('Window.IsActive(PopupRecapInfoWindow)') or \

                    if not future.done(): block = items[i]['source']

                    if self.url == None: raise Exception()

                    self.selectedSource = items[i]['label']

                    try: progressDialog.close()
                    except: pass

                    control.execute('Dialog.Close(virtualkeyboard)')
                    control.execute('Dialog.Close(yesnoDialog)')
                    return self.url
                except:
                    pass

            try: progressDialog.close()
            except: pass

        except Exception as e:
            try: progressDialog.close()
            except: pass
            log_utils.log('Error %s' % str(e), log_utils.LOGINFO)


    def sourcesDirect(self, items):
        # TODO - OK
        # filter = [i for i in items if i['source'].lower() in self.hostcapDict and i['debrid'] == '']
        # items = [i for i in items if not i in filter]
        # items = [i for i in items if ('autoplay' in i and i['autoplay'] == True) or not 'autoplay' in i]

        u = None

        header = control.addonInfo('name')
        header2 = header.upper()

        try:
            control.sleep(1)

            progressDialog = control.progressDialog if control.getSetting('progress.dialog') == '0' else control.progressDialogBG
            progressDialog.create(header, '')
            progressDialog.update(0)
        except:
            pass

        for i in range(len(items)):
            try:
                if progressDialog.iscanceled(): break
                progressDialog.update(int((100 / float(len(items))) * i), str(items[i]['label']))
            except:
                progressDialog.update(int((100 / float(len(items))) * i), str(header2) + str(items[i]['label']))

            try:
                if control.abortRequested: return sys.exit()

                url = self.sourcesResolve(items[i])
                if u == None: u = url
                if not url == None: break
            except:
                pass

        try: progressDialog.close()
        except: pass

        return u

    def errorForSources(self):
        control.idle()
        control.infoDialog("Keine Streams verfügbar oder ausgewählt", sound=False, icon='INFO')
  
    # def getTitle(self, title):
    #     title = utils.normalize(title)
    #     return title

    def getConstants(self):
        self.itemsProperty = '%s.container.items' % control.Addon.getAddonInfo('id')
        self.metaProperty = '%s.container.meta'  % control.Addon.getAddonInfo('id')
        from scrapers import sources
        self.provider_sources = sources()

# https://github.com/michaz1988/michaz1988.github.io/issues/48
    def mediaInfo(self, source, dialog=None):
        import xbmcgui
        try:
            import urllib3
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
        except: pass
        try:
            item = json.loads(source)[0]
            if item['source'] is None:
                raise Exception()

            import time as _time
            from resources.lib.mediainfo import TOTAL_TIMEOUT
            deadline = _time.time() + TOTAL_TIMEOUT

            if dialog is None:
                dialog = xbmcgui.DialogProgress()
                dialog.create('Medien-Info', 'Löse Stream-URL auf... (%d Sek.)' % TOTAL_TIMEOUT)
                dialog.update(0)

            future = self.executor.submit(self.sourcesResolve, item)

            # Wait for resolve with responsive cancel (check every 250ms)
            for i in range(120):  # 120 * 250ms = 30s max
                remaining = int(deadline - _time.time())
                if remaining > 0:
                    dialog.update(int(50.0 * i / 120), 'Löse Stream-URL auf... (%d Sek.)' % remaining)
                else:
                    dialog.update(int(50.0 * i / 120), 'Löse Stream-URL auf...')
                try:
                    if dialog.iscanceled():
                        try: dialog.close()
                        except: pass
                        return
                except: pass
                if future.done():
                    break
                control.sleep(0.25)
                # Don't count down while resolver shows interactive dialogs
                if control.condVisibility('Window.IsActive(virtualkeyboard)') or \
                        control.condVisibility('Window.IsActive(yesnoDialog)'):
                    continue

            url = self.url if future.done() else None
            control.execute('Dialog.Close(virtualkeyboard)')
            control.execute('Dialog.Close(yesnoDialog)')

            try:
                if dialog.iscanceled():
                    try: dialog.close()
                    except: pass
                    return
            except: pass

            if url is None:
                try: dialog.close()
                except: pass
                control.infoDialog("Stream-URL konnte nicht aufgelöst werden", sound=False, icon='INFO')
                return

            dialog.update(50, 'Analysiere Stream...')

            from resources.lib import mediainfo
            info = mediainfo.getMediaInfo(url, dialog, deadline)

            try: dialog.close()
            except: pass

            if info:
                xbmcgui.Dialog().textviewer('Medien-Info', info)
            else:
                control.infoDialog("Auflösung konnte nicht ermittelt werden", sound=False, icon='INFO')

        except Exception as e:
            try:
                if dialog: dialog.close()
            except: pass
            log_utils.log('mediaInfo Error: %s' % str(e), log_utils.LOGERROR)
            control.infoDialog("Auflösung konnte nicht ermittelt werden", sound=False, icon='INFO')
