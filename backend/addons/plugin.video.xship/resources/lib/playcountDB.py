

#2021-07-05

import sys, ast
from os import path, stat
from sqlite3 import dbapi2 as db
from sqlite3 import Error as sqlError
from xbmcvfs import mkdir, exists
from resources.lib.control import dataPath, parse_qsl

if not exists(dataPath): mkdir(dataPath)

# DB für Playcount
playcountDB = path.join(dataPath, 'playcount.db')

def _getParams(_params):
    for key, value in _params.items():
        try:
            exec("%s = %s" % (key, value))
        except:
            exec ("%s = '%s'" % (key, value))

def _createSql(table): # IF NOT EXISTS - könnte man auch entfernen
    sql = ''
    if table == 'movie':
        sql = "CREATE TABLE IF NOT EXISTS %s (" \
              "title TEXT, " "name TEXT, " "imdb_id TEXT, " \
              "tmdb_id TEXT, " "playcount INT, " "lastplayed TEXT, " \
              "resume_position REAL, " "total_time REAL )" % table
    elif table == 'tvshow':
        sql = "CREATE TABLE IF NOT EXISTS %s (" \
              "title TEXT, " "name TEXT, " "imdb_id TEXT, " "number_of_seasons INT, " \
              "playcount INT )" % table
    elif table == 'season':
        sql = "CREATE TABLE IF NOT EXISTS %s (" \
              "title TEXT, " "name TEXT, " "season INT, " "number_of_episodes INT, " \
              "playcount INT)" % table
    elif table == 'episode':
        sql = "CREATE TABLE IF NOT EXISTS %s (" \
              "title TEXT, " "name TEXT, " "season INT, " "episode INT, " \
              "playcount INT)" % table
    return sql

# einmalig Tabellen in der DB anlegen wenn die Dateigröße von der Datenbank Datei 0 ist
if not exists(playcountDB) or stat(playcountDB).st_size == 0: # size DB
    conn = db.connect(playcountDB)
    try:
        cursor = conn.cursor()
        tables = ['movie','tvshow', 'season', 'episode']
        for i in tables:
            sql = _createSql(i)
            cursor.execute(sql)
        cursor.close()
    except sqlError as e:
        print (e)   # test
    except Exception as e:
        print (e)   # test
    finally:
        if not (conn is None):
            conn.close()
else:
    # Migration: lastplayed Spalte hinzufuegen falls nicht vorhanden
    conn = db.connect(playcountDB)
    try:
        cursor = conn.cursor()
        cursor.execute("PRAGMA table_info(movie)")
        columns = [col[1] for col in cursor.fetchall()]
        if 'lastplayed' not in columns:
            cursor.execute("ALTER TABLE movie ADD COLUMN lastplayed TEXT")
        if 'tmdb_id' not in columns:
            cursor.execute("ALTER TABLE movie ADD COLUMN tmdb_id TEXT")
        if 'resume_position' not in columns:
            cursor.execute("ALTER TABLE movie ADD COLUMN resume_position REAL")
        if 'total_time' not in columns:
            cursor.execute("ALTER TABLE movie ADD COLUMN total_time REAL")
        # Migration: episode-Tabelle erweitern fuer Lastplayed/Resume
        cursor.execute("PRAGMA table_info(episode)")
        ep_columns = [col[1] for col in cursor.fetchall()]
        if 'imdb_id' not in ep_columns:
            cursor.execute("ALTER TABLE episode ADD COLUMN imdb_id TEXT")
        if 'tmdb_id' not in ep_columns:
            cursor.execute("ALTER TABLE episode ADD COLUMN tmdb_id TEXT")
        if 'lastplayed' not in ep_columns:
            cursor.execute("ALTER TABLE episode ADD COLUMN lastplayed TEXT")
        if 'resume_position' not in ep_columns:
            cursor.execute("ALTER TABLE episode ADD COLUMN resume_position REAL")
        if 'total_time' not in ep_columns:
            cursor.execute("ALTER TABLE episode ADD COLUMN total_time REAL")
        conn.commit()
        cursor.close()
    except:
        pass
    finally:
        conn.close()


