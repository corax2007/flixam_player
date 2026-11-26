

# 2022-04-10
# edit 2026-02-21

from resources.lib.ParameterHandler import ParameterHandler
from resources.lib import control
#from resolveurl.lib import pyaes
import re, sys, xbmc

try:
    from urlparse import urlparse
    from htmlentitydefs import name2codepoint
    from urllib import quote, unquote, quote_plus, unquote_plus
except ImportError:
    from urllib.parse import quote, unquote, quote_plus, unquote_plus, urlparse
    from html.entities import name2codepoint


class cParser:
    @staticmethod
    def _get_compiled_pattern(pattern, flags=0):
        return re.compile(pattern, flags)

    @staticmethod
    def _replaceSpecialCharacters(s):
        try:
            # Umlaute Unicode konvertieren
            for t in (('\\/', '/'), ('&amp;', '&'), ('\\u00c4', 'Ä'), ('\\u00e4', 'ä'),
                      ('\\u00d6', 'Ö'), ('\\u00f6', 'ö'), ('\\u00dc', 'Ü'), ('\\u00fc', 'ü'),
                      ('\\u00df', 'ß'), ('\\u2013', '-'), ('\\u00b2', '²'), ('\\u00b3', '³'),
                      ('\\u00e9', 'é'), ('\\u2018', '‘'), ('\\u201e', '„'), ('\\u201c', '“'),
                      ('\\u00c9', 'É'), ('\\u2026', '...'), ('\\u202f', 'h'), ('\\u2019', '’'),
                      ('\\u0308', '̈'), ('\\u00e8', 'è'), ('#038;', ''), ('\\u00f8', 'ø'),
                      ('／', '/'), ('\\u00e1', 'á'), ('&#8211;', '-'), ('&#8220;', '“'), ('&#8222;', '„'),
                      ('&#8217;', '’'), ('&#8230;', '…'), ('\\u00bc', '¼'), ('\\u00bd', '½'), ('\\u00be', '¾'),
                      ('\\u2153', '⅓'), ('\\u002A', '*')):
                s = s.replace(*t)

            # Umlaute HTML konvertieren
            for h in (('\\/', '/'), ('&#x26;', '&'), ('&#039;', "'"), ("&#39;", "'"),
                      ('&#xC4;', 'Ä'), ('&#xE4;', 'ä'), ('&#xD6;', 'Ö'), ('&#xF6;', 'ö'),
                      ('&#xDC;', 'Ü'), ('&#xFC;', 'ü'), ('&#xDF;', 'ß'), ('&#xB2;', '²'),
                      ('&#xDC;', '³'), ('&#xBC;', '¼'), ('&#xBD;', '½'), ('&#xBE;', '¾'),
                      ('&#8531;', '⅓'), ('&#8727;', '*')):
                s = s.replace(*h)
        except:
            pass
        return s

    @staticmethod
    def parseSingleResult(sHtmlContent, pattern, ignoreCase=False):
        if sHtmlContent:
            flags = re.S | re.M
            if ignoreCase:
                flags |= re.I

            matches = cParser._get_compiled_pattern(pattern, flags).search(sHtmlContent)

            if matches:
                # Check if there's at least one capturing group
                if matches.lastindex is not None and matches.lastindex >= 1:
                    return True, cParser._replaceSpecialCharacters(matches.group(1))
                else:
                    # fallback to the entire match if no group was captured
                    return True, cParser._replaceSpecialCharacters(matches.group(0))
        return False, None

    @staticmethod
    def parse(sHtmlContent, pattern, iMinFoundValue=1, ignoreCase=False):
        if sHtmlContent:
            flags = re.DOTALL
            if ignoreCase:
                flags |= re.I

            aMatches = cParser._get_compiled_pattern(pattern, flags).findall(sHtmlContent)

            if len(aMatches) >= iMinFoundValue:
                # handle both single strings and tuples of matches
                if isinstance(aMatches[0], tuple):
                    # Process each string in tuple
                    aMatches = [tuple(cParser._replaceSpecialCharacters(x) if isinstance(x, str) and x is not None else '' for x in match) for match in aMatches]
                else:
                    # Process single strings
                    aMatches = [cParser._replaceSpecialCharacters(x) if isinstance(x, str) and x is not None else '' for x in aMatches]

                return True, aMatches
        return False, None

    @staticmethod
    def replace(pattern, sReplaceString, sValue):
        return cParser._get_compiled_pattern(pattern).sub(sReplaceString, sValue)

    @staticmethod
    def search(pattern, sValue, ignoreCase=True):
        flags = 0
        if ignoreCase:
            flags = re.IGNORECASE
        return cParser._get_compiled_pattern(pattern, flags).search(sValue)

    @staticmethod
    def escape(sValue):
        return re.escape(sValue)

    @staticmethod
    def getNumberFromString(sValue):
        aMatches = re.compile(r'\d+').findall(sValue)
        if len(aMatches) > 0:
            return int(aMatches[0])
        return 0

    @staticmethod
    def urlparse(sUrl):
        return urlparse(sUrl.replace('www.', '')).netloc.title()

    @staticmethod
    def urlDecode(sUrl):
        return unquote(sUrl)

    @staticmethod
    def urlEncode(sUrl, safe=''):
        return quote(sUrl, safe)

    @staticmethod
    def quote(sUrl):
        return quote(sUrl)

    @staticmethod
    def unquotePlus(sUrl):
        return unquote_plus(sUrl)

    @staticmethod
    def quotePlus(sUrl):
        return quote_plus(sUrl)

    @staticmethod
    def B64decode(text):
        import base64
        return base64.b64decode(text).decode('utf-8')


