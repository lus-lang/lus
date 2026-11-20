<?php
// Access log parsing: generate Apache common log lines, then parse each
// line with one regular expression and aggregate.

ini_set("memory_limit", "-1");

$N = isset($argv[1]) ? (int)$argv[1] : 1000000;

$state = 42;
function rand_n(int $n): int
{
    global $state;
    $state = ($state * 48271) % 2147483647;
    return $state % $n;
}

const METHODS = ["GET", "POST", "PUT", "DELETE"];
const STATUSES = [200, 200, 200, 301, 404, 500];
// The first 8 paths are prefixes that take a numeric id.
const PATHS = [
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
];

$lines = [];
for ($i = 0; $i < $N; $i++) {
    $a = rand_n(256);
    $b = rand_n(256);
    $c = rand_n(256);
    $mm = rand_n(60);
    $ss = rand_n(60);
    $method = METHODS[rand_n(4)];
    $k = rand_n(40);
    $path = PATHS[$k];
    if ($k < 8) {
        $path .= rand_n(1000);
    }
    $status = STATUSES[rand_n(6)];
    $bytes = rand_n(50000);
    $lines[] = sprintf('10.%d.%d.%d - - [20/Nov/2026:10:%02d:%02d +0000] "%s /%s HTTP/1.1" %d %d',
        $a, $b, $c, $mm, $ss, $method, $path, $status, $bytes);
}
$text = implode("\n", $lines) . "\n";
unset($lines);

$pattern = '/^(\S+) - - \[[^\]]*\] "([A-Z]+) \/(\S*) HTTP\/1\.1" (\d+) (\d+)$/';

$statuses = [];
$ips = [];
$paths = [];
$total = 0;
foreach (explode("\n", $text) as $line) {
    if (!preg_match($pattern, $line, $m)) {
        continue;
    }
    [, $ip, , $path, $status, $bytes] = $m;
    $statuses[$status] = ($statuses[$status] ?? 0) + 1;
    $total += (int)$bytes;
    $ips[$ip] = true;
    $paths[$path] = ($paths[$path] ?? 0) + 1;
}

$ranked = [];
foreach ($paths as $path => $hits) {
    $ranked[] = [(string)$path, $hits];
}
usort($ranked, fn($x, $y) => $y[1] <=> $x[1] ?: strcmp($x[0], $y[0]));
$top = array_map(fn($e) => $e[1], array_slice($ranked, 0, 5));

printf("logs %d %d %d %d %d %s\n", $statuses["200"] ?? 0, $statuses["404"] ?? 0, $statuses["500"] ?? 0,
    $total, count($ips), implode(" ", $top));
