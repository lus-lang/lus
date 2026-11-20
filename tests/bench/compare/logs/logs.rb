# Access log parsing: generate Apache common log lines, then parse each
# line with one regular expression and aggregate.
require "set"

N = ARGV[0] ? ARGV[0].to_i : 1000000

$state = 42
def rand_n(n)
  $state = ($state * 48271) % 2147483647
  $state % n
end

METHODS = %w[GET POST PUT DELETE].freeze
STATUSES = [200, 200, 200, 301, 404, 500].freeze
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
].freeze

LINE = /\A(\S+) - - \[[^\]]*\] "([A-Z]+) \/(\S*) HTTP\/1\.1" (\d+) (\d+)\z/

lines = Array.new(N) do
  a = rand_n(256)
  b = rand_n(256)
  c = rand_n(256)
  mm = rand_n(60)
  ss = rand_n(60)
  method = METHODS[rand_n(4)]
  k = rand_n(40)
  path = PATHS[k]
  path = "#{path}#{rand_n(1000)}" if k < 8
  status = STATUSES[rand_n(6)]
  bytes = rand_n(50000)
  format('10.%d.%d.%d - - [20/Nov/2026:10:%02d:%02d +0000] "%s /%s HTTP/1.1" %d %d',
         a, b, c, mm, ss, method, path, status, bytes)
end
text = lines.join("\n") << "\n"
lines = nil

statuses = Hash.new(0)
ips = Set.new
paths = Hash.new(0)
total = 0
text.each_line(chomp: true) do |line|
  m = LINE.match(line)
  next unless m
  ip, _method, path, status, bytes = m.captures
  statuses[status] += 1
  total += bytes.to_i
  ips << ip
  paths[path] += 1
end

top = paths.sort_by { |path, hits| [-hits, path] }.first(5).map(&:last)
puts "logs #{statuses["200"]} #{statuses["404"]} #{statuses["500"]} #{total} #{ips.size} #{top.join(" ")}"
