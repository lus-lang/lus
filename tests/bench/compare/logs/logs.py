# Access log parsing: generate Apache common log lines, then parse each
# line with one regular expression and aggregate.
import re
import sys
from collections import Counter

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000000

state = 42


def rand(n):
    global state
    state = (state * 48271) % 2147483647
    return state % n


METHODS = ["GET", "POST", "PUT", "DELETE"]
STATUSES = [200, 200, 200, 301, 404, 500]
# The first 8 paths are prefixes that take a numeric id.
PATHS = [
    "api/v1/items/", "api/v1/users/", "api/v1/orders/", "api/v1/carts/",
    "api/v2/items/", "api/v2/users/", "api/v2/search/", "blog/posts/",
    "home", "index.html", "about.html", "contact.html",
    "login", "logout", "signup", "favicon.ico",
    "robots.txt", "sitemap.xml", "css/main.css", "css/print.css",
    "js/app.js", "js/vendor.js", "img/logo.png", "img/banner.jpg",
    "img/icons.svg", "fonts/inter.woff2", "api/v1/health", "api/v1/status",
    "api/v1/items", "api/v1/users", "api/v1/orders", "api/v2/items",
    "api/v2/search", "docs/index.html", "docs/guide.html", "docs/api.html",
    "blog", "blog/feed.xml", "pricing", "download",
]

LINE = re.compile(r'^(\S+) - - \[[^\]]*\] "([A-Z]+) /(\S*) HTTP/1\.1" (\d+) (\d+)$')


def main():
    lines = []
    for _ in range(N):
        a, b, c = rand(256), rand(256), rand(256)
        mm, ss = rand(60), rand(60)
        method = METHODS[rand(4)]
        k = rand(40)
        path = PATHS[k]
        if k < 8:
            path += str(rand(1000))
        status = STATUSES[rand(6)]
        nbytes = rand(50000)
        lines.append(f'10.{a}.{b}.{c} - - [20/Nov/2026:10:{mm:02d}:{ss:02d} +0000] "{method} /{path} HTTP/1.1" {status} {nbytes}')
    text = "\n".join(lines) + "\n"
    del lines

    statuses = Counter()
    ips = set()
    paths = Counter()
    total = 0
    for line in text.splitlines():
        m = LINE.match(line)
        if m:
            ip, method, path, status, nbytes = m.groups()
            statuses[status] += 1
            total += int(nbytes)
            ips.add(ip)
            paths[path] += 1

    top = sorted(paths.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
    hits = " ".join(str(n) for _, n in top)
    print(f"logs {statuses['200']} {statuses['404']} {statuses['500']} {total} {len(ips)} {hits}")


main()
