# JSON encode and decode round trip over generated records.
import sys

# This file is named json.py, so drop its own directory from the import path
# before loading the standard library module of the same name.
del sys.path[0]
import json  # noqa: E402

N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000000

state = 42


def rand(n):
    global state
    state = (state * 48271) % 2147483647
    return state % n


def main():
    records = []
    for i in range(1, N + 1):
        name = "user" + str(rand(100000))
        age = rand(90)
        active = rand(2) == 1
        t1 = "t" + str(rand(50))
        t2 = "t" + str(rand(50))
        score = rand(1000000)
        records.append({"id": i, "name": name, "age": age, "active": active, "tags": [t1, t2], "score": score})

    text = json.dumps(records, separators=(",", ":"))
    back = json.loads(text)

    active = 0
    agesum = 0
    scoresum = 0
    seen = set()
    for r in back:
        if r["active"]:
            active += 1
        agesum += r["age"]
        scoresum += r["score"]
        seen.update(r["tags"])

    print(f"json {active} {agesum} {scoresum % 1000000007} {len(seen)} {len(text)}")


main()
