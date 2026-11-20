# lru: simulate a cache service with an LRU cache of fixed capacity.
import sys
from collections import OrderedDict

n = int(sys.argv[1]) if len(sys.argv) > 1 else 4000000
CAPACITY = 50000

state = 42


def rand(m):
    global state
    state = (state * 48271) % 2147483647
    return state % m


class LRUCache:
    def __init__(self, capacity):
        self.capacity = capacity
        self.items = OrderedDict()
        self.evictions = 0

    def get(self, key):
        value = self.items.get(key)
        if value is not None:
            self.items.move_to_end(key)
        return value

    def put(self, key, value):
        if key in self.items:
            self.items[key] = value
            self.items.move_to_end(key)
            return
        if len(self.items) == self.capacity:
            self.items.popitem(last=False)
            self.evictions += 1
        self.items[key] = value


cache = LRUCache(CAPACITY)
hits = misses = 0
for _ in range(n):
    key = "k" + str(rand(rand(200000) + 1))
    if rand(10) < 8:
        value = cache.get(key)
        if value is not None:
            hits += 1
            value["hits"] += 1
        else:
            misses += 1
            cache.put(key, {"key": key, "size": rand(4096), "hits": 0})
    else:
        cache.put(key, {"key": key, "size": rand(4096), "hits": 0})

total = 0
for value in cache.items.values():
    total = (total + value["size"]) % 1000000007
print(f"lru {hits} {misses} {cache.evictions} {total}")
