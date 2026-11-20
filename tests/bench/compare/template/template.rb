# template: render an HTML report for generated items with escaping,
# built in a mutable String buffer.
require "cgi/escape"

N = ARGV[0] ? ARGV[0].to_i : 1000000

$state = 42
def rand_n(n)
  $state = ($state * 48271) % 2147483647
  $state % n
end

TAGS = ["new", "sale", "<hot>", "a&b", '"quoted"', "it's", "x>y", "plain"].freeze

Item = Struct.new(:id, :title, :price, :tags)

items = (1..N).map do |id|
  title = "Item #{id} & #{rand_n(1000)} #{TAGS[rand_n(8)]}"
  price = rand_n(100000)
  tags = Array.new(rand_n(3) + 1) { TAGS[rand_n(8)] }
  Item.new(id, title, price, tags)
end

def render(items)
  out = +"<!DOCTYPE html>\n<html><head><title>Report</title></head><body>\n"
  out << "<h1>Items &amp; prices</h1>\n<table>\n"
  out << "<tr><th>ID</th><th>Title</th><th>Price</th><th>Tags</th></tr>\n"
  items.each do |item|
    dollars, cents = item.price.divmod(100)
    tags = item.tags.map { |t| CGI.escapeHTML(t) }.join(", ")
    out << "<tr><td>#{item.id}</td><td>#{CGI.escapeHTML(item.title)}</td>" \
           "<td>$#{dollars}.#{format("%02d", cents)}</td><td>#{tags}</td></tr>\n"
  end
  out << "</table>\n<p>#{items.size} items</p>\n</body></html>\n"
  out
end

page = render(items)
sum = 0
i = 96
while i < page.bytesize
  sum += page.getbyte(i)
  i += 97
end
puts "template #{page.bytesize} #{sum % 1000000007}"
