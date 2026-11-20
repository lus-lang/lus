<?php
// template: render an HTML report for generated items with escaping,
// built with an array and implode.

$N = isset($argv[1]) ? (int)$argv[1] : 1000000;

$state = 42;
function rand_n(int $n): int {
    global $state;
    $state = ($state * 48271) % 2147483647;
    return $state % $n;
}

const TAGS = ["new", "sale", "<hot>", "a&b", '"quoted"', "it's", "x>y", "plain"];
const ESC = ["&" => "&amp;", "<" => "&lt;", ">" => "&gt;", '"' => "&quot;", "'" => "&#39;"];

function escape(string $s): string {
    return strtr($s, ESC);
}

$items = [];
for ($id = 1; $id <= $N; $id++) {
    $title = "Item $id & " . rand_n(1000) . " " . TAGS[rand_n(8)];
    $price = rand_n(100000);
    $tags = [];
    $count = rand_n(3) + 1;
    for ($j = 0; $j < $count; $j++) $tags[] = TAGS[rand_n(8)];
    $items[] = ["id" => $id, "title" => $title, "price" => $price, "tags" => $tags];
}

function render(array $items): string {
    $out = [
        "<!DOCTYPE html>\n<html><head><title>Report</title></head><body>\n",
        "<h1>Items &amp; prices</h1>\n<table>\n",
        "<tr><th>ID</th><th>Title</th><th>Price</th><th>Tags</th></tr>\n",
    ];
    foreach ($items as $item) {
        $price = $item["price"];
        $tags = implode(", ", array_map("escape", $item["tags"]));
        $out[] = sprintf("<tr><td>%d</td><td>%s</td><td>\$%d.%02d</td><td>%s</td></tr>\n",
            $item["id"], escape($item["title"]), intdiv($price, 100), $price % 100, $tags);
    }
    $out[] = "</table>\n<p>" . count($items) . " items</p>\n</body></html>\n";
    return implode("", $out);
}

$page = render($items);
$len = strlen($page);
$sum = 0;
for ($i = 96; $i < $len; $i += 97) $sum += ord($page[$i]);
echo "template $len " . ($sum % 1000000007) . "\n";