# Achtung wird mit MultiThread benutzt
def getPlaycount(mediatype, column_names, column_value, season=0, episode=0):
    conn = _get_connection(playcountDB)
    cursor = conn.cursor()
    sql_get  = _get(mediatype, column_names, column_value, season, episode)
    cursor.execute(sql_get)
    match = cursor.fetchone()
    cursor.close()
    conn.close()
    playcount = match['playcount'] if match else None
    return playcount

def _get_connection(filename):
    conn = db.connect(filename)
    conn.row_factory = _dict_factory
    return conn

def _dict_factory(cursor, row):
    d = {}
    for idx, col in enumerate(cursor.description):
        d[col[0]] = row[idx]
    return d

def _get(mediatype, column_names, column_value, season, episode):
    if mediatype == 'movie':
        sql_get = 'SELECT playcount FROM movie WHERE %s="%s"' % (column_names, column_value)
    elif season and episode:
        sql_get = 'SELECT playcount FROM episode WHERE %s="%s" and season=%s and episode=%s' % (column_names, column_value, season, episode)
    elif season:
        sql_get = 'SELECT playcount FROM season WHERE %s = "%s" and season = %s' % (column_names, column_value, season)
    else:
        sql_get = 'SELECT playcount FROM tvshow WHERE %s = "%s"' % (column_names, column_value)
    return sql_get


def createEntry(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, episode, tmdb_id=None):
    if mediatype == 'movie':
        _createEntry(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, episode, column_names='imdb_id', tmdb_id=tmdb_id)
    if season and episode:
        _createEntry(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, episode, tmdb_id=tmdb_id)
        name = name[:-3]
        _createEntry(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, None)
        name = name[:-4]
        _createEntry(mediatype, title, name, imdb, number_of_seasons, None, number_of_episodes, None)
    elif season:
        _createEntry(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, None)
        name = name[:-4]
        _createEntry(mediatype, title, name, imdb, number_of_seasons, None, number_of_episodes, None)
    else:
        _createEntry(mediatype, title, name, imdb, number_of_seasons, None, number_of_episodes, None)


def _createEntry(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, episode, column_names='title', tmdb_id=None):
    if column_names == 'imdb_id':
        column_value = imdb
    elif column_names == 'title':
        column_value = title
    else:
        column_value = name
    conn = _get_connection(playcountDB)  # dict
    cursor = conn.cursor()
    sql = _get(mediatype, column_names, column_value, season, episode)
    cursor.execute(sql)
    match = cursor.fetchone()
    if match is None:
        sql_insert, sql_value  = _sql_insert(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, episode, tmdb_id=tmdb_id)
        cursor.execute(sql_insert , sql_value)
    elif mediatype == 'movie':
        from datetime import datetime
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        if tmdb_id:
            cursor.execute('UPDATE movie SET lastplayed = ?, tmdb_id = ? WHERE imdb_id = ?', (now, str(tmdb_id), imdb))
        else:
            cursor.execute('UPDATE movie SET lastplayed = ? WHERE imdb_id = ?', (now, imdb))
    elif season and episode:
        from datetime import datetime
        now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        updates = ['lastplayed = ?']
        values = [now]
        if tmdb_id:
            updates.append('tmdb_id = ?')
            values.append(str(tmdb_id))
        if imdb:
            updates.append('imdb_id = ?')
            values.append(imdb)
        values.append(name)
        cursor.execute('UPDATE episode SET %s WHERE name = ?' % ', '.join(updates), values)
    conn.commit()
    cursor.close()
    conn.close()

