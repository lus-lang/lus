local parts = {}
for i = 1, 1000000 do parts[#parts + 1] = "item " .. i end
local s = table.concat(parts, ",")
local n = 0
for w in s:gmatch("[^,]+") do n = n + 1 end
print(#s, n)
