# wordfreq: count word frequencies in a generated text.
n = ARGV[0] ? ARGV[0].to_i : 10000000

$state = 42
def rand_int(m)
  $state = ($state * 48271) % 2147483647
  $state % m
end

letters = ("a".."z").to_a
vocab = Array.new(5000) do
  len = 3 + rand_int(7)
  word = +""
  len.times do
    ch = letters[rand_int(26)]
    ch = ch.upcase if rand_int(5) == 0
    word << ch
  end
  word
end

punct = [",", ".", "!"]
text = String.new(capacity: n * 8)
(1..n).each do |i|
  text << vocab[rand_int(rand_int(5000) + 1)]
  text << punct[rand_int(3)] if rand_int(12) == 0
  text << (i % 12 == 0 ? "\n" : " ")
end

counts = Hash.new(0)
total = 0
text.scan(/[A-Za-z]+/) do |w|
  counts[w.downcase] += 1
  total += 1
end

ranked = counts.sort_by { |w, c| [-c, w] }

out = ["wordfreq", ranked.size, total]
out.concat(ranked.first(10).map { |_, c| c })
out.concat(ranked.first(3).map { |w, _| w })
puts out.join(" ")
