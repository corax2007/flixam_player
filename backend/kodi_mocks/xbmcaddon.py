import os
import xml.etree.ElementTree as ET

# In Kodi liefert Addon() ohne ID das gerade laufende Addon. Der Mock muss
# das correspondingly tun, sonst lesen Scrapers fremde Settings.
_CURRENT_ADDON = None


def current_addon():
    return _CURRENT_ADDON


def set_current_addon(addon_id):
    global _CURRENT_ADDON
    _CURRENT_ADDON = addon_id


class Addon:
    def __init__(self, id=None):
        self.id = id or _CURRENT_ADDON or "plugin.video.xstream"
        self.addon_dir = os.path.expanduser(f"~/flixam_player/backend/addons/{self.id}")
        self._settings = {}
        self._load_defaults()

    def _load_defaults(self):
        xml_path = os.path.join(self.addon_dir, "resources", "settings.xml")
        if os.path.exists(xml_path):
            try:
                tree = ET.parse(xml_path)
                for elem in tree.findall(".//setting"):
                    key = elem.get("id")
                    if not key:
                        continue
                    # Kodi erlaubt Defaults als Attribut (default="x") oder als
                    # Kind-Element (<default>x</default>) - die xstream-Settings
                    # nutzen ausschliesslich die Kind-Variante.
                    val = elem.get("default")
                    if val is None:
                        default_el = elem.find("default")
                        if default_el is not None and default_el.text is not None:
                            val = default_el.text.strip()
                        else:
                            val = ""
                    # Boolean-Settings normalisieren: Addons vergleichen oft
                    # exakt gegen 'true' (Kodi liefert 'true'/'false').
                    if elem.get("type") == "boolean":
                        val = "true" if str(val).strip().lower() in ("true", "1", "yes", "on") else "false"
                    self._settings[key] = str(val)
            except Exception:
                pass

    def getAddonInfo(self, info_id):
        if info_id == "path":
            return self.addon_dir
        if info_id == "profile":
            p = os.path.expanduser(f"~/flixam_player/backend/kodi_data/addon_data/{self.id}/")
            os.makedirs(p, exist_ok=True)
            return p
        if info_id in ("id", "name"):
            return self.id
        if info_id == "version":
            return "21.0.0"
        return ""

    def getSetting(self, key):
        return str(self._settings.get(key, ""))

    def getSettingBool(self, key):
        return self.getSetting(key).lower() in ("true", "1", "yes")

    def getSettingInt(self, key):
        try:
            return int(float(self.getSetting(key)))
        except ValueError:
            return 0

    def getSettingNumber(self, key):
        try:
            return float(self.getSetting(key))
        except ValueError:
            return 0.0

    def setSetting(self, key, value):
        self._settings[key] = str(value)

    def setSettingBool(self, key, value):
        self._settings[key] = "true" if value else "false"

    def setSettingInt(self, key, value):
        self._settings[key] = str(int(value))

    def setSettingNumber(self, key, value):
        self._settings[key] = str(float(value))

    def openSettings(self):
        print(f"[ADDON] openSettings aufgerufen für {self.id}")

    def getAddonPath(self, addon_id=None):
        return os.path.join(self.addon_dir, "resources")

    def getInstallPath(self, addon_id=None):
        return self.addon_dir

    def getEnabled(self, addon_id=None):
        return True

    def getAuthor(self, addon_id=None):
        return "xStream"

    def getVersion(self, addon_id=None):
        return "21.0.0"

    def getLocalizedString(self, code):
        try:
            import xbmc
            value = xbmc.getLocalizedString(code)
            if value and not str(value).startswith("String_"):
                return value
        except Exception:
            pass
        return f"String_{code}"
