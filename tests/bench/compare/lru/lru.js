// lru: simulate a cache service with an LRU cache of fixed capacity.
const n = process.argv[2] ? parseInt(process.argv[2], 10) : 4000000;
const CAPACITY = 50000;

let state = 42;
function rand(m) {
  state = (state * 48271) % 2147483647;
  return state % m;
}

class LRUCache {
  constructor(capacity) {
    this.capacity = capacity;
    this.map = new Map();
    this.head = { prev: null, next: null };
    this.tail = { prev: this.head, next: null };
    this.head.next = this.tail;
    this.evictions = 0;
  }
  unlink(n) { n.prev.next = n.next; n.next.prev = n.prev; }
  pushFront(n) { n.prev = this.head; n.next = this.head.next; this.head.next.prev = n; this.head.next = n; }
  get(key) {
    const n = this.map.get(key);
    if (n === undefined) return undefined;
    this.unlink(n); this.pushFront(n); return n.value;
  }
  put(key, value) {
    let n = this.map.get(key);
    if (n !== undefined) { n.value = value; this.unlink(n); this.pushFront(n); return; }
    if (this.map.size === this.capacity) {
      const old = this.tail.prev; this.unlink(old); this.map.delete(old.key); this.evictions++;
    }
    n = { key, value, prev: null, next: null };
    this.pushFront(n); this.map.set(key, n);
  }
}
const cache = new LRUCache(CAPACITY);
let hits = 0;
let misses = 0;
for (let i = 0; i < n; i++) {
  const key = "k" + rand(rand(200000) + 1);
  if (rand(10) < 8) {
    const value = cache.get(key);
    if (value !== undefined) {
      hits++;
      value.hits++;
    } else {
      misses++;
      cache.put(key, { key, size: rand(4096), hits: 0 });
    }
  } else {
    cache.put(key, { key, size: rand(4096), hits: 0 });
  }
}

let sum = 0;
for (let n = cache.head.next; n !== cache.tail; n = n.next) sum = (sum + n.value.size) % 1000000007;
console.log(`lru ${hits} ${misses} ${cache.evictions} ${sum}`);
