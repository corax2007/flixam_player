
#2021-07-14
# edit 2026-08-09

import sys
from os import path
import xbmcvfs
from resources.lib import control
from resources.lib.tools import cParser
if int(control.getKodiVersion()) >= 20: from resources.lib.listitem import ListItemInfoTag

sysaddon = sys.argv[0]
syshandle = int(sys.argv[1]) if len(sys.argv) > 1 else ''
artPath = control.artPath()
addonFanart = control.addonFanart()
addonPath = control.addonPath

# Flache Film-Listen (keine Unter-Listen wie Genre/Jahr).
# Genutzt von movies().
# Format: (url_key, label, icon, default_icon)
FLAT_MOVIE_LISTS = [
    ('neu',         'Neu',                      'movies.png',  'DefaultRecentlyAddedMovies.png'),
    ('imkino',      'Im Kino',                  'in-theaters.png',  'DefaultStudios.png'),
    ('trend',       'Im Trend',                 'most-popular.png', 'DefaultInProgressShows.png'),
    ('topbewertet', 'Top bewertet',             'highly-rated.png', 'DefaultSets.png'),
    ('production_status=released%26sort_by=vote_count.desc',  'Meist bewertet',           'most-voted.png',   'DefaultFavourites.png'),
    ('production_status=released%26sort_by=revenue.desc',     'Bestes Einspielergebnis',  'box-office.png',   'DefaultMovies.png'),
]

# TODO https://kodi.wiki/view/Default_Icons
class navigator:
    def root(self):
        # Setting 'navigator.menu.search': AN = die 3 Such-Eintraege ganz oben,
        # AUS (default) = sie bleiben an ihrer alten Position (zwischen Serien und Werkzeuge).
        searchOnTop = control.getSetting('navigator.menu.search') == 'true'

        def _addSearch():
            self.addDirectoryItem("Suche Filme", 'moviesSearch', '_movies-search.png', 'DefaultAddonsSearch.png')
            self.addDirectoryItem("Suche Serien", 'tvshowsSearch', '_series-search.png', 'DefaultAddonsSearch.png')
            self.addDirectoryItem("Suche nach Person/Darsteller", 'personSearch', '_people-search.png', 'DefaultAddonsSearch.png')

        if searchOnTop: _addSearch()
        self.addDirectoryItem("Filme", 'movieNavigator', 'movies.png', 'DefaultMovies.png')
        self.addDirectoryItem("Serien", 'tvNavigator', 'tvshows.png', 'DefaultTVShows.png')
        if not searchOnTop: _addSearch()
        self.addDirectoryItem("Werkzeuge", 'toolNavigator', 'tools.png', 'DefaultAddonProgram.png')
        if control.condVisibility('system.platform.windows'): self.addDirectoryItem("Stream-URL abspielen", 'playURL', 'url.png', 'DefaultAddonWebSkin.png', isFolder=False)
        self._endDirectory(content='',cache=False)  # addons  videos  files

# TODO vote_count vote_average popularity revenue
    def movies(self):
        for url_key, label, icon, default_icon in FLAT_MOVIE_LISTS:
            self.addDirectoryItem(label, 'listings&media_type=movie&url=%s' % url_key, icon, default_icon)
        self.addDirectoryItem("Heute im Trend", 'listings&media_type=movie&url=trending', 'most-popular.png', 'DefaultRecentlyAddedMovies.png')
        self.addDirectoryItem("Jahr", 'movieYears', 'years.png', 'DefaultYear.png')
        self.addDirectoryItem("Genres", 'movieGenres', 'genres.png', 'DefaultGenre.png')
        self.addDirectoryItem("Streaming-Anbieter", 'movieProviders', 'most-popular.png', 'DefaultMovies.png')
        # self.addDirectoryItem("Oskar-Gewinner", 'movies&url=oscars', 'oscar-winners.png', 'DefaultMovies.png')
        self._endDirectory()

    def tvshows(self):
        self.addDirectoryItem("Neu", 'listings&media_type=tv&url=tvneu', 'tvshows.png', 'DefaultRecentlyAddedEpisodes.png')
        self.addDirectoryItem("Heute im Trend", 'listings&media_type=tv&url=trending', 'most-popular.png', 'DefaultTVShows.png')
        self.addDirectoryItem("Jahr", 'tvYears', 'years.png', 'DefaultYear.png')
        self.addDirectoryItem("Genres", 'tvGenres', 'genres.png', 'DefaultGenre.png')
        self.addDirectoryItem("Streaming-Anbieter", 'tvProviders', 'most-popular.png', 'DefaultTVShows.png')
        self.addDirectoryItem("Laufend", 'listings&media_type=tv&url=with_status=0%26sort_by=popularity.desc', 'in-theaters.png', 'DefaultTVShows.png')
        self.addDirectoryItem("Abgeschlossen", 'listings&media_type=tv&url=with_status=3%26sort_by=vote_count.desc', 'highly-rated.png', 'DefaultTVShows.png')
        self.addDirectoryItem("Am populärsten", 'listings&media_type=tv&url=sort_by=popularity.desc', 'most-popular.png', 'DefaultTVShows.png')
        self.addDirectoryItem("Am besten bewertet", 'listings&media_type=tv&url=sort_by=vote_average.desc%26vote_count.gte=200', 'highly-rated.png', 'DefaultFavourites.png')
        self.addDirectoryItem("Meist bewertet", 'listings&media_type=tv&url=sort_by=vote_count.desc', 'most-voted.png', 'DefaultFavourites.png')
        self._endDirectory()

    def tools(self):
        self.addDirectoryItem(control.addonName + ": EINSTELLUNGEN", 'addonSettings', 'tools.png', 'DefaultAddonProgram.png', isFolder=False)
        # self.addDirectoryItem(""+control.addonName.upper()+": Reset Settings (außer Konten)", 'resetSettings', 'nightly_update.png', 'DefaultAddonProgram.png', isFolder=False)
        self.addDirectoryItem("Resolver: EINSTELLUNGEN", 'resolverSettings', 'resolveurl.png', 'DefaultAddonProgram.png', isFolder=False)
        self.addDirectoryItem("Resolver: Update", 'resolverUpdate', 'nightly_update.png', 'DefaultAddonProgram.png', isFolder=False)
        self.addDirectoryItem("Domain Check", 'domainCheck', 'folder.png', 'DefaultAddonProgram.png', isFolder=False)
        self.addDirectoryItem("Support: Information anzeigen", 'pluginInfo', 'plugin-info.png', 'DefaultAddonProgram.png', isFolder=False)
        self._endDirectory()    # addons  videos  files

