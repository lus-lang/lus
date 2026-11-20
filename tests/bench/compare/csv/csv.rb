# csv: generate CSV text, parse it with the CSV library, and aggregate per region.
require "csv"

N = ARGV[0] ? ARGV[0].to_i : 2000000

$state = 42
def rand_n(n)
  $state = ($state * 48271) % 2147483647
  $state % n
end

REGIONS = %w[north south east west central coastal mountain island]
WORDS = %w[fragile gift urgent bulk sample]

def generate(n)
  out = +"id,region,product,quantity,price_cents,note\n"
  (1..n).each do |id|
    region = REGIONS[rand_n(8)]
    product = rand_n(200)
    quantity = rand_n(20) + 1
    price = rand_n(100000)
    k = rand_n(10)
    note = if k == 0
      '"big, ""rush"" order"'
    elsif k < 4
      ""
    else
      WORDS[rand_n(5)]
    end
    out << "#{id},#{region},p#{product},#{quantity},#{price},#{note}\n"
  end
  out
end

rows = CSV.parse(generate(N))
stats = REGIONS.to_h { |r| [r, [0, 0, 0, 0]] }
commas = 0
rows.drop(1).each do |r|
  st = stats[r[1]]
  q = r[3].to_i
  p = r[4].to_i
  st[0] += 1
  st[1] += q
  st[2] += q * p
  st[3] = p if p > st[3]
  commas += 1 if r[5]&.include?(",")
end
out = ["csv"]
REGIONS.each do |name|
  st = stats[name]
  out << "#{st[0]} #{st[1]} #{st[2] % 1000000007} #{st[3]}"
end
out << commas.to_s
puts out.join(" ")
