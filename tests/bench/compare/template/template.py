# template: render an HTML report for generated items with escaping,
# built with a list and str.join.
import sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000000

state = 42


def rand(n):
    global state
    state = (state * 48271) % 2147483647
    return state % n


TAGS = ["new", "sale", "<hot>", "a&b", '"quoted"', "it's", "x>y", "plain"]


def escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            .replace('"', "&quot;").replace("'", "&#39;"))


def make_items(n):
    items = []
    for id in range(1, n + 1):
        title = f"Item {id} & {rand(1000)} {TAGS[rand(8)]}"
        price = rand(100000)
        tags = [TAGS[rand(8)] for _ in range(rand(3) + 1)]
        items.append({"id": id, "title": title, "price": price, "tags": tags})
    return items


def render(items):
    out = [
        "<!DOCTYPE html>\n<html><head><title>Report</title></head><body>\n",
        "<h1>Items &amp; prices</h1>\n<table>\n",
        "<tr><th>ID</th><th>Title</th><th>Price</th><th>Tags</th></tr>\n",
    ]
    for item in items:
        dollars, cents = divmod(item["price"], 100)
        tags = ", ".join(escape(t) for t in item["tags"])
        out.append(f"<tr><td>{item['id']}</td><td>{escape(item['title'])}</td>"
                   f"<td>${dollars}.{cents:02d}</td><td>{tags}</td></tr>\n")
    out.append(f"</table>\n<p>{len(items)} items</p>\n</body></html>\n")
    return "".join(out)


def main():
    page = render(make_items(N)).encode("ascii")
    total = sum(page[96::97])
    print(f"template {len(page)} {total % 1000000007}")


main()
