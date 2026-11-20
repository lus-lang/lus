<?php
// csv: generate CSV text, parse it with fgetcsv on a memory stream,
// and aggregate per region.

$N = isset($argv[1]) ? (int)$argv[1] : 2000000;

// Holding every parsed row needs more than the default 128 MB.
ini_set("memory_limit", "2G");

$state = 42;
function rand_n(int $n): int {
    global $state;
    $state = ($state * 48271) % 2147483647;
    return $state % $n;
}

const REGIONS = ["north", "south", "east", "west", "central", "coastal", "mountain", "island"];
const WORDS = ["fragile", "gift", "urgent", "bulk", "sample"];

function generate(int $n): string {
    $parts = ["id,region,product,quantity,price_cents,note\n"];
    for ($id = 1; $id <= $n; $id++) {
        $region = REGIONS[rand_n(8)];
        $product = rand_n(200);
        $quantity = rand_n(20) + 1;
        $price = rand_n(100000);
        $k = rand_n(10);
        if ($k === 0) {
            $note = '"big, ""rush"" order"';
        } elseif ($k < 4) {
            $note = "";
        } else {
            $note = WORDS[rand_n(5)];
        }
        $parts[] = "$id,$region,p$product,$quantity,$price,$note\n";
    }
    return implode("", $parts);
}

$fh = fopen("php://memory", "r+");
fwrite($fh, generate($N));
rewind($fh);
$rows = [];
while (($row = fgetcsv($fh, null, ",", "\"", "")) !== false) {
    $rows[] = $row;
}
fclose($fh);

$stats = [];
foreach (REGIONS as $r) $stats[$r] = [0, 0, 0, 0];
$commas = 0;
$count = count($rows);
for ($i = 1; $i < $count; $i++) {
    $r = $rows[$i];
    $st = &$stats[$r[1]];
    $q = (int)$r[3];
    $p = (int)$r[4];
    $st[0] += 1;
    $st[1] += $q;
    $st[2] += $q * $p;
    if ($p > $st[3]) $st[3] = $p;
    if (str_contains($r[5], ",")) $commas++;
    unset($st);
}
$out = ["csv"];
foreach (REGIONS as $name) {
    $st = $stats[$name];
    $out[] = $st[0] . " " . $st[1] . " " . ($st[2] % 1000000007) . " " . $st[3];
}
$out[] = (string)$commas;
echo implode(" ", $out), "\n";
