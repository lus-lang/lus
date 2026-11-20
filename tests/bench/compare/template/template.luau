-- template: render an HTML report for generated items with escaping,
-- built with table.concat.

local N = tonumber((...)) or 1000000

local state = 42
local function rand(n)
    state = (state * 48271) % 2147483647
    return state % n
end

local TAGS = { "new", "sale", "<hot>", "a&b", '"quoted"', "it's", "x>y", "plain" }

local items = {}
for id = 1, N do
    local title = "Item " .. id .. " & " .. rand(1000) .. " " .. TAGS[rand(8) + 1]
    local price = rand(100000)
    local tags = {}
    for j = 1, rand(3) + 1 do tags[j] = TAGS[rand(8) + 1] end
    items[id] = { id = id, title = title, price = price, tags = tags }
end

local ESC = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }
local function escape(s)
    return (string.gsub(s, "[&<>\"']", ESC))
end

local function render(list)
    local out = {
        "<!DOCTYPE html>\n<html><head><title>Report</title></head><body>\n",
        "<h1>Items &amp; prices</h1>\n<table>\n",
        "<tr><th>ID</th><th>Title</th><th>Price</th><th>Tags</th></tr>\n",
    }
    local n = #out
    local format = string.format
    for i = 1, #list do
        local item = list[i]
        local tags = item.tags
        local escaped = {}
        for j = 1, #tags do escaped[j] = escape(tags[j]) end
        local price = item.price
        n = n + 1
        out[n] = format("<tr><td>%d</td><td>%s</td><td>$%d.%02d</td><td>%s</td></tr>\n",
            item.id, escape(item.title), math.floor(price / 100), price % 100,
            table.concat(escaped, ", "))
    end
    out[n + 1] = "</table>\n<p>" .. #list .. " items</p>\n</body></html>\n"
    return table.concat(out)
end

local page = render(items)
local sum = 0
for i = 97, #page, 97 do sum = sum + string.byte(page, i) end
print(string.format("template %d %d", #page, sum % 1000000007))
