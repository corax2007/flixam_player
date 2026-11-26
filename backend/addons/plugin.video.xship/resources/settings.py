
import sys
from  xbmcgui import NOTIFICATION_INFO, Dialog
from resources.lib import control
from scrapers import scrapers_source

dialog = Dialog()
name = control.addonInfo('name')

_params = dict(control.parse_qsl(sys.argv[1].replace('?', '')))
_action = _params.get('action')
mode = None
query = None

def window(title='', content='', filename=''):
    import xbmc, xbmcgui, time, os
    if content == '' and filename == '': return
    if content == '' and filename != '':
        file = os.path.join(control.py2_decode(control.translatePath(control.addonInfo('path'))), 'resources', filename)
        if sys.version_info[0] == 2:
            with open(file, 'r') as f:
                content = f.read()
        else:
            with open(file, 'rb') as f:
                content = f.read().decode('utf8')

        window_id = 10147
        control_label = 1
        control_textbox = 5
        timeout = 1
        xbmc.executebuiltin("ActivateWindow({})".format(window_id))
        w = xbmcgui.Window(window_id)
        # Wait for window to open
        start_time = time.time()
        while (not xbmc.getCondVisibility("Window.IsVisible({})".format(window_id)) and
               time.time() - start_time < timeout):
            xbmc.sleep(100)
        # noinspection PyUnresolvedReferences
        w.getControl(control_label).setLabel(title)
        # noinspection PyUnresolvedReferences
        w.getControl(control_textbox).setText(content)


def run(params):
    action = params.get('subaction')

    if action == "Defaults":
        dialog.notification(name , 'Einstellungen wurden übernommen', NOTIFICATION_INFO, 500, sound=False)
        sourceList = scrapers_source.all_providers
        for i in sourceList:
            source_setting = 'provider.' + i
            value = control.getSettingDefault(source_setting)
            control.setSetting(source_setting, value)

    elif action == "toggleAll":
        dialog.notification(name , 'Einstellungen wurden übernommen', NOTIFICATION_INFO, 500, sound=False)
        sourceList = scrapers_source.all_providers
        for i in sourceList:
            source_setting = 'provider.' + i
            control.setSetting(source_setting, params['setting'])

    elif action == "defaultsGerman":
        sourceList = scrapers_source.german_providers
        for i in sourceList:
            source_setting = 'provider.' + i
            value = control.getSettingDefault(source_setting)
            control.setSetting(source_setting, value)

    elif action == "toggleGerman":
        sourceList = scrapers_source.german_providers
        for i in sourceList:
            source_setting = 'provider.' + i
            control.setSetting(source_setting, params['setting'])
            
    elif action == "filterGenres":
        genres = [
            (16, 'Animation'), (28, 'Action'), (12, 'Abenteuer'), (35, 'Komödie'),
            (80, 'Krimi'), (99, 'Dokumentarfilm'), (18, 'Drama'), (10751, 'Familie'),
            (14, 'Fantasy'), (36, 'Historie'), (27, 'Horror'), (10402, 'Musik'),
            (9648, 'Mystery'), (10749, 'Liebesfilm'), (878, 'Science Fiction'),
            (10770, 'TV-Film'), (53, 'Thriller'), (10752, 'Kriegsfilm'), (37, 'Western'),
        ]
        current = control.getSetting('filter.genres')
        current_ids = [int(x.strip()) for x in current.split(',') if x.strip()] if current else []
        labels = [g[1] for g in genres]
        preselect = [idx for idx, g in enumerate(genres) if g[0] in current_ids]
        selected = dialog.multiselect('Genres ausschließen', labels, preselect=preselect)
        if selected is not None:
            ids = ','.join(str(genres[i][0]) for i in selected)
            control.setSetting('filter.genres', ids)

    elif action == "filterCountries":
        countries = [
            ('AR', 'Argentinien'), ('AU', 'Australien'), ('BE', 'Belgien'), ('BR', 'Brasilien'),
            ('CN', 'China'), ('DK', 'Dänemark'), ('FR', 'Frankreich'), ('GB', 'Großbritannien'),
            ('ID', 'Indonesien'), ('IN', 'Indien'), ('IR', 'Iran'), ('IL', 'Israel'),
            ('IT', 'Italien'), ('JP', 'Japan'), ('CA', 'Kanada'), ('CO', 'Kolumbien'),
            ('KR', 'Südkorea'), ('MX', 'Mexiko'), ('NL', 'Niederlande'), ('NO', 'Norwegen'),
            ('AT', 'Österreich'), ('PH', 'Philippinen'), ('PL', 'Polen'), ('RO', 'Rumänien'),
            ('RU', 'Russland'), ('SE', 'Schweden'), ('CH', 'Schweiz'), ('ES', 'Spanien'),
            ('TH', 'Thailand'), ('CZ', 'Tschechien'), ('TR', 'Türkei'), ('HU', 'Ungarn'),
            ('US', 'USA'),
        ]
        current = control.getSetting('filter.countries')
        current_codes = [x.strip() for x in current.split(',') if x.strip()] if current else []
        labels = ['%s - %s' % (c[0], c[1]) for c in countries]
        preselect = [idx for idx, c in enumerate(countries) if c[0] in current_codes]
        selected = dialog.multiselect('Länder ausschließen', labels, preselect=preselect)
        if selected is not None:
            codes = ','.join(countries[i][0] for i in selected)
            control.setSetting('filter.countries', codes)


        
