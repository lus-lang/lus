#!/usr/bin/env node
// Posts a release or a news post to X. Run from a GitHub Action:
//
//   node tools/post-x.js release "$GITHUB_EVENT_PATH"
//   node tools/post-x.js news packages/site/src/news/NAME.md ...
//
// The post text comes from the release body or the news frontmatter. An
// HTML comment <!-- x: TEXT --> in a release body, or an `x:` field in news
// frontmatter, replaces the generated text. The four credentials of an
// OAuth 1.0a user context come from X_API_KEY, X_API_SECRET,
// X_ACCESS_TOKEN, and X_ACCESS_SECRET. When any of them is missing, or
// with --dry-run, the script prints the post and sends nothing.
//
// The script uses no packages, so nothing but Node itself runs next to
// the credentials.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ENDPOINT = "https://api.x.com/2/tweets";
const SITE = "https://lus.dev";
const LIMIT = 280;
const URL_WEIGHT = 23;

// twitter-text v3: code points in these ranges weigh 1, all others 2
const LIGHT_RANGES = [
  [0x0000, 0x10ff],
  [0x2000, 0x200d],
  [0x2010, 0x201f],
  [0x2032, 0x2037],
];
const URL_PATTERN = /https?:\/\/[^\s]+/g;

function weightedLength(text) {
  let total = 0;
  const rest = text.normalize("NFC").replace(URL_PATTERN, () => {
    total += URL_WEIGHT;
    return "";
  });
  for (const ch of rest) {
    const cp = ch.codePointAt(0);
    total += LIGHT_RANGES.some(([lo, hi]) => cp >= lo && cp <= hi) ? 1 : 2;
  }
  return total;
}

// RFC 3986 encoding, which OAuth 1.0a requires
function percent(value) {
  return encodeURIComponent(value).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}

// The Authorization header for a request. A JSON body is not form encoded,
// so only the OAuth parameters and any query or form parameters in `extra`
// enter the signature.
function authorization(method, url, creds, nonce, timestamp, extra = {}) {
  const params = {
    ...extra,
    oauth_consumer_key: creds.apiKey,
    oauth_nonce: nonce,
    oauth_signature_method: "HMAC-SHA1",
    oauth_timestamp: String(timestamp),
    oauth_token: creds.accessToken,
    oauth_version: "1.0",
  };
  const paramString = Object.keys(params)
    .sort()
    .map((k) => `${percent(k)}=${percent(params[k])}`)
    .join("&");
  const base = [method.toUpperCase(), percent(url), percent(paramString)].join("&");
  const key = `${percent(creds.apiSecret)}&${percent(creds.accessSecret)}`;
  const header = Object.fromEntries(Object.entries(params).filter(([k]) => k.startsWith("oauth_")));
  header.oauth_signature = crypto.createHmac("sha1", key).update(base).digest("base64");
  return "OAuth " + Object.keys(header)
    .sort()
    .map((k) => `${percent(k)}="${percent(header[k])}"`)
    .join(", ");
}

