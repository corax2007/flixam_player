# -*- coding: utf-8 -*-
# FlareSolverr integration for Cloudflare bypass
# Called from requestHandler.py when Cloudflare is detected.
# Setting empty = never called, zero overhead.

import json
import time
from urllib.request import Request, urlopen
from urllib.parse import urlparse
from http.cookiejar import Cookie
from resources.lib.tools import logger

_FS_TIMEOUT = 10  # seconds to wait for FlareSolverr HTTP response
_FS_MAX_TIMEOUT = 60000  # max timeout for FlareSolverr to solve challenge (ms)


def solve(fs_url, url):
    """
    Call FlareSolverr to fetch a Cloudflare-protected URL.

    Args:
        fs_url: FlareSolverr base URL (e.g. http://192.168.2.218:8191)
        url: the Cloudflare-blocked URL to fetch

    Returns:
        (html, cookies_list, user_agent) on success, None on any failure.
    """
    try:
        api_url = fs_url.rstrip('/')
        if not api_url.endswith('/v1'):
            api_url += '/v1'

        payload = json.dumps({
            "cmd": "request.get",
            "url": url,
            "maxTimeout": _FS_MAX_TIMEOUT
        }).encode('utf-8')

        req = Request(api_url, data=payload,
                      headers={'Content-Type': 'application/json'})
        resp = urlopen(req, timeout=_FS_TIMEOUT + _FS_MAX_TIMEOUT // 1000)
        result = json.loads(resp.read().decode('utf-8'))

        if result.get('status') != 'ok':
            logger.info(' -> [flaresolverr]: failed: %s' % result.get('message', ''))
            return None

        solution = result['solution']
        html = solution.get('response', '')
        cookies = solution.get('cookies', [])
        user_agent = solution.get('userAgent', '')

        domain = urlparse(url).netloc
        logger.info(' -> [flaresolverr]: solved %s (%d bytes, %d cookies)'
                     % (domain, len(html), len(cookies)))
        return (html, cookies, user_agent)

    except Exception as e:
        logger.error(' -> [flaresolverr]: error: %s' % str(e))
        return None


def inject_cookies(cookie_jar, fs_cookies):
    """
    Convert FlareSolverr cookie dicts to http.cookiejar.Cookie objects
    and add them to the cookie jar.
    """
    for c in fs_cookies:
        try:
            cookie = Cookie(
                version=0,
                name=c['name'],
                value=c['value'],
                port=None, port_specified=False,
                domain=c.get('domain', ''),
                domain_specified=bool(c.get('domain')),
                domain_initial_dot=c.get('domain', '').startswith('.'),
                path=c.get('path', '/'),
                path_specified=True,
                secure=c.get('secure', False),
                expires=int(c.get('expiry', time.time() + 7200)),
                discard=False,
                comment=None, comment_url=None, rest={}
            )
            cookie_jar.set_cookie(cookie)
        except Exception as e:
            logger.error(' -> [flaresolverr]: cookie inject error: %s' % str(e))
