<?php
// HTTP server benchmark: answers GET / with a small JSON document. The
// built-in php -S server is meant for development, so this is a small
// HTTP/1.1 event loop on stream_socket_server and stream_select.
$port = (int)($argv[1] ?? 8080);
$server = stream_socket_server("tcp://127.0.0.1:$port", $errno, $errstr,
    STREAM_SERVER_BIND | STREAM_SERVER_LISTEN,
    stream_context_create(["socket" => ["backlog" => 1024]]));
if (!$server) {
    fwrite(STDERR, "$errstr\n");
    exit(1);
}
stream_set_blocking($server, false);

$clients = [];
$buffers = [];
$counter = 0;

function respond($sock, string $request): bool
{
    global $counter;
    $end = strpos($request, "\r\n");
    $parts = explode(" ", substr($request, 0, $end), 3);
    $close = stripos($request, "\r\nconnection: close") !== false;
    if ($parts[0] === "GET" && ($parts[1] ?? "") === "/") {
        $counter++;
        $body = json_encode(["message" => "hello", "n" => $counter]);
        $out = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . strlen($body) . "\r\n\r\n" . $body;
    } else {
        $out = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nnot found\n";
    }
    fwrite($sock, $out);
    return !$close;
}

while (true) {
    $read = $clients;
    $read[] = $server;
    $write = null;
    $except = null;
    if (stream_select($read, $write, $except, null) === false) {
        continue;
    }
    foreach ($read as $sock) {
        if ($sock === $server) {
            while ($c = @stream_socket_accept($server, 0)) {
                stream_set_blocking($c, false);
                $id = (int)$c;
                $clients[$id] = $c;
                $buffers[$id] = "";
            }
            continue;
        }
        $id = (int)$sock;
        $data = fread($sock, 65536);
        if ($data === "" || $data === false) {
            if (feof($sock)) {
                fclose($sock);
                unset($clients[$id], $buffers[$id]);
            }
            continue;
        }
        $buffers[$id] .= $data;
        $keep = true;
        while (($pos = strpos($buffers[$id], "\r\n\r\n")) !== false) {
            $head = substr($buffers[$id], 0, $pos);
            $length = 0;
            if (stripos($head, "\r\ncontent-length:") !== false
                && preg_match('/\r\ncontent-length:\s*(\d+)/i', $head, $m)) {
                $length = (int)$m[1];
            }
            if (strlen($buffers[$id]) < $pos + 4 + $length) {
                break;
            }
            $buffers[$id] = substr($buffers[$id], $pos + 4 + $length);
            if (!respond($sock, $head)) {
                $keep = false;
                break;
            }
        }
        if (!$keep) {
            fclose($sock);
            unset($clients[$id], $buffers[$id]);
        }
    }
}