#TODO
    def addDirectoryItem(self, name, query, thumb, icon, context=None, queue=False, isAction=True, isFolder=True):
        url = '%s?action=%s' % (sysaddon, query) if isAction == True else query
        thumb = self.getMedia(thumb, icon)
        #laut kodi doku - ListItem([label, label2, path, offscreen])
        # Fettschrift fuer Menue-Labels zentral hier (Toggle 'bold_labels'). Nur das Label,
        # nicht 'name' selbst -> Plot/sPlot unten bleibt unveraendert.
        listitem = control.item(control.bold(name), offscreen=True) # Removed iconImage and thumbnailImage
        listitem.setArt({'poster': thumb, 'icon': icon})
        if not context == None:
            cm = []
            cm.append((context[0], 'RunPlugin(%s?action=%s)' % (sysaddon, context[1])))
            listitem.addContextMenuItems(cm)

        isMatch, sPlot = cParser.parseSingleResult(query, "plot'.*?'([^']+)")
        if not isMatch: sPlot = '[COLOR blue]{0}[/COLOR]'.format(name)
        if isFolder:
            if int(control.getKodiVersion()) <= 19:
                listitem.setInfo('video', {'overlay': 4, 'plot': control.unquote_plus(sPlot)})
            else:
                info_tag = ListItemInfoTag(listitem, 'video')
                info_tag.set_info({'overlay': 4, 'plot': control.unquote_plus(sPlot)})
            listitem.setIsFolder(True)
        else:
            listitem.setProperty('IsPlayable', 'false')
        self.addFanart(listitem, query)

        control.addItem(syshandle, url, listitem, isFolder)

    def _endDirectory(self, content='', cache=True ): # addons  videos  files
        # https://romanvm.github.io/Kodistubs/_autosummary/xbmcplugin.html#xbmcplugin.setContent
        control.content(syshandle, content)
        control.plugincategory(syshandle, control.addonName + ' / '+ control.addonVersion)
        import xbmcplugin
        xbmcplugin.addSortMethod(syshandle, xbmcplugin.SORT_METHOD_UNSORTED)
        control.endofdirectory(syshandle, succeeded=True, cacheToDisc=cache)

# ------- ergänzt für xStream V2 -----------
    def addFanart(self, listitem, query):
        if control.getSetting('fanart')=='true':
            isMatch, sFanart = cParser.parseSingleResult(query, "fanart'.*?'([^']+)")
            if isMatch:
                sFanart = self.getMedia(sFanart)
                listitem.setProperty('fanart_image', sFanart)
            else:
                listitem.setProperty('fanart_image', addonFanart)

    def getMedia(self,mediaFile=None, icon=None):
        media_files = ['banner.png', 'box-office.png', 'clearlogo.png', 'downloads.png', 'fanart.jpg', 'genres.png', 'highly-rated.png', 'icon.png', 'in-theaters.png', 'most-popular.png', 'most-voted.png', 'movies.png', 'next.png', 'no-picture.png', 'plugin-info.png', 'poster.png', 'resolveurl.png', 'screenshot-01.jpg', 'screenshot-02.jpg', 'screenshot-03.jpg', 'screenshot-04.jpg', 'tmdb_search.png', 'tools.png', 'tvshows.png', 'url.png', 'vavoo.png', 'years.png', '_movies-search.png', '_people-search.png', '_search.png', '_series-search.png']
        if mediaFile in media_files: mediaFile = 'https://raw.githubusercontent.com/xsupdater/xsupdater/backup/logos/media/%s' % mediaFile
        elif xbmcvfs.exists(path.join(artPath, mediaFile)): mediaFile = path.join(artPath, mediaFile)
        elif xbmcvfs.exists(path.join(artPath, 'sites', mediaFile)): mediaFile = path.join(artPath, 'sites', mediaFile)
        else: mediaFile = icon
        return mediaFile
    

