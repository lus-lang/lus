<?php
// wordfreq: count word frequencies in a generated text.
ini_set("memory_limit", "-1");
$n = isset($argv[1]) ? (int)$argv[1] : 10000000;

$state = 42;
function rand_int(int $m): int {
    global $state;
    $state = ($state * 48271) % 2147483647;
    return $state % $m;
}

$letters = "abcdefghijklmnopqrstuvwxyz";
$vocab = [];
for ($k = 0; $k < 5000; $k++) {
    $len = 3 + rand_int(7);
    $word = "";
    for ($j = 0; $j < $len; $j++) {
        $ch = $letters[rand_int(26)];
        if (rand_int(5) === 0) $ch = strtoupper($ch);
        $word .= $ch;
    }
    $vocab[] = $word;
}

$punct = [",", ".", "!"];
$text = "";
for ($i = 1; $i <= $n; $i++) {
    $text .= $vocab[rand_int(rand_int(5000) + 1)];
    if (rand_int(12) === 0) $text .= $punct[rand_int(3)];
    $text .= ($i % 12 === 0) ? "\n" : " ";
}

preg_match_all('/[A-Za-z]+/', $text, $m);
$counts = [];
$total = 0;
foreach ($m[0] as $w) {
    $w = strtolower($w);
    $counts[$w] = ($counts[$w] ?? 0) + 1;
    $total++;
}
unset($m);

uksort($counts, function ($a, $b) use ($counts) {
    return $counts[$b] <=> $counts[$a] ?: strcmp($a, $b);
});

$out = ["wordfreq", count($counts), $total];
$top = array_slice($counts, 0, 10, true);
foreach ($top as $c) $out[] = $c;
foreach (array_slice(array_keys($top), 0, 3) as $w) $out[] = $w;
echo implode(" ", $out), "\n";
