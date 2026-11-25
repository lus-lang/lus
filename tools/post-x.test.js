#!/usr/bin/env node

const assert = require("assert/strict");

const {weightedLength, percent, authorization, firstParagraph, releasePost, newsPost} = require("./post-x.js");

// URLs weigh 23 whatever their length, and wide characters weigh 2.
assert.equal(weightedLength("abc"), 3);
assert.equal(weightedLength("see https://lus.dev/news/a-very-long-slug-indeed"), 4 + 23);
assert.equal(weightedLength("中"), 2);
assert.equal(weightedLength("\u{1F600}"), 2);

assert.equal(percent("a b!*'()"), "a%20b%21%2A%27%28%29");

// The signature matches the worked example in the X documentation page
// "Creating a signature".
{
  const header = authorization(
    "POST",
    "https://api.twitter.com/1.1/statuses/update.json",
    {
      apiKey: "xvz1evFS4wEEPTGEFPHBog",
      apiSecret: "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw",
      accessToken: "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb",
      accessSecret: "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE",
    },
    "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg",
    1318622958,
    {status: "Hello Ladies + Gentlemen, a signed OAuth request!", include_entities: "true"},
  );
  assert.match(header, /oauth_signature="hCtSmYh%2BiHYCEqBWrE7C7hYmtUk%3D"/);
  assert.doesNotMatch(header, /status=/);
  assert.match(header, /^OAuth oauth_consumer_key="xvz1evFS4wEEPTGEFPHBog", oauth_nonce="[^"]+", oauth_signature="[^"]+", oauth_signature_method="HMAC-SHA1", oauth_timestamp="1318622958", oauth_token="[^"]+", oauth_version="1.0"$/);
}

// The first paragraph skips headings and strips Markdown.
assert.equal(firstParagraph("## Highlights\n\nA **fast** [JIT](https://x) and `catch`.\n\nMore."), "A fast JIT and catch.");

// Prereleases and drafts produce no post.
assert.equal(releasePost({release: {tag_name: "v2.0.0-unstable.3", prerelease: true}}), null);

{
  const post = releasePost({release: {tag_name: "v2.0.0", prerelease: false, draft: false, html_url: "https://github.com/lus-lang/lus/releases/tag/v2.0.0", body: "Lus 2.0 rewrites the runtime in Zig. It adds a JIT.\n\n## Changes\n\n- many"}});
  assert.equal(post, "Lus 2.0.0 is out.\n\nLus 2.0 rewrites the runtime in Zig. It adds a JIT.\n\nhttps://github.com/lus-lang/lus/releases/tag/v2.0.0");
}

// A comment in the release body replaces the generated text.
assert.equal(releasePost({release: {tag_name: "v2.0.1", html_url: "u", body: "<!-- x: Lus 2.0.1 fixes two bugs. https://lus.dev -->\nBody"}}), "Lus 2.0.1 fixes two bugs. https://lus.dev");

// A long body is cut at a sentence boundary to fit 280.
{
  const long = Array.from({length: 40}, (_, i) => `Sentence number ${i} is here.`).join(" ");
  const post = releasePost({release: {tag_name: "v2.0.0", html_url: "https://example.com/r", body: long}});
  assert.ok(weightedLength(post) <= 280);
  assert.match(post, /here\.\n\nhttps:\/\/example\.com\/r$/);
}

// News posts link to lus.dev, and changelogs are left to the release.
assert.equal(newsPost("src/news/changelog-2.0.0.md", "---\ntitle: x\n---\n"), null);
assert.equal(newsPost("src/news/microlua.md", "---\ntitle: How tiny can Lua get?\ndate: 2026-07-03\n---\n\nLua is tiny.\n"), "How tiny can Lua get?\n\nLua is tiny.\n\nhttps://lus.dev/news/microlua");
assert.equal(newsPost("src/news/a.md", "---\ntitle: T\nx: \"Custom text\"\n---\nBody"), "Custom text\n\nhttps://lus.dev/news/a");

console.log("post-x tests passed");
