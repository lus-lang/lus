# JSON encode and decode round trip over generated records.
require "json"
require "set"

N = ARGV[0] ? ARGV[0].to_i : 1000000

$state = 42
def rand_n(n)
  $state = ($state * 48271) % 2147483647
  $state % n
end

records = []
(1..N).each do |i|
  name = "user#{rand_n(100000)}"
  age = rand_n(90)
  active = rand_n(2) == 1
  t1 = "t#{rand_n(50)}"
  t2 = "t#{rand_n(50)}"
  score = rand_n(1000000)
  records << { "id" => i, "name" => name, "age" => age, "active" => active, "tags" => [t1, t2], "score" => score }
end

text = JSON.generate(records)
back = JSON.parse(text)

active = 0
agesum = 0
scoresum = 0
seen = Set.new
back.each do |r|
  active += 1 if r["active"]
  agesum += r["age"]
  scoresum += r["score"]
  r["tags"].each { |tag| seen << tag }
end

puts "json #{active} #{agesum} #{scoresum % 1000000007} #{seen.size} #{text.bytesize}"
