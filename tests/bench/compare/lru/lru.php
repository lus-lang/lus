<?php
// lru: simulate a cache service with an LRU cache of fixed capacity.
$n = isset($argv[1]) ? (int)$argv[1] : 4000000;
const CAPACITY = 50000;

$state = 42;
function rand_int(int $m): int {
    global $state;
    $state = ($state * 48271) % 2147483647;
    return $state % $m;
}

final class Entry {
    public function __construct(
        public string $key,
        public int $size,
        public int $hits = 0,
    ) {}
}

final class Node {
    public ?Node $prev = null;
    public ?Node $next = null;
    public function __construct(public string $key, public ?Entry $value) {}
}

// A hash map from key to node plus a doubly linked list of nodes, most
// recently used first. head and tail are sentinels.
final class LRUCache {
    private array $map = [];
    private Node $head;
    private Node $tail;
    public int $evictions = 0;

    public function __construct(private int $capacity) {
        $this->head = new Node("", null);
        $this->tail = new Node("", null);
        $this->head->next = $this->tail;
        $this->tail->prev = $this->head;
    }

    private function unlink(Node $node): void {
        $node->prev->next = $node->next;
        $node->next->prev = $node->prev;
    }

    private function pushFront(Node $node): void {
        $node->prev = $this->head;
        $node->next = $this->head->next;
        $this->head->next->prev = $node;
        $this->head->next = $node;
    }

    public function get(string $key): ?Entry {
        $node = $this->map[$key] ?? null;
        if ($node === null) return null;
        $this->unlink($node);
        $this->pushFront($node);
        return $node->value;
    }

    public function put(string $key, Entry $value): void {
        $node = $this->map[$key] ?? null;
        if ($node !== null) {
            $node->value = $value;
            $this->unlink($node);
            $this->pushFront($node);
            return;
        }
        if (count($this->map) === $this->capacity) {
            $old = $this->tail->prev;
            $this->unlink($old);
            unset($this->map[$old->key]);
            $this->evictions++;
        }
        $node = new Node($key, $value);
        $this->pushFront($node);
        $this->map[$key] = $node;
    }

    public function sizeSum(): int {
        $sum = 0;
        for ($node = $this->head->next; $node !== $this->tail; $node = $node->next) {
            $sum = ($sum + $node->value->size) % 1000000007;
        }
        return $sum;
    }
}

$cache = new LRUCache(CAPACITY);
$hits = 0;
$misses = 0;
for ($i = 0; $i < $n; $i++) {
    $key = "k" . rand_int(rand_int(200000) + 1);
    if (rand_int(10) < 8) {
        $value = $cache->get($key);
        if ($value !== null) {
            $hits++;
            $value->hits++;
        } else {
            $misses++;
            $cache->put($key, new Entry($key, rand_int(4096)));
        }
    } else {
        $cache->put($key, new Entry($key, rand_int(4096)));
    }
}

echo "lru $hits $misses {$cache->evictions} {$cache->sizeSum()}\n";