class logger:
    @staticmethod
    def info(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGINFO)

    @staticmethod
    def debug(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGDEBUG)

    @staticmethod
    def warning(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGWARNING)

    @staticmethod
    def error(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGERROR)

    @staticmethod
    def fatal(sInfo):
        logger.__writeLog(sInfo, cLogLevel=xbmc.LOGFATAL)

    @staticmethod
    def __writeLog(sLog, cLogLevel=xbmc.LOGDEBUG):
        params = ParameterHandler()
        try:
            if params.exist('site'):
                site = params.getValue('site')
                sLog = "\t[%s] -> %s: %s" % (control.addonName, site, sLog)
            else:
                sLog = "\t[%s] %s" % (control.addonName, sLog)
            xbmc.log(sLog, cLogLevel)
        except Exception as e:
            xbmc.log('Logging Failure: %s' % e, cLogLevel)
            pass


# class cUtil:
#     @staticmethod
#     def removeHtmlTags(sValue, sReplace=''):
#         p = re.compile(r'<.*?>')
#         return p.sub(sReplace, sValue)
#
#     @staticmethod
#     def unescape(text):
#         def fixup(m):
#             text = m.group(0)
#             if not text.endswith(';'): text += ';'
#             if text[:2] == '&#':
#                 try:
#                     if text[:3] == '&#x':
#                         return unichr(int(text[3:-1], 16))
#                     else:
#                         return unichr(int(text[2:-1]))
#                 except ValueError:
#                     pass
#             else:
#                 try:
#                     text = unichr(name2codepoint[text[1:-1]])
#                 except KeyError:
#                     pass
#             return text
#
#         if isinstance(text, str):
#             try:
#                 text = text.decode('utf-8')
#             except Exception:
#                 try:
#                     text = text.decode('utf-8', 'ignore')
#                 except Exception:
#                     pass
#         return re.sub(r"&(\\w+;|#x?\\d+;?)", fixup, text.strip())
#
#     @staticmethod
#     def cleanse_text(text):
#         if text is None: text = ''
#         text = cUtil.removeHtmlTags(text)
#         if sys.version_info[0] == 2:
#             text = cUtil.unescape(text)
#             if isinstance(text, unicode):
#                 text = text.encode('utf-8')
#
#         text = text.replace('\\xc3\\x84', 'Ä').replace('\\xc3\\xa4', 'ä')
#         text = text.replace('\\xc3\\x96', 'Ö').replace('\\xc3\\xb6', 'ö')
#         text = text.replace('\\xc3\\x9c', 'Ü').replace('\\xc3\\xbc', 'ü')
#         text = text.replace('\\xc3\\x9f', 'ß').replace("\\'", "'")
#
#         return text
#
#     @staticmethod
#     def evp_decode(cipher_text, passphrase, salt=None):
#         if not salt:
#             salt = cipher_text[8:16]
#             cipher_text = cipher_text[16:]
#         key, iv = cUtil.evpKDF(passphrase, salt)
#         decrypter = pyaes.Decrypter(pyaes.AESModeOfOperationCBC(key, iv))
#         plain_text = decrypter.feed(cipher_text)
#         plain_text += decrypter.feed()
#         return plain_text.decode("utf-8")
#
#     @staticmethod
#     def evpKDF(pwd, salt, key_size=32, iv_size=16):
#         temp = b''
#         fd = temp
#         while len(fd) < key_size + iv_size:
#             h = hashlib.md5()
#             h.update(temp + pwd + salt)
#             temp = h.digest()
#             fd += temp
#         key = fd[0:key_size]
#         iv = fd[key_size:key_size + iv_size]
#         return key, iv

# class cCache(object):
#     _win = None
#     def __init__(self):
#         # see https://kodi.wiki/view/Window_IDs
#         # use WINDOW_SCREEN_CALIBRATION to store all data
#         self._win = xbmcgui.Window(10011) # ? 10000
#
#     def __del__(self):
#         del self._win
#
#     def get(self, key, cache_time):
#         import ast
#         cachedata = self._win.getProperty(key)
#         if cachedata:
#             cachedata = ast.literal_eval(cachedata)
#             if time.time() - cachedata[0] < cache_time:
#                 return cachedata[1]
#             else:
#                 self._win.clearProperty(key)
#
#         return None
#
#     def set(self, key, data):
#         self._win.setProperty(key, repr((time.time(), data)))
#
#     def clear(self):
#         self._win.clearProperties()
