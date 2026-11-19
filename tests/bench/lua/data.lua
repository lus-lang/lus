local function sum(t)
    local s = 0
    for i = 1, #t do s = s + t[i] end
    return s
end
local function mean(t) return sum(t) / #t end
local function stdev(t)
    local m = mean(t)
    local q = 0
    for i = 1, #t do local d = t[i] - m q = q + d * d end
    return math.sqrt(q / #t)
end
local n = 1000000
local f, k = {}, {}
for i = 1, n do
    f[i] = i * 0.25
    k[i] = i % 1000
end
local s = 0
for _ = 1, 20 do
    s = s + sum(f) + mean(k) + stdev(f) + sum(k)
end
print(s)
