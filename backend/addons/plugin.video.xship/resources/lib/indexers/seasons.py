


#2021-07-21
# edit 2025-08-02 switch from treads to concurrent.futures

import sys, re, traceback
import datetime, time, json
from resources.lib.tmdb import cTMDB
from concurrent.futures import ThreadPoolExecutor
from resources.lib import control, playcountDB, log_utils
from resources.lib.control import getKodiVersion
if int(getKodiVersion()) >= 20: from resources.lib.listitem import ListItemInfoTag

_params = dict(control.parse_qsl(sys.argv[2].replace('?',''))) if len(sys.argv) > 1 else dict()

class seasons:
	def __init__(self):
		self.list = []
		self.lang = "de"
		self.sysmeta = _params['sysmeta']
		#self.datetime = (datetime.datetime.utcnow() - datetime.timedelta(hours=5))
		#self.systime = (self.datetime).strftime('%Y%m%d%H%M%S%f')


	def get(self, params):
		try:
			data = json.loads(params['sysmeta'])
			self.title = data['title']
			tmdb_id = data['tmdb_id']
			# #106: TMDB search doesn't return number_of_seasons — fetch via detail call
			try:
				detail = cTMDB().get_meta('tvshow', '', '', tmdb_id, advanced='true')
				number_of_seasons = (detail or {}).get('number_of_seasons', 0)
			except Exception as e:
				log_utils.log(level=log_utils.LOGERROR, msg='[seasons.get] TMDB detail fetch failed: %s' % e)
				return

			tvdb_id = detail['tvdb_id'] if 'tvdb_id' in detail else None
			imdb_id = detail['imdb_id'] if 'imdb_id' in detail else None
			imdbnumber = detail['imdbnumber'] if 'imdbnumber' in detail else None

			# title = data['title']
			# playcount = playcountDB.getPlaycount('tvshow', 'title', title, None, None)
			# if playcount is None:
			# 	#playcountDB.createEntry('tvshow', title, title, imdb_id, number_of_seasons, None, None, None)
			# 	playcount = 0
			# self.sysmeta = re.sub(r'"playcount": \d', '"playcount": %s' % playcount, self.sysmeta)
			if imdbnumber:
				self.sysmeta = re.sub(r'"imdbnumber": ""', '"imdbnumber": "%s"' % imdbnumber, self.sysmeta)
			if imdb_id:
				self.sysmeta = re.sub(r'"imdb_id": ""', '"imdb_id": "%s"' % imdb_id, self.sysmeta)

			for i in range(1, number_of_seasons+1):
				self.list.append({'tmdb_id': tmdb_id, 'tvdb_id': tvdb_id, 'season': i})

			self.worker()

			if self.list == None or len(self.list) == 0:	# nichts gefunden
				control.infoDialog("Nichts gefunden", time=8000)
			else:
				self.Directory(self.list)
				return self.list
			return
		except Exception as e:
			log_utils.log(level=log_utils.LOGERROR, msg='[seasons.get] CRASH: %s\n%s' % (e, traceback.format_exc()))


	def worker(self):
		self.meta = []
		with ThreadPoolExecutor() as executor:
			# must consume results — executor.map swallows exceptions silently otherwise
			list(executor.map(self.super_meta, self.list))

		self.meta = sorted(self.meta, key=lambda k: k['season'])
		self.list = [i for i in self.meta] # falls noch eine Filterfunktion kommt


	def super_meta(self, i):
		try:
			meta = cTMDB().get_meta_seasons(i['tmdb_id'] , i['season'], advanced='true')
			try:
				playcount = playcountDB.getPlaycount('season', 'title', self.title, meta['season'], None)
				playcount = playcount if playcount else 0
				overlay = 7 if playcount > 0 else 6
				meta.update({'playcount': playcount, 'overlay': overlay})
				episodes = meta.get('episodes')
				# z.B. One Piece (1999)
				if episodes[0]['episode_number'] != 1:
					for i in range(0, len(episodes)):
						episode = episodes[i]
						episode.update({'episode_number': i + 1})
						meta.update({'episodes': episodes})
			except Exception as e:
				log_utils.log(level=log_utils.LOGERROR, msg='[seasons.super_meta] playcount/episodes error s%s: %s' % (i.get('season','?') if isinstance(i, dict) else '?', e))
			self.meta.append(meta)
		except Exception as e:
			log_utils.log(level=log_utils.LOGERROR, msg='[seasons.super_meta] CRASH s%s: %s\n%s' % (i.get('season','?'), e, traceback.format_exc()))


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
		pos = 0
		for i in items:
			try:
				season = i['season']
				meta = json.loads(self.sysmeta)
				sysmeta = json.loads(self.sysmeta)
				systitle = sysmeta['systitle']
				sysname = systitle + ' S%02d' % season
				sysmeta.update({'sysname': sysname})
				sysmeta.update({'season': season})
				sysmeta.update({'number_of_episodes': i['number_of_episodes']})
				# episodes NICHT in die URL stopfen (riesiges JSON pro Staffel liess die Liste laggen) -> episodes.py holt sie aus dem 7-Tage-Cache
				_sysmeta = {k: v for k, v in sysmeta.items()}
				_sysmeta.pop('cast', None)
				_sysmeta.pop('episodes', None)
				_sysmeta = control.quote_plus(json.dumps(_sysmeta))

				label = 'Staffel %s - %s' % (season, sysmeta['title'])
				if 'premiered' in i:
					if datetime.datetime(*(time.strptime(i['premiered'], "%Y-%m-%d")[0:6])) > datetime.datetime.now():
						label = '[COLOR=red][I]{}[/I][/COLOR]'.format(label) # ffcc0000
				else:
					continue

				poster = i['poster'] if 'poster' in i and 'http' in i['poster'] else sysmeta['poster']
				fanart = sysmeta['fanart'] if 'fanart' in sysmeta else addonFanart
				plot = i['plot'] if 'plot' in i and len(i['plot']) > 50 else sysmeta['plot']

				meta.update({'poster': poster})
				meta.update({'fanart': fanart})
				meta.update({'plot': plot})
				#if 'air_date' in i and i['air_date']: meta.update({'air_date': i['air_date']})
				if 'premiered' in i and i['premiered']: meta.update({'premiered': i['premiered']})

				item = control.item(label=label, offscreen=True)
				item.setArt({'poster': poster, 'banner': addonBanner})
				if settingFanart == 'true': item.setArt({'fanart': fanart})

				if sysmeta.get('playcount', 0) == 0: playcount = i.get('playcount', 0)
				else: playcount = 1

				cm = []
				try:
					if playcount == 1:
						cm.append((unwatchedMenu, 'RunPlugin(%s?action=UpdatePlayCount&meta=%s&playCount=0)' % (sysaddon, _sysmeta)))
						meta.update({'playcount': 1, 'overlay': 7})
						sysmeta.update({'playcount': 1, 'overlay': 7})
						pos = season +1
						if len(items) == season: pos = season
					else:
						cm.append((watchedMenu, 'RunPlugin(%s?action=UpdatePlayCount&meta=%s&playCount=1)' % (sysaddon, _sysmeta)))
						meta.update({'playcount': 0, 'overlay': 6})
						sysmeta.update({'playcount': 0, 'overlay': 6})
				except Exception as e:
					log_utils.log(level=log_utils.LOGERROR, msg='[seasons.Directory] playcount menu error s%s: %s' % (season, e))
				if hasTrailerPlayer:
					cm.append(('Staffel-Trailer ansehen', 'RunPlugin(%s?action=playTrailer&tmdb_id=%s&mediatype=tv&title=%s&year=%s&poster=%s&season=%s)' % (
						sysaddon, sysmeta['tmdb_id'],
						control.quote_plus(str(sysmeta['title'])),
						str(sysmeta.get('year', '')),
						control.quote_plus(str(poster)),
						str(season),
					)))
				cm.append(('Einstellungen', 'RunPlugin(%s?action=addonSettings)' % sysaddon))
				item.addContextMenuItems(cm)

				sysmeta = control.quote_plus(json.dumps(sysmeta))
				url = '%s?action=episodes&sysmeta=%s' % (sysaddon, sysmeta)

				aActors = []
				if 'cast' in meta and meta['cast']: aActors = meta['cast']

				## supported infolabels: https://codedocs.xyz/AlwinEsch/kodi/group__python__xbmcgui__listitem.html#ga0b71166869bda87ad744942888fb5f14
				# # # remove unsupported InfoLabels
				meta.pop('cast', None)  # ersetzt durch item.setCast(i['cast'])
				meta.pop('fanart', None)
				meta.pop('poster', None)
				meta.pop('imdb_id', None)
				meta.pop('tvdb_id', None)
				meta.pop('tmdb_id', None)
				meta.pop('number_of_seasons', None)
				meta.pop('number_of_episodes', None)
				meta.pop('originallanguage', None)
				meta.pop('sysname', None)
				meta.pop('systitle', None)
				meta.pop('year', None)
				meta.pop('aliases', None)
				meta.pop('backdrop_url', None)
				meta.pop('cover_url', None)

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
					stream_details = {
						'video': [video_streaminfo],
						'audio': [audio_streaminfo]}
					info_tag.set_stream_details(stream_details)
					info_tag.set_cast(aActors)


				control.addItem(handle=syshandle, url=url, listitem=item, isFolder=True)
			except Exception as e:
				log_utils.log(level=log_utils.LOGERROR, msg='[seasons.Directory] CRASH s%s: %s\n%s' % (i.get('season','?'), e, traceback.format_exc()))

		control.content(syshandle, 'tvshows')
		control.plugincategory(syshandle, control.addonVersion)
		control.endofdirectory(syshandle, cacheToDisc=True)

		# setzt Auswahl nach letzte als gesehen markierte Staffel -> Content: 'movies'
		# if control.getSetting('status.position') == 'true':	# edit kasi
		if pos > 0:
			from resources.lib.utils import setPosition
			setPosition(pos, __name__, 'movies')
