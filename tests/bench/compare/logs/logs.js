// Access log parsing: generate Apache common log lines, then parse each
// line with one regular expression and aggregate.
"use strict";

const N = process.argv.length > 2 ? parseInt(process.argv[2], 10) : 1000000;

let state = 42;
function rand(n) {
    state = (state * 48271) % 2147483647;
    return state % n;
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

const LINE = /^(\S+) - - \[[^\]]*\] "([A-Z]+) \/(\S*) HTTP\/1\.1" (\d+) (\d+)$/;

function pad2(n) {
    return n < 10 ? "0" + n : "" + n;
}

function main() {
    const lines = [];
    for (let i = 0; i < N; i++) {
        const a = rand(256), b = rand(256), c = rand(256);
        const mm = rand(60), ss = rand(60);
        const method = METHODS[rand(4)];
        const k = rand(40);
        let path = PATHS[k];
        if (k < 8) path += rand(1000);
        const status = STATUSES[rand(6)];
        const bytes = rand(50000);
        lines.push(`10.${a}.${b}.${c} - - [20/Nov/2026:10:${pad2(mm)}:${pad2(ss)} +0000] "${method} /${path} HTTP/1.1" ${status} ${bytes}`);
    }
    const text = lines.join("\n") + "\n";

    const statuses = new Map();
    const ips = new Set();
    const paths = new Map();
    let total = 0;
    for (const line of text.split("\n")) {
        const m = LINE.exec(line);
        if (m === null) continue;
        const [, ip, , path, status, bytes] = m;
        statuses.set(status, (statuses.get(status) || 0) + 1);
        total += parseInt(bytes, 10);
        ips.add(ip);
        paths.set(path, (paths.get(path) || 0) + 1);
    }

    const top = [...paths.entries()]
        .sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0))
        .slice(0, 5)
        .map((e) => e[1]);
    const count = (s) => statuses.get(s) || 0;
    console.log(`logs ${count("200")} ${count("404")} ${count("500")} ${total} ${ips.size} ${top.join(" ")}`);
}

main();
