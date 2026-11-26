class ListItem:
    def __init__(self, label="", label2="", path="", offscreen=False):
        self.label = label
        self.label2 = label2
        self.path = path
        self.art = {}
        self.info = {}
        self.properties = {}

    def setArt(self, values):
        self.art.update(values)

    def setInfo(self, type, infoLabels):
        self.info.update(infoLabels)

    def setProperty(self, key, value):
        self.properties[key] = value

    def addContextMenuItems(self, items, replaceItems=False):
        pass

    def setMimeType(self, mimeType):
        pass

    def setContentLookup(self, contentLookup):
        pass

    def setIsFolder(self, v):
        self.isFolder = v

    def getProperty(self, key):
        return self.properties.get(key, "")

    def getVideoInfoTag(self):
        return VideoInfoTag()

    def getAudioInfoTag(self):
        return VideoInfoTag()

    def getSubtitleInfoTag(self):
        return VideoInfoTag()

class VideoInfoTag:
    """Mock fuer xbmcgui.ListItem.getVideoInfoTag() / Audio-/Subtitle-Tags.

    Kodi-InfoTag-Objekt: fluent Setter wie setMediaType/setPlot/setRating sowie
    Getter wie getMediaType. Unbekannte Attribute fallen auf No-Ops zurueck.
    """
    def __init__(self, initial=None):
        self._data = dict(initial or {})

    def __getattr__(self, name):
        if isinstance(name, str) and name.startswith("get") and len(name) > 3:
            key = name[3:]
            default = self._data.get(key, "")
            return lambda *args, **kwargs: default
        def _noop(*args, **kwargs):
            return None
        return _noop

    def getData(self):
        return dict(self._data)


class _DummyControl:
    def setLabel(self, label=""):
        pass
    def setText(self, text=""):
        pass
    def setEnabled(self, enabled=True):
        pass
    def setVisible(self, visible=True):
        pass
    def setVisibleCondition(self, condition):
        pass

def getCurrentWindowId():
    return 10000

# Action-IDs (vom Input-Mapper / Captcha-Controls genutzt)
ACTION_MOVE_DOWN = 12
ACTION_MOVE_LEFT = 272
ACTION_MOVE_RIGHT = 271
ACTION_MOVE_UP = 273
ACTION_NAV_BACK = 158
ACTION_SELECT_ITEM = 11
ALPHANUM_HIDE_INPUT = 1204
NOTIFICATION_INFO = 0
NOTIFICATION_WARNING = 1
NOTIFICATION_ERROR = 2

class Control:
    def __init__(self, *args, **kwargs):
        pass
    def getId(self):
        return 0
    def setEnabled(self, enabled):
        pass
    def setVisible(self, visible):
        pass
    def setFocus(self, focus):
        pass
    def setLabel(self, label):
        pass
    def setText(self, text):
        pass
    def getLabel(self):
        return ""
    def getText(self):
        return ""

class ControlButton(Control):
    pass

class ControlImage(Control):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

class ControlLabel(Control):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

class ControlFadeLabel(ControlLabel):
    pass

class Window:
    def __init__(self, existingWindowId=-1):
        self.properties = {}
    def show(self):
        pass
    def close(self):
        pass
    def getControl(self, controlId):
        return _DummyControl()
    def setProperty(self, key, value):
        self.properties[key] = value
    def clearProperty(self, key):
        self.properties.pop(key, None)
    def setIsFolder(self, v):
        self.isFolder = v

    def getProperty(self, key):
        return self.properties.get(key, "")

class WindowDialog(Window):
    pass

class WindowXML(Window):
    def __init__(self, xmlFilename, scriptPath, defaultSkin="Default", defaultRes="720p"):
        super().__init__()

class WindowXMLDialog(WindowXML):
    pass

class Dialog:
    def notification(self, heading, message, icon="", time=5000, sound=True):
        print(f"[NOTIFY] {heading}: {message}")

    def select(self, heading, list, autoclose=0, preselect=-1, useDetails=False):
        print(f"[SELECT] {heading} -> Optionen: {list}")
        return 0 if list else -1

    def ok(self, heading, line1, line2="", line3=""):
        print(f"[OK] {heading}: {line1} {line2}")
        return True

class DialogProgress:
    def create(self, heading, line1="", line2="", line3=""):
        pass
    def update(self, percent, line1="", line2="", line3=""):
        pass
    def iscanceled(self):
        return False
    def close(self):
        pass


class DialogProgressBG(DialogProgress):
    pass
