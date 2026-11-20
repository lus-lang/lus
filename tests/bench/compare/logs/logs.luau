-- Access log parsing: generate Apache common log lines, then parse each
-- line with one pattern and aggregate.

local N = tonumber((...)) or 1000000

local state = 42
local function rand(n)
    state = (state * 48271) % 2147483647
    return state % n
end

local METHODS = { "GET", "POST", "PUT", "DELETE" }
local STATUSES = { 200, 200, 200, 301, 404, 500 }
-- The first 8 paths are prefixes that take a numeric id.
local PATHS = {
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
}

local format = string.format

local lines = {}
for i = 1, N do
    local a, b, c = rand(256), rand(256), rand(256)
    local mm, ss = rand(60), rand(60)
    local method = METHODS[rand(4) + 1]
    local k = rand(40)
    local path = PATHS[k + 1]
    if k < 8 then
        path = path .. rand(1000)
    end
    local status = STATUSES[rand(6) + 1]
    local bytes = rand(50000)
    lines[i] = format('10.%d.%d.%d - - [20/Nov/2026:10:%02d:%02d +0000] "%s /%s HTTP/1.1" %d %d',
        a, b, c, mm, ss, method, path, status, bytes)
end
local text = table.concat(lines, "\n") .. "\n"
lines = nil

local pattern = '^(%S+) %- %- %[[^%]]*%] "(%u+) /(%S*) HTTP/1%.1" (%d+) (%d+)$'

local statuses = {}
local ips, nips = {}, 0
local paths = {}
local total = 0
for line in text:gmatch("[^\n]+") do
    local ip, method, path, status, bytes = line:match(pattern)
    if ip then
        statuses[status] = (statuses[status] or 0) + 1
        total = total + tonumber(bytes)
        if not ips[ip] then
            ips[ip] = true
            nips = nips + 1
        end
        paths[path] = (paths[path] or 0) + 1
    end
end

local ranked = {}
for path, hits in pairs(paths) do
    ranked[#ranked + 1] = { path = path, hits = hits }
end
table.sort(ranked, function(x, y)
    if x.hits ~= y.hits then
        return x.hits > y.hits
    end
    return x.path < y.path
end)

local out = { "logs", format("%d", statuses["200"] or 0), format("%d", statuses["404"] or 0),
    format("%d", statuses["500"] or 0), format("%d", total), format("%d", nips) }
for i = 1, 5 do
    out[#out + 1] = format("%d", ranked[i].hits)
end
print(table.concat(out, " "))
