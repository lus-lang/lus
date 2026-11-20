// HTTP server benchmark: answers GET / with a small JSON document.
// Node runs it on the http module and Bun runs it on Bun.serve.
const port = Number(process.argv[2] || 8080);
let n = 0;

if (typeof Bun !== "undefined") {
    Bun.serve({
        hostname: "127.0.0.1",
        port,
        fetch(req) {
            if (req.method === "GET" && new URL(req.url).pathname === "/") {
                n++;
                return new Response(JSON.stringify({ message: "hello", n }), {
                    headers: { "Content-Type": "application/json" },
                });
            }
            return new Response("not found\n", { status: 404 });
        },
    });
} else {
    const http = require("http");
    const server = http.createServer((req, res) => {
        if (req.method === "GET" && req.url === "/") {
            n++;
            const body = JSON.stringify({ message: "hello", n });
            res.writeHead(200, {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(body),
            });
            res.end(body);
        } else {
            res.writeHead(404, { "Content-Type": "text/plain", "Content-Length": 10 });
            res.end("not found\n");
        }
    });
    server.keepAliveTimeout = 60000;
    server.listen(port, "127.0.0.1");
}
