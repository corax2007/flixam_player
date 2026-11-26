

#2021-07-15
# switch from treads to concurrent.futures 
# edit 2025-08-23 

import sys
import datetime, time, json
from concurrent.futures import ThreadPoolExecutor
from resources.lib.tmdb import cTMDB
from resources.lib.indexers import navigator
from resources.lib import searchDB, playcountDB, art, control, log_utils
from resources.lib.control import getKodiVersion, iteritems
from resources.lib.utils import cjk_detect
if int(getKodiVersion()) >= 20: from resources.lib.listitem import ListItemInfoTag

_params = dict(control.parse_qsl(sys.argv[2].replace('?',''))) if len(sys.argv) > 1 else dict()

class movies:
	def __init__(self):
		self.list = []
		self.meta = []
		self.total_pages = 0
		self.next_pages = 0
		self.query = ''
		self.activeSearchDB = 'TMDB'
		self.playcount = 0
		self.search_direct = False

		self.datetime = (datetime.datetime.utcnow() - datetime.timedelta(hours=5))
		self.systime = (self.datetime).strftime('%Y%m%d%H%M%S%f')

	def get(self, params):
		try:
			self.next_pages = int(params.get('page'))
			self.query = params.get('query')
			self.list, self.total_pages = cTMDB().search_term_full('movie', params.get('query'), params.get('page'))
			if self.list == None or len(self.list) == 0:  # nichts gefunden
				return control.infoDialog("Nichts gefunden1", time=2000)
			self.search_direct = True
			self.getDirectory(params)
			searchDB.save_query(params.get('query'), params.get('action'))
		except:
			return

	def getDirectory(self, params):
		try:
			if params.get('next_pages'): self.next_pages = params.get('next_pages')
			if params.get('total_pages'): self.total_pages = params.get('total_pages')
			if params.get('list'): self.list = params.get('list')
			self.presorted = params.get('presorted', False)
			self.filter_providers = params.get('filter_providers', False)
			self.cinema_only = params.get('cinema_only', False)
			self.digital_released = params.get('digital_released', False)
			self.sort_by_date = params.get('sort_by_date', False)
			self.worker()
			if self.list == None or len(self.list) == 0:	#nichts gefunden
				return control.infoDialog("Nichts gefunden", time=2000)
			self.Directory(self.list)
			return self.list
		except:
			return


	def search(self):
		navigator.navigator().addDirectoryItem("Filme - neue Suche %s" % self.activeSearchDB , 'searchNew&table=movies', 'tmdb_search.png', 'DefaultAddonsSearch.png',
											   isFolder=False, context=('Einstellungen', 'addonSettings'))
		match = searchDB.getSearchTerms('movies')
		lst = []
		delete_option = False
		for index, i in enumerate(match):
			term = control.py2_encode(i['query'])
			if term not in lst:
				delete_option = True
				navigator.navigator().addDirectoryItem(term, 'movies&page=1&query=%s' % term, '_search.png',
													   'DefaultAddonsSearch.png', isFolder=True,
													   context=("Suchanfrage löschen", 'searchDelTerm&table=movies&name=%s' % index))
				lst += [(term)]
		if delete_option:
			navigator.navigator().addDirectoryItem("Suchverlauf löschen", 'searchClear&table=movies', 'tools.png', 'DefaultAddonProgram.png', isFolder=False)
		navigator.navigator()._endDirectory('', False) # addons  videos  files


	def worker(self):
		try:
			if self.list and isinstance(self.list[0], dict):
				try:
					self.list = [i['id'] for i in self.list]
				except:
					self.list = [i['tmdb_id'] for i in self.list]
			self.meta = []
			id_order = list(self.list)  # preserve original TMDB order before concurrent fetch
			with ThreadPoolExecutor(max_workers=10) as executor:
				executor.map(self.super_meta, self.list)
			if getattr(self, 'presorted', False):
				# Preserve TMDB order (e.g. sorted by release_date, popularity, rating)
				meta_by_id = {str(m.get('tmdb_id', '')): m for m in self.meta}
				self.meta = [meta_by_id[str(tid)] for tid in id_order if str(tid) in meta_by_id]
			else:
				self.meta = sorted(self.meta, key=lambda k: k['title'])
			#self.list = [i for i in self.meta if i['votes'] > 10 and i['rating'] > 4]
			filter_countries = control.getSetting('filter.countries')
			excluded_countries = set(c.strip() for c in filter_countries.split(',') if c.strip()) if filter_countries else set()
			filter_genres = control.getSetting('filter.genres')
			excluded_genres = set(int(g.strip()) for g in filter_genres.split(',') if g.strip()) if filter_genres else set()
			self.list = []
			today_str = datetime.datetime.today().strftime('%Y-%m-%d')
			for i in self.meta:
				if excluded_countries and i.get('origin_country'):
					if any(c in excluded_countries for c in i['origin_country'].split(', ')):
						continue
				if excluded_genres and i.get('genre_ids'):
					if any(g in excluded_genres for g in i['genre_ids']):
						continue
				if getattr(self, 'filter_providers', False) and not i.get('watch_providers'):
					continue
				if getattr(self, 'cinema_only', False):
					rt = i.get('de_release_types', {})
					has_digital = any(rt.get(t, '') <= today_str for t in (4, 5, 6) if t in rt)
					if has_digital:
						continue
					cinema_dates = [rt[t] for t in (2, 3) if t in rt and rt[t] <= today_str]
					if cinema_dates:
						i['premiered'] = min(cinema_dates)
				if getattr(self, 'digital_released', False):
					rt = i.get('de_release_types', {})
					released_dates = [rt[t] for t in (4, 5, 6) if t in rt and rt[t] <= today_str]
					if not released_dates:
						continue
					i['premiered'] = min(released_dates)
				if self.search_direct or getattr(self, 'presorted', False):
					self.list.append(i)
				else:
					if 'votes' in i and i['votes'] > 10 and 'rating' in i and i['rating'] > 4: self.list.append(i)
					if not 'votes' in i: self.list.append(i)
			if getattr(self, 'sort_by_date', False):
				self.list.sort(key=lambda x: x.get('premiered', ''), reverse=True)
		except:
			log_utils.error()

	def super_meta(self, id):
		try:
			# TODO different search providers
			meta = cTMDB().get_meta('movie', '', '', id, advanced='true')
			if not meta or not meta.get('title'):
				return
			try:
				playcount = playcountDB.getPlaycount('movie', 'imdb_id', meta['imdb_id']) # mediatype, column_names, column_value, season=0, episode=0
				playcount = playcount if playcount else 0
				try:
					meta.update({'playcount': playcount})
				except:
					meta.setdefault('playcount', playcount)
			except:
				pass
			if not 'poster' in meta or meta['poster'] == '':
				poster = art.getMovie_art(meta['tmdb_id'], meta['imdbnumber'])
				meta.update({'poster': poster})
			#meta.update({'mediatype': 'movie'})
			self.meta.append(meta)
			return meta
		except Exception as e:
			from resources.lib import log_utils
			log_utils.log('[movies] super_meta(%s) Fehler: %s' % (id, e), log_utils.LOGERROR)


	def Directory(self, items):
		if items == None or len(items) == 0:
			control.idle()
			sys.exit()
		sysaddon = sys.argv[0]
		syshandle = int(sys.argv[1])

		addonPoster, addonBanner = control.addonPoster(), control.addonBanner()
		addonFanart, settingFanart = control.addonFanart(), control.getSetting('fanart')
		watchedMenu = "In %s [I]Gesehen[/I]" % control.addonName
		unwatchedMenu = "In %s [I]Ungesehen[/I]" % control.addonName
		hasTrailerPlayer = control.hasTrailerPlayer()
		trailerLabel = control.trailerLabel()
		for i in items:
			try:
				title = i['title'] if 'title' in i else i['originaltitle']
				if cjk_detect(title):
					title = i.get('originaltitle', '')
					if not title or cjk_detect(title):
						alt = [a for a in i.get('aliases', []) if a and not cjk_detect(a)]
						if alt: title = alt[0]
						else: continue
				try:
					label = '%s (%s)' % (title, i['year'])  # show in list
				except:
					label = title

				sysname = label

				if 'premiered' in i:
					if datetime.datetime(*(time.strptime(i['premiered'], "%Y-%m-%d")[0:6])) > datetime.datetime.now():
						# label = '[COLOR=red][I]{}[/I][/COLOR]'.format(label) # ffcc0000
						continue
				else:
					# label = '[COLOR=red][I]{}[/I][/COLOR]'.format(label)
					continue

				meta = dict((k, v) for k, v in iteritems(i))
				meta['title'] = title
				if not 'duration' in i or i['duration'] == 0: meta.update({'duration': str(120 * 60)})

				poster = i['poster'] if 'poster' in i and 'http' in i['poster'] else addonPoster
				fanart = i['fanart'] if 'fanart' in i and 'http' in i['fanart'] else addonFanart
				meta.update({'poster': poster})
				meta.update({'fanart': fanart})
				meta.update({'systitle': title})
				meta.update({'sysname': sysname})

				_sysmeta = control.quote_plus(json.dumps(meta))

				item = control.item(label=label, offscreen=True)
				item.setArt({'poster': poster, 'banner': addonBanner})
				if settingFanart == 'true': item.setArt({'fanart': fanart})

				cm = []
				try:
					playcount = i['playcount'] if 'playcount' in i else 0
					if playcount == 1:
						cm.append((unwatchedMenu, 'RunPlugin(%s?action=UpdatePlayCount&meta=%s&playCount=0)' % (sysaddon, _sysmeta)))
						meta.update({'playcount': 1, 'overlay': 7})
					else:
						cm.append((watchedMenu, 'RunPlugin(%s?action=UpdatePlayCount&meta=%s&playCount=1)' % (sysaddon, _sysmeta)))
						meta.update({'playcount': 0, 'overlay': 6})
				except:
					pass

				if hasTrailerPlayer:
					cm.append((trailerLabel, 'RunPlugin(%s?action=playTrailer&tmdb_id=%s&mediatype=movie&title=%s&year=%s&poster=%s)' % (
						sysaddon, meta['tmdb_id'],
						control.quote_plus(str(title)),
						str(i.get('year', '')),
						control.quote_plus(str(poster)),
					)))
				cm.append(('Einstellungen', 'RunPlugin(%s?action=addonSettings)' % sysaddon))
				item.addContextMenuItems(cm)

				if 'plot' in i:
					plot = i['plot']
				else:
					plot = ''

				header = ''
				votes = ''
				if 'rating' in i and i['rating'] != '':
					if 'votes' in i: votes = '(%s)' % str(i['votes']).replace(',', '')
					header += '[COLOR blue]Bewertung :  %.1f  %s[/COLOR]' % (float(i['rating']), votes)
				if i.get('genre') and i['genre']:
					if header: header += '\n'
					header += '[COLOR grey]Genre:  %s[/COLOR]' % ', '.join(i['genre'])
				if i.get('origin_country') or i.get('fsk'):
					if header: header += '\n'
					parts = []
					if i.get('fsk'): parts.append('FSK:  %s' % i['fsk'])
					if i.get('origin_country'): parts.append('Land:  %s' % i['origin_country'])
					header += '[COLOR grey]%s[/COLOR]' % ', '.join(parts)
				if header and plot:
					plot = header + '\n\n' + plot
				elif header:
					plot = header
				meta.update({'plot': plot})
				aActors = []
				if 'cast' in i and i['cast']: aActors = i['cast']

				## supported infolabels: https://codedocs.xyz/AlwinEsch/kodi/group__python__xbmcgui__listitem.html#ga0b71166869bda87ad744942888fb5f14
				# remove unsupported infolabels
				meta.pop('cast', None)  # ersetzt durch item.setCast(i['cast'])
				meta.pop('fanart', None)
				meta.pop('tmdb_id', None)
				meta.pop('originallanguage', None)
				meta.pop('budget', None)
				meta.pop('revenue', None)
				meta.pop('sysname', None)
				meta.pop('systitle', None)
				meta.pop('watch_providers', None)
				meta.pop('origin_country', None)
				meta.pop('origin_country', None)
				meta.pop('fsk', None)
				meta.pop('de_release_types', None)
				meta.pop('genre_ids', None)

				sysmeta = control.quote_plus(json.dumps(meta))
				url = '%s?action=play&sysmeta=%s' % (sysaddon, sysmeta)

				meta.pop('poster', None)
				meta.pop('imdb_id', None)
				meta.pop('aliases', None)
				meta.pop('backdrop_url', None)
				meta.pop('cover_url', None)
