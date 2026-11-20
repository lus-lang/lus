<?php
// JSON encode and decode round trip over generated records.

ini_set("memory_limit", "-1");

$N = isset($argv[1]) ? (int)$argv[1] : 1000000;

$state = 42;
function rand_n(int $n): int
{
    global $state;
    $state = ($state * 48271) % 2147483647;
    return $state % $n;
}

$records = [];
for ($i = 1; $i <= $N; $i++) {
    $name = "user" . rand_n(100000);
    $age = rand_n(90);
    $active = rand_n(2) === 1;
    $t1 = "t" . rand_n(50);
    $t2 = "t" . rand_n(50);
    $score = rand_n(1000000);
    $records[] = ["id" => $i, "name" => $name, "age" => $age, "active" => $active, "tags" => [$t1, $t2], "score" => $score];
}

$text = json_encode($records);
$back = json_decode($text, true);

$active = 0;
$agesum = 0;
$scoresum = 0;
$seen = [];
foreach ($back as $r) {
    if ($r["active"]) {
        $active++;
    }
    $agesum += $r["age"];
    $scoresum += $r["score"];
    foreach ($r["tags"] as $tag) {
        $seen[$tag] = true;
    }
}

printf("json %d %d %d %d %d\n", $active, $agesum, $scoresum % 1000000007, count($seen), strlen($text));