def _sql_insert(mediatype, title, name, imdb, number_of_seasons, season, number_of_episodes, episode, tmdb_id=None):
    if mediatype == 'movie':
        from datetime import datetime
        sql_insert = 'INSERT INTO movie (title, name, imdb_id, tmdb_id, playcount, lastplayed) Values (?, ?, ?, ?, ?, ?)'
        sql_value = (title, name, imdb, str(tmdb_id) if tmdb_id else None, 0, datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    elif season and episode:
        from datetime import datetime
        sql_insert = 'INSERT INTO episode (title, name, season, episode, playcount, imdb_id, tmdb_id, lastplayed) Values (?, ?, ?, ?, ?, ?, ?, ?)'
        sql_value = (title, name, season, episode, 0, imdb, str(tmdb_id) if tmdb_id else None, datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    elif season:
        sql_insert = 'INSERT INTO season (title, name, season, number_of_episodes, playcount) Values (?, ?, ?, ?, ?)'
        sql_value = (title, name, season, number_of_episodes, 0)
    else:
        sql_insert = 'INSERT INTO tvshow (title, name, imdb_id, number_of_seasons, playcount) Values (?, ?, ?, ?, ?)'
        sql_value = (title, name, imdb, number_of_seasons, 0)
    return sql_insert, sql_value

def __insert_from_dict(table, size):
    ''' Create a SQL Insert statement with dictionary values '''
    sql = 'INSERT INTO %s ' % table
    format = ', '.join('?' * size)
    sql_insert = sql + 'Values (%s)' % format
    return sql_insert


def UpdatePlaycount(params): # for context menu
    mediatype = systitle = sysname = imdb_id = number_of_seasons = season = number_of_episodes = episode = playCount = ''
    meta = ast.literal_eval(params['meta'])
    if 'mediatype' in meta and meta['mediatype']: mediatype = meta['mediatype']
    if 'systitle' in meta and meta['systitle']: systitle = meta['systitle']
    if 'sysname' in meta and meta['sysname']: sysname = meta['sysname']
    if 'imdb_id' in meta and meta['imdb_id']: imdb_id = meta['imdb_id']
    if 'number_of_seasons' in meta and meta['number_of_seasons']: number_of_seasons = meta['number_of_seasons']
    if 'season' in meta and meta['season']: season = meta['season']
    if 'number_of_episodes' in meta and meta['number_of_episodes']: number_of_episodes = meta['number_of_episodes']
    if 'episode' in meta and meta['episode']: episode = meta['episode']
    if 'playCount' in params and params['playCount']: playCount = int(params['playCount'])
    if mediatype == 'movie':
        column_names = 'imdb_id'
        column_value = imdb_id
    else:
        column_names = 'title'
        column_value = systitle

    status = getPlaycount(mediatype, column_names, column_value, season, episode)
    if status is None: createEntry(mediatype, systitle, sysname, imdb_id, number_of_seasons, season, number_of_episodes, episode)
    _updatePlaycount(mediatype, systitle, sysname, imdb_id, number_of_seasons, season, number_of_episodes, episode, playCount)


def updatePlaycount(mediatype, title='', name='', id='', number_of_seasons=None, season=None, number_of_episodes=None, episode=None, playcount=None):
    #createEntry(mediatype, title, name, id, number_of_seasons, season, number_of_episodes, episode)
    _updatePlaycount(mediatype, title, name, id, number_of_seasons, season, number_of_episodes, episode, playcount)


def _updatePlaycount(mediatype, title, name, id, number_of_seasons, season, number_of_episodes, episode, playcount):
    conn = db.connect(playcountDB)
    cursor = conn.cursor()
    sql  = _sql_update(mediatype, title, name, id, season, episode, playcount)
    cursor.execute(sql)
    conn.commit()
    if mediatype == 'tvshow':  _check(cursor, conn, mediatype, title, name, id, number_of_seasons, season, number_of_episodes, episode, playcount)
    cursor.close()
    conn.close()

def _check(cursor, conn, mediatype, title, name, id, number_of_seasons, season, number_of_episodes, episode, playcount):
    if playcount >= 1:
        sql = _sql_check(title, season, episode)
        if sql == '': return
        cursor.execute(sql)
        matched = cursor.fetchall()
        if not '0' in str(matched) and len(matched) == number_of_episodes or episode == '':
            if episode != '':
                sql = 'UPDATE season SET playcount = %s WHERE title = "%s" and season = %s' % (playcount, title, season)
                cursor.execute(sql)
                conn.commit()
                sql = _sql_check(title, season, None)
                cursor.execute(sql)
                matched = cursor.fetchall()
            if not '0' in str(matched) and len(matched) == number_of_seasons:
                sql = 'UPDATE tvshow SET playcount = %s WHERE title = "%s"' % (playcount, title)
                cursor.execute(sql)
                conn.commit()
    else:
        sql = 'UPDATE tvshow SET playcount = %s WHERE title = "%s"' % (playcount, title)
        cursor.execute(sql)
        conn.commit()
        if episode:
            sql = 'UPDATE season SET playcount = %s WHERE title = "%s" and season = %s' % (playcount, title, season)
            cursor.execute(sql)
            conn.commit()


def _sql_check(title, season, episode):
    if season and episode:
        sql_check = 'SELECT playcount FROM episode WHERE title = "%s" and season = %s' % (title, season)
    elif season:
        sql_check = 'SELECT playcount FROM season WHERE title = "%s"' % title
    else:
        sql_check = ''
    return sql_check


def _sql_update(table, title, name, id, season, episode, playcount):
    if table == 'movie':
        sql_update = 'UPDATE movie SET playcount = %s WHERE imdb_id = "%s"' % (playcount, id)
    elif season and episode:
        sql_update = 'UPDATE episode SET playcount = %s WHERE name = "%s"' % (playcount, name)
    elif season:
        sql_update = 'UPDATE season SET playcount = %s WHERE name = "%s"' % (playcount, name)
    else:
        sql_update = 'UPDATE tvshow SET playcount = %s WHERE name = "%s"' % (playcount, name)
    return sql_update


def getLastPlayedMovies(limit=20):
    """Gibt zuletzt gesehene Filme zurueck."""
    conn = _get_connection(playcountDB)
    cursor = conn.cursor()
    cursor.execute('SELECT tmdb_id, title, MAX(lastplayed) AS lastplayed, MAX(playcount) AS playcount, MAX(resume_position) AS resume_position, MAX(total_time) AS total_time FROM movie WHERE lastplayed IS NOT NULL AND tmdb_id IS NOT NULL GROUP BY tmdb_id ORDER BY lastplayed DESC LIMIT ?', (limit,))
    results = cursor.fetchall()
    cursor.close()
    conn.close()
    return results


def getLastPlayedEpisodes(limit=20):
    """Gibt zuletzt gesehene Episoden zurueck."""
    conn = _get_connection(playcountDB)
    cursor = conn.cursor()
    cursor.execute('SELECT tmdb_id, title, lastplayed, playcount, resume_position, total_time, season, episode, imdb_id FROM episode WHERE lastplayed IS NOT NULL AND tmdb_id IS NOT NULL ORDER BY lastplayed DESC LIMIT ?', (limit,))
    results = cursor.fetchall()
    cursor.close()
    conn.close()
    return results


def updateResume(imdb_id, resume_position, total_time=0):
    """Speichert Resume-Position (0.0-1.0) und Gesamtlaenge fuer einen Film."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE movie SET resume_position = ?, total_time = ? WHERE imdb_id = ?', (resume_position, total_time, imdb_id))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] updateResume FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def incrementPlaycount(imdb_id):
    """Erhoeht playcount um 1 und setzt resume_position auf 0 (fertig geschaut)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE movie SET playcount = playcount + 1, resume_position = 0.0 WHERE imdb_id = ?', (imdb_id,))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] incrementPlaycount FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def incrementEpisodePlaycount(ep_id, season, episode):
    """Erhoeht playcount um 1 und setzt resume_position auf 0 (fertig geschaut). ep_id = imdb_id oder tmdb_id."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE episode SET playcount = playcount + 1, resume_position = 0.0 WHERE (tmdb_id = ? OR imdb_id = ?) AND season = ? AND episode = ?',
                     (ep_id, ep_id, season, episode))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] incrementEpisodePlaycount FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def isInHistory(imdb_id):
    """Prueft ob ein Film in der History steht (lastplayed gesetzt)."""
    conn = _get_connection(playcountDB)
    try:
        cursor = conn.cursor()
        cursor.execute('SELECT 1 FROM movie WHERE imdb_id = ? AND lastplayed IS NOT NULL', (imdb_id,))
        return cursor.fetchone() is not None
    except Exception:
        return False
    finally:
        conn.close()


def isEpisodeInHistory(ep_id, season, episode):
    """Prueft ob eine Episode in der History steht (lastplayed gesetzt)."""
    conn = _get_connection(playcountDB)
    try:
        cursor = conn.cursor()
        cursor.execute('SELECT 1 FROM episode WHERE (tmdb_id = ? OR imdb_id = ?) AND season = ? AND episode = ? AND lastplayed IS NOT NULL',
                       (ep_id, ep_id, season, episode))
        return cursor.fetchone() is not None
    except Exception:
        return False
    finally:
        conn.close()


def getResume(imdb_id):
    """Gibt resume_position (0.0-1.0) fuer einen Film zurueck, oder None."""
    conn = _get_connection(playcountDB)
    try:
        cursor = conn.cursor()
        cursor.execute('SELECT resume_position FROM movie WHERE imdb_id = ?', (imdb_id,))
        row = cursor.fetchone()
        return row['resume_position'] if row else None
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] getResume FEHLER: %s' % e, xbmc.LOGERROR)
        return None
    finally:
        conn.close()


def clearLastplayed(imdb_id):
    """Loescht lastplayed und resume_position (Film unter Mindest-Spielzeit)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE movie SET lastplayed = NULL, resume_position = NULL WHERE imdb_id = ?', (imdb_id,))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] clearLastplayed FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def clearLastplayedByTmdb(tmdb_id):
    """Entfernt einen Film aus dem Verlauf (per tmdb_id)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE movie SET lastplayed = NULL, resume_position = NULL WHERE tmdb_id = ?', (str(tmdb_id),))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] clearLastplayedByTmdb FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def deleteByTmdb(tmdb_id):
    """Löscht alle DB-Einträge eines Films komplett (Playcount, Verlauf, alles)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('DELETE FROM movie WHERE tmdb_id = ?', (str(tmdb_id),))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] deleteByTmdb FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def clearAllLastplayed():
    """Löscht den Film-Verlauf (alle lastplayed + resume_position)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE movie SET lastplayed = NULL, resume_position = NULL WHERE lastplayed IS NOT NULL')
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] clearAllLastplayed FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def clearAllLastplayedEpisodes():
    """Löscht den Episoden-Verlauf (alle lastplayed + resume_position)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE episode SET lastplayed = NULL, resume_position = NULL WHERE lastplayed IS NOT NULL')
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] clearAllLastplayedEpisodes FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def updateEpisodeResume(ep_id, season, episode, resume_position, total_time=0):
    """Speichert Resume-Position (0.0-1.0) und Gesamtlaenge fuer eine Episode. ep_id = imdb_id oder tmdb_id."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE episode SET resume_position = ?, total_time = ? WHERE (tmdb_id = ? OR imdb_id = ?) AND season = ? AND episode = ?',
                     (resume_position, total_time, ep_id, ep_id, season, episode))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] updateEpisodeResume FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def getEpisodeResume(ep_id, season, episode):
    """Gibt resume_position (0.0-1.0) fuer eine Episode zurueck, oder None. ep_id = imdb_id oder tmdb_id."""
    conn = _get_connection(playcountDB)
    try:
        cursor = conn.cursor()
        cursor.execute('SELECT resume_position FROM episode WHERE (tmdb_id = ? OR imdb_id = ?) AND season = ? AND episode = ?',
                       (ep_id, ep_id, season, episode))
        row = cursor.fetchone()
        return row['resume_position'] if row else None
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] getEpisodeResume FEHLER: %s' % e, xbmc.LOGERROR)
        return None
    finally:
        conn.close()


def clearEpisodeLastplayed(ep_id, season, episode):
    """Loescht lastplayed und resume_position einer Episode. ep_id = imdb_id oder tmdb_id."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('UPDATE episode SET lastplayed = NULL, resume_position = NULL WHERE (tmdb_id = ? OR imdb_id = ?) AND season = ? AND episode = ?',
                     (ep_id, ep_id, season, episode))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] clearEpisodeLastplayed FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


def deleteEpisodeByTmdb(tmdb_id, season, episode):
    """Loescht eine Episode aus dem Verlauf (per tmdb_id + season + episode)."""
    conn = db.connect(playcountDB)
    try:
        conn.execute('DELETE FROM episode WHERE tmdb_id = ? AND season = ? AND episode = ?',
                     (str(tmdb_id), season, episode))
        conn.commit()
    except Exception as e:
        import xbmc
        xbmc.log('[xShip] deleteEpisodeByTmdb FEHLER: %s' % e, xbmc.LOGERROR)
    finally:
        conn.close()