# TODO
				# gefakte Video/Audio Infos
				# video_streaminfo = {'codec': 'h264', "width": 1920, "height": 1080}
				# audio_streaminfo = {'codec': 'dts', 'channels': 6, 'language': 'de'}
				video_streaminfo = {}
				audio_streaminfo = {}

				if int(getKodiVersion()) <= 19:
					if aActors: item.setCast(aActors)
					item.setInfo(type='Video', infoLabels=meta)
					item.addStreamInfo('video', video_streaminfo)
					item.addStreamInfo('audio', audio_streaminfo)
				else:
					info_tag = ListItemInfoTag(item, 'video')
					info_tag.set_info(meta)
					"""
					stream_details = {
							'video': [{videostream_1_values}, {videostream_2_values} ...],
							'audio': [{audiostream_1_values}, {audiostream_2_values} ...],
							'subtitle': [{subtitlestream_1_values}, {subtitlestream_2_values} ...]}
					"""
					stream_details = {
						'video': [video_streaminfo],
						'audio': [audio_streaminfo]}

					info_tag.set_stream_details(stream_details)
					info_tag.set_cast(aActors)

				control.addItem(handle=syshandle, url=url, listitem=item, isFolder=False)
			except Exception as e:
				print(e)
				pass

		# nächste Seite
		try:
			self.next_pages = self.next_pages + 1
			if self.next_pages <= self.total_pages:
				if self.query:
					url = '%s?action=movies&url=&page=%s&query=%s' % (sys.argv[0], self.next_pages, self.query )
				else:
					url = '%s?action=listings' % sys.argv[0]
					url += '&media_type=%s' % _params.get('media_type')
					url += '&next_pages=%s' % self.next_pages
					url += '&url=%s' % control.quote_plus(_params.get('url'))
				item = control.item(label="Nächste Seite")
				icon = control.addonNext()
				item.setArt({'icon': icon, 'thumb': icon, 'poster': icon, 'banner': icon})
				if not addonFanart == None: item.setArt({'fanart': addonFanart})
				
				#  -> gesehen/ungesehen im cm und "Keine Informationen verfügbar" ausblenden (abhängig von control.content() )
				video_streaminfo = {'overlay': 4, 'plot': ' '}  # alt255

				if int(getKodiVersion()) <= 19:
					item.setInfo('video', video_streaminfo)
				else:
					stream_details = {'video': [video_streaminfo]}
					info_tag = ListItemInfoTag(item, 'video')
					info_tag.set_stream_details(stream_details)
				control.addItem(handle=syshandle, url=url, listitem=item, isFolder=True)
		except:
			pass

		control.content(syshandle, 'movies')
		control.plugincategory(syshandle, control.addonVersion)
		control.endofdirectory(syshandle, cacheToDisc=True)

