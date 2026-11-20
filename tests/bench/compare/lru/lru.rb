# lru: simulate a cache service with an LRU cache of fixed capacity.
n = ARGV[0] ? ARGV[0].to_i : 4000000
CAPACITY = 50000

$state = 42
def rand_int(m)
  $state = ($state * 48271) % 2147483647
  $state % m
end

Entry = Struct.new(:key, :size, :hits)

# A Hash iterates in insertion order, so re-inserting a key on use keeps
# the least recently used entry first.
class LRUCache
  attr_reader :items, :evictions

  def initialize(capacity)
    @capacity = capacity
    @items = {}
    @evictions = 0
  end

  def get(key)
    value = @items.delete(key)
    @items[key] = value if value
    value
  end

  def put(key, value)
    if @items.delete(key).nil? && @items.size == @capacity
      @items.shift
      @evictions += 1
    end
    @items[key] = value
  end
end

cache = LRUCache.new(CAPACITY)
hits = 0
misses = 0
n.times do
  key = "k#{rand_int(rand_int(200000) + 1)}"
  if rand_int(10) < 8
    value = cache.get(key)
    if value
      hits += 1
      value.hits += 1
    else
      misses += 1
      cache.put(key, Entry.new(key, rand_int(4096), 0))
    end
  else
    cache.put(key, Entry.new(key, rand_int(4096), 0))
  end
end

sum = 0
cache.items.each_value { |v| sum = (sum + v.size) % 1000000007 }
puts "lru #{hits} #{misses} #{cache.evictions} #{sum}"
