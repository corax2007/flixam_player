SORT_METHOD_NONE = 0
SORT_METHOD_LABEL = 1
SORT_METHOD_UNSORTED = 0
SORT_METHOD_DATE = 2
SORT_METHOD_VIDEO_RATING = 3
SORT_METHOD_VIDEO_RUNTIME = 4
SORT_METHOD_VIDEO_TITLE = 5
SORT_METHOD_GENRE = 6
SORT_METHOD_PROGRAM_COUNT = 7

DIRECTORY_ITEMS = []
RESOLVED_URL = None

def reset():
    global DIRECTORY_ITEMS, RESOLVED_URL
    DIRECTORY_ITEMS = []
    RESOLVED_URL = None

def addDirectoryItem(handle, url, listitem, isFolder=False, totalItems=0):
    DIRECTORY_ITEMS.append({
        "title": getattr(listitem, "label", ""),
        "url": url,
        "isFolder": isFolder,
        "art": getattr(listitem, "art", {}),
        "info": getattr(listitem, "info", {}),
    })
    return True

def addDirectoryItems(handle, items, totalItems=0):
    for url, listitem, isFolder in items:
        addDirectoryItem(handle, url, listitem, isFolder)
    return True

def endOfDirectory(handle, succeeded=True, updateListing=False, cacheToDisc=True):
    pass

def setContent(handle, content):
    pass

def addSortMethod(handle, sortMethod):
    pass

def setResolvedUrl(handle, succeeded, listitem):
    global RESOLVED_URL
    if succeeded and listitem:
        RESOLVED_URL = getattr(listitem, "path", None)
        if RESOLVED_URL:
            try:
                import xbmc
                xbmc.abort_playback(RESOLVED_URL)
            except Exception:
                pass


def setPluginCategory(handle, category):
    pass
