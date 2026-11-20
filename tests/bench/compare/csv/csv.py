# csv: generate CSV text, parse it with the csv module, and aggregate per region.
import sys

# This file is named csv.py, so drop its own directory from the import path
# before importing the standard library csv module.
del sys.path[0]

import csv  # noqa: E402
import io  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 2000000

state = 42


def rand(n):
    global state
    state = (state * 48271) % 2147483647
    return state % n


REGIONS = ["north", "south", "east", "west", "central", "coastal", "mountain", "island"]
WORDS = ["fragile", "gift", "urgent", "bulk", "sample"]


def generate(n):
    parts = ["id,region,product,quantity,price_cents,note\n"]
    for id in range(1, n + 1):
        region = REGIONS[rand(8)]
        product = rand(200)
        quantity = rand(20) + 1
        price = rand(100000)
        k = rand(10)
        if k == 0:
            note = '"big, ""rush"" order"'
        elif k < 4:
            note = ""
        else:
            note = WORDS[rand(5)]
        parts.append(f"{id},{region},p{product},{quantity},{price},{note}\n")
    return "".join(parts)


def main():
    rows = list(csv.reader(io.StringIO(generate(N))))
    stats = {r: [0, 0, 0, 0] for r in REGIONS}
    commas = 0
    for r in rows[1:]:
        st = stats[r[1]]
        q = int(r[3])
        p = int(r[4])
        st[0] += 1
        st[1] += q
        st[2] += q * p
        if p > st[3]:
            st[3] = p
        if "," in r[5]:
            commas += 1
    out = ["csv"]
    for name in REGIONS:
        st = stats[name]
        out.append(f"{st[0]} {st[1]} {st[2] % 1000000007} {st[3]}")
    out.append(str(commas))
    print(" ".join(out))


main()
