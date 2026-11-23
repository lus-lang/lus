// Line protocol load for tests/bench/coio/echo.lus: C connections, each
// keeping DEPTH lines in flight, count the echoed lines for a few seconds.
// Usage: bun load.mjs PORT [conns] [depth] [seconds]
import net from "node:net";
const [port, conns = 64, depth = 1, secs = 5] = process.argv.slice(2).map(Number);
const line = "GET /some/resource/of/typical/length HTTP/1.1 0123456789\n";
const batch = line.repeat(depth);
let total = 0, lat = [], stop = false;
function client() {
  return new Promise((res) => {
    const s = net.connect(port, "127.0.0.1");
    s.setNoDelay(true);
    let pending = "", got = 0, t0 = 0;
    const send = () => { t0 = performance.now(); s.write(batch); };
    s.on("connect", send);
    s.on("data", (d) => {
      pending += d;
      let nl;
      while ((nl = pending.indexOf("\n")) >= 0) { pending = pending.slice(nl + 1); got++; }
      if (got >= depth) {
        got -= depth; total += depth;
        if (lat.length < 2e6) lat.push(performance.now() - t0);
        if (stop) { s.end(); return res(); }
        send();
      }
    });
    s.on("error", () => res());
    s.on("close", () => res());
  });
}
const start = performance.now();
const ps = [];
for (let i = 0; i < conns; i++) ps.push(client());
setTimeout(() => { stop = true; }, secs * 1000);
await Promise.all(ps);
const el = (performance.now() - start) / 1000;
lat.sort((a, b) => a - b);
const q = (p) => lat[Math.floor(lat.length * p)]?.toFixed(3);
console.log(JSON.stringify({ lines_per_s: Math.round(total / el), p50_ms: q(0.5), p99_ms: q(0.99) }));