// The first paragraph of Markdown as plain text
function firstParagraph(markdown) {
  const para = markdown
    .replace(/<!--[\s\S]*?-->/g, "")
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .find((p) => p && !p.startsWith("#") && !p.startsWith("|") && !p.startsWith("```"));
  if (!para) return "";
  return para
    .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/[*_`]/g, "")
    .replace(/^[-*]\s+/gm, "")
    .replace(/\s+/g, " ")
    .trim();
}

// Shortens text to fit the budget at a sentence or word boundary
function fit(text, budget) {
  if (weightedLength(text) <= budget) return text;
  const sentences = text.match(/[^.!?]+[.!?]+(\s|$)/g) || [];
  let out = "";
  for (const s of sentences) {
    if (weightedLength(out + s) > budget) break;
    out += s;
  }
  if (out.trim()) return out.trim();
  const words = text.split(" ");
  out = "";
  for (const w of words) {
    if (weightedLength(out + w + " ...") > budget) break;
    out += w + " ";
  }
  return out.trim() + " ...";
}

function compose(head, body, url) {
  const fixed = `${head}\n\n\n\n${url}`;
  const room = LIMIT - weightedLength(fixed);
  const middle = body ? fit(body, room) : "";
  return middle ? `${head}\n\n${middle}\n\n${url}` : `${head}\n\n${url}`;
}

function override(text) {
  const m = /<!--\s*x:\s*([\s\S]*?)-->/.exec(text || "");
  return m ? m[1].trim() : null;
}

// A post for a published release, or null for a prerelease
function releasePost(event) {
  const release = event.release;
  if (!release || release.prerelease || release.draft) return null;
  const version = release.tag_name.replace(/^v/, "");
  const custom = override(release.body);
  if (custom) return custom;
  return compose(`Lus ${version} is out.`, firstParagraph(release.body || ""), release.html_url);
}

function frontmatter(source) {
  const m = /^---\n([\s\S]*?)\n---\n?([\s\S]*)$/.exec(source);
  if (!m) return {data: {}, body: source};
  const data = {};
  for (const line of m[1].split("\n")) {
    const kv = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line);
    if (kv) data[kv[1]] = kv[2].replace(/^["']|["']$/g, "");
  }
  return {data, body: m[2]};
}

// A post for a news page, or null for a changelog, which the release covers
function newsPost(file, source) {
  const id = path.basename(file).replace(/\.mdx?$/, "");
  if (id.startsWith("changelog-")) return null;
  const {data, body} = frontmatter(source);
  const url = `${SITE}/news/${id}`;
  if (data.x) return `${data.x}\n\n${url}`;
  return compose(data.title || id, firstParagraph(body), url);
}

function credentials(env) {
  const creds = {
    apiKey: env.X_API_KEY,
    apiSecret: env.X_API_SECRET,
    accessToken: env.X_ACCESS_TOKEN,
    accessSecret: env.X_ACCESS_SECRET,
  };
  return Object.values(creds).every(Boolean) ? creds : null;
}

async function send(text, creds) {
  const nonce = crypto.randomBytes(16).toString("hex");
  const timestamp = Math.floor(Date.now() / 1000);
  const response = await fetch(ENDPOINT, {
    method: "POST",
    headers: {
      Authorization: authorization("POST", ENDPOINT, creds, nonce, timestamp),
      "Content-Type": "application/json",
    },
    body: JSON.stringify({text}),
  });
  const reply = await response.text();
  if (!response.ok) throw new Error(`X API ${response.status}: ${reply}`);
  return JSON.parse(reply).data;
}

async function main(argv, env) {
  const dryFlag = argv.includes("--dry-run");
  const [kind, ...files] = argv.filter((a) => a !== "--dry-run");
  let posts;
  if (kind === "release") {
    posts = [releasePost(JSON.parse(fs.readFileSync(files[0], "utf8")))];
  } else if (kind === "news") {
    posts = files.map((f) => newsPost(f, fs.readFileSync(f, "utf8")));
  } else {
    console.error("usage: post-x.js release EVENT.json | news FILE.md ... [--dry-run]");
    process.exit(2);
  }
  const creds = credentials(env);
  for (const text of posts.filter(Boolean)) {
    const weight = weightedLength(text);
    if (weight > LIMIT) throw new Error(`post weighs ${weight}, over ${LIMIT}:\n${text}`);
    if (dryFlag || !creds) {
      console.log(`dry run (${weight}/${LIMIT}):\n${text}\n`);
      continue;
    }
    const data = await send(text, creds);
    console.log(`posted ${data.id}`);
  }
}

module.exports = {weightedLength, percent, authorization, firstParagraph, fit, releasePost, newsPost, frontmatter};

if (require.main === module) {
  main(process.argv.slice(2), process.env).catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
}
