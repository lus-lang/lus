// The server of http_serve.lus on the http module of Node, for the
// comparison that tests/bench/README.md describes.
//
//     node tests/bench/http_serve.js 8081
//     oha -z 10s -c 64 --no-tui http://127.0.0.1:8081/

const http = require("node:http");

const port = Number(process.argv[2] || 8081);
const body = "Hello, World!\n";

http
  .createServer((req, res) => {
    res.writeHead(200, {
      "Content-Type": "text/plain",
      "Content-Length": Buffer.byteLength(body),
    });
    res.end(body);
  })
  .listen(port, "127.0.0.1");
