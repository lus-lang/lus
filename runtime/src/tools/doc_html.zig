//! The HTML output of `lus doc --format html -o DIR`.
//!
//! Each module becomes `DIR/MODULE.html`, with one section per entry whose
//! anchor is the name of the entry. `DIR/index.html` lists the modules,
//! and `DIR/search.js` holds the search index as a script, so the search
//! box of every page also works on pages opened from disk. Descriptions are
//! Markdown, of which the renderer knows paragraphs, headings, bullet
//! lists, fenced code blocks, inline code, emphasis, and links.
//!
//! An intra-doc link is a reference to an entry in brackets, as in rustdoc:
//! `` [`trim`] `` or `[strings.trim]` links to the section of that entry
//! in whichever module defines it, and `[label](strings.trim)` links with
//! another label. A name that no module defines stays plain text.

const std = @import("std");
const doc = @import("doc.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Where an entry lives: its page and its anchor.
const Target = struct { page: []const u8, anchor: []const u8 };

/// The names an intra-doc link may use for each entry: `name` and
/// `module.name`. A short name that two modules define links to the
/// first, in the order of the files.
pub const Links = struct {
    map: std.StringHashMapUnmanaged(Target) = .empty,

    pub fn init(arena: Allocator, modules: []const doc.Module) !Links {
        var l: Links = .{};
        for (modules) |m| {
            const page = try std.fmt.allocPrint(arena, "{s}.html", .{m.name});
            try l.map.put(arena, m.name, .{ .page = page, .anchor = "" });
            for (m.entries) |e| {
                const t: Target = .{ .page = page, .anchor = e.name };
                const full = if (std.mem.startsWith(u8, e.name, m.name) and e.name.len > m.name.len and (e.name[m.name.len] == '.' or e.name[m.name.len] == ':'))
                    e.name
                else
                    try std.fmt.allocPrint(arena, "{s}.{s}", .{ m.name, e.name });
                try l.map.put(arena, full, t);
                const short = if (std.mem.lastIndexOfAny(u8, e.name, ".:")) |dot| e.name[dot + 1 ..] else e.name;
                if (!l.map.contains(short)) try l.map.put(arena, short, t);
                if (!l.map.contains(e.name)) try l.map.put(arena, e.name, t);
            }
        }
        return l;
    }

    fn find(l: *const Links, name: []const u8) ?Target {
        const trimmed = std.mem.trimEnd(u8, name, "()");
        return l.map.get(trimmed);
    }
};

fn esc(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

fn href(w: *Writer, t: Target) Writer.Error!void {
    try esc(w, t.page);
    if (t.anchor.len > 0) {
        try w.writeByte('#');
        try esc(w, t.anchor);
    }
}

/// Renders the inline Markdown of one line or paragraph.
fn inline_(w: *Writer, links: *const Links, s: []const u8) Writer.Error!void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '`') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse {
                try esc(w, s[i..]);
                return;
            };
            try w.writeAll("<code>");
            try esc(w, s[i + 1 .. end]);
            try w.writeAll("</code>");
            i = end + 1;
        } else if (c == '[') {
            if (link(w, links, s, &i)) |done| {
                if (done) continue;
            } else |e| return e;
            try w.writeByte('[');
            i += 1;
        } else if (c == '*' and i + 1 < s.len and s[i + 1] == '*') {
            const end = std.mem.indexOfPos(u8, s, i + 2, "**") orelse {
                try w.writeAll("**");
                i += 2;
                continue;
            };
            try w.writeAll("<strong>");
            try inline_(w, links, s[i + 2 .. end]);
            try w.writeAll("</strong>");
            i = end + 2;
        } else if ((c == '*' or c == '_') and i + 1 < s.len and s[i + 1] != ' ' and (i == 0 or !std.ascii.isAlphanumeric(s[i - 1]))) {
            const end = std.mem.indexOfScalarPos(u8, s, i + 1, c) orelse {
                try w.writeByte(c);
                i += 1;
                continue;
            };
            try w.writeAll("<em>");
            try inline_(w, links, s[i + 1 .. end]);
            try w.writeAll("</em>");
            i = end + 1;
        } else {
            try esc(w, s[i .. i + 1]);
            i += 1;
        }
    }
}

/// Renders a link that starts at `s[i.*]`, a `[`, and moves `i` past it.
/// Returns false, leaving `i`, when the brackets hold no link.
fn link(w: *Writer, links: *const Links, s: []const u8, i: *usize) Writer.Error!bool {
    const close = std.mem.indexOfScalarPos(u8, s, i.* + 1, ']') orelse return false;
    const label = s[i.* + 1 .. close];
    if (close + 1 < s.len and s[close + 1] == '(') {
        const end = std.mem.indexOfScalarPos(u8, s, close + 2, ')') orelse return false;
        const dest = s[close + 2 .. end];
        try w.writeAll("<a href=\"");
        if (links.find(dest)) |t| try href(w, t) else try esc(w, dest);
        try w.writeAll("\">");
        try inline_(w, links, label);
        try w.writeAll("</a>");
        i.* = end + 1;
        return true;
    }
    const name = std.mem.trim(u8, label, "`");
    const t = links.find(name) orelse return false;
    try w.writeAll("<a href=\"");
    try href(w, t);
    try w.writeAll("\">");
    try inline_(w, links, label);
    try w.writeAll("</a>");
    i.* = close + 1;
    return true;
}

/// Renders a Markdown description as HTML blocks.
pub fn markdown(w: *Writer, arena: Allocator, links: *const Links, text: []const u8) Writer.Error!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var list_open = false;
    var paragraph: std.Io.Writer.Allocating = .init(arena);
    defer paragraph.deinit();
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            try flush(w, links, &paragraph, &list_open);
            const lang = std.mem.trim(u8, trimmed[3..], " \t");
            try w.writeAll("<pre><code");
            if (lang.len > 0) {
                try w.writeAll(" class=\"language-");
                try esc(w, std.mem.sliceTo(lang, ' '));
                try w.writeAll("\"");
            }
            try w.writeAll(">");
            var first = true;
            while (it.next()) |code| {
                if (std.mem.startsWith(u8, std.mem.trimStart(u8, code, " \t"), "```")) break;
                if (!first) try w.writeByte('\n');
                first = false;
                try esc(w, code);
            }
            try w.writeAll("</code></pre>\n");
            continue;
        }
        if (trimmed.len == 0) {
            try flush(w, links, &paragraph, &list_open);
            continue;
        }
        if (trimmed[0] == '#') {
            try flush(w, links, &paragraph, &list_open);
            var level: usize = 0;
            while (level < trimmed.len and trimmed[level] == '#') level += 1;
            const h = @min(level + 2, 6);
            try w.print("<h{d}>", .{h});
            try inline_(w, links, std.mem.trim(u8, trimmed[level..], " "));
            try w.print("</h{d}>\n", .{h});
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            if (paragraph.written().len > 0 and !list_open) try flush(w, links, &paragraph, &list_open);
            if (!list_open) {
                try w.writeAll("<ul>\n");
                list_open = true;
            } else try flushItem(w, links, &paragraph);
            paragraph.writer.writeAll(trimmed[2..]) catch return error.WriteFailed;
            continue;
        }
        if (paragraph.written().len > 0) paragraph.writer.writeByte(' ') catch return error.WriteFailed;
        paragraph.writer.writeAll(trimmed) catch return error.WriteFailed;
    }
    try flush(w, links, &paragraph, &list_open);
}

fn flushItem(w: *Writer, links: *const Links, paragraph: *std.Io.Writer.Allocating) Writer.Error!void {
    if (paragraph.written().len == 0) return;
    try w.writeAll("<li>");
    try inline_(w, links, paragraph.written());
    try w.writeAll("</li>\n");
    paragraph.clearRetainingCapacity();
}

fn flush(w: *Writer, links: *const Links, paragraph: *std.Io.Writer.Allocating, list_open: *bool) Writer.Error!void {
    if (list_open.*) {
        try flushItem(w, links, paragraph);
        try w.writeAll("</ul>\n");
        list_open.* = false;
        return;
    }
    if (paragraph.written().len == 0) return;
    try w.writeAll("<p>");
    try inline_(w, links, paragraph.written());
    try w.writeAll("</p>\n");
    paragraph.clearRetainingCapacity();
}

const style =
    \\:root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --muted: #666; --line: #ddd; --code: #f4f4f5; --link: #0b57d0; }
    \\@media (prefers-color-scheme: dark) { :root { --fg: #e8e8ea; --bg: #141416; --muted: #9a9aa0; --line: #333; --code: #1f1f23; --link: #8ab4f8; } }
    \\body { margin: 0; font: 16px/1.55 system-ui, sans-serif; color: var(--fg); background: var(--bg); }
    \\header { display: flex; gap: 1rem; align-items: center; padding: .75rem 1.5rem; border-bottom: 1px solid var(--line); }
    \\header a { color: inherit; text-decoration: none; font-weight: 600; }
    \\#search { flex: 1; max-width: 28rem; padding: .35rem .6rem; font: inherit; border: 1px solid var(--line); background: var(--bg); color: inherit; }
    \\#results { position: absolute; top: 3rem; left: 1.5rem; right: 1.5rem; max-width: 40rem; background: var(--bg); border: 1px solid var(--line); list-style: none; margin: 0; padding: .25rem 0; }
    \\#results:empty { display: none; }
    \\#results li { padding: .2rem .8rem; }
    \\main { max-width: 52rem; margin: 0 auto; padding: 1.5rem; }
    \\a { color: var(--link); }
    \\code, pre { font: 14px/1.5 ui-monospace, monospace; background: var(--code); }
    \\code { padding: .05rem .25rem; }
    \\pre { padding: .75rem 1rem; overflow-x: auto; }
    \\pre code { padding: 0; }
    \\section { border-top: 1px solid var(--line); margin-top: 2rem; padding-top: 1rem; }
    \\h2 code { font-size: 1.1em; background: none; }
    \\.meta, .summary { color: var(--muted); }
    \\
;

const script =
    \\(function () {
    \\  var input = document.getElementById("search"), list = document.getElementById("results");
    \\  if (!input || !window.LUS_DOC_INDEX) return;
    \\  input.addEventListener("input", function () {
    \\    var q = input.value.trim().toLowerCase(); list.textContent = "";
    \\    if (!q) return;
    \\    var hits = window.LUS_DOC_INDEX.filter(function (e) { return e.n.toLowerCase().indexOf(q) >= 0; });
    \\    hits.sort(function (a, b) { return a.n.toLowerCase().indexOf(q) - b.n.toLowerCase().indexOf(q) || a.n.length - b.n.length; });
    \\    hits.slice(0, 20).forEach(function (e) {
    \\      var li = document.createElement("li"), a = document.createElement("a");
    \\      a.href = e.u; a.textContent = e.n; li.appendChild(a);
    \\      if (e.s) { var s = document.createElement("span"); s.className = "summary"; s.textContent = " " + e.s; li.appendChild(s); }
    \\      list.appendChild(li);
    \\    });
    \\  });
    \\})();
    \\
;

fn head(w: *Writer, title: []const u8) Writer.Error!void {
    try w.writeAll("<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try esc(w, title);
    try w.writeAll("</title>\n<style>\n");
    try w.writeAll(style);
    try w.writeAll("</style>\n</head>\n<body>\n<header><a href=\"index.html\">Index</a><input id=\"search\" type=\"search\" placeholder=\"Search\" autocomplete=\"off\" aria-label=\"Search the documentation\"><ul id=\"results\"></ul></header>\n<main>\n");
}

fn foot(w: *Writer) Writer.Error!void {
    try w.writeAll("</main>\n<script src=\"search.js\"></script>\n</body>\n</html>\n");
}

/// The first sentence of a description, for the index and the search.
fn summary(text: []const u8) []const u8 {
    const line = std.mem.sliceTo(std.mem.trim(u8, text, " \n"), '\n');
    if (std.mem.indexOf(u8, line, ". ")) |dot| return line[0 .. dot + 1];
    return line;
}

fn signature(w: *Writer, e: doc.Entry) Writer.Error!void {
    try w.writeAll("<pre><code class=\"language-lus\">function ");
    try esc(w, e.name);
    try w.writeByte('(');
    for (e.params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        if (p.rest) try w.writeAll("...");
        try esc(w, p.name);
    }
    const last_is_vararg = e.params.len > 0 and (e.params[e.params.len - 1].rest or std.mem.eql(u8, e.params[e.params.len - 1].name, "..."));
    if (e.vararg and !last_is_vararg) try w.writeAll(if (e.params.len > 0) ", ..." else "...");
    try w.writeAll(")</code></pre>\n");
}

pub fn writeModule(w: *Writer, arena: Allocator, links: *const Links, m: doc.Module) Writer.Error!void {
    try head(w, m.name);
    try w.writeAll("<h1>");
    try esc(w, m.name);
    try w.writeAll("</h1>\n");
    if (m.package) |p| if (p.version) |v| {
        try w.writeAll("<p class=\"meta\">Version ");
        try esc(w, v);
        if (p.license) |lic| {
            try w.writeAll(", license ");
            try esc(w, lic);
        }
        try w.writeAll("</p>\n");
    };
    if (m.description.len > 0) try markdown(w, arena, links, m.description);
    for (m.entries) |e| {
        try w.writeAll("<section id=\"");
        try esc(w, e.name);
        try w.writeAll("\">\n<h2><code>");
        try esc(w, e.name);
        try w.writeAll("</code></h2>\n");
        if (e.is_function) try signature(w, e) else try w.print("<p class=\"meta\">{s}</p>\n", .{if (std.mem.eql(u8, e.kind, "constant")) "Constant" else "Variable"});
        if (e.description.len > 0) try markdown(w, arena, links, e.description);
        if (e.params.len > 0) {
            try w.writeAll("<h3>Parameters</h3>\n<ul>\n");
            for (e.params) |p| {
                try w.writeAll("<li><code>");
                if (p.rest) try w.writeAll("...");
                try esc(w, p.name);
                try w.writeAll("</code> (<code>");
                try esc(w, p.type);
                try w.writeAll("</code>");
                if (p.optional) try w.writeAll(", optional");
                try w.writeAll(")");
                if (p.description.len > 0) {
                    try w.writeAll(": ");
                    try inline_(w, links, p.description);
                }
                try w.writeAll("</li>\n");
            }
            try w.writeAll("</ul>\n");
        }
        if (e.returns.len > 0) {
            try w.writeAll("<h3>Returns</h3>\n<ul>\n");
            for (e.returns) |r| {
                try w.writeAll("<li><code>");
                try esc(w, r.type);
                try w.writeAll("</code>");
                if (r.description.len > 0) {
                    try w.writeAll(": ");
                    try inline_(w, links, r.description);
                }
                try w.writeAll("</li>\n");
            }
            try w.writeAll("</ul>\n");
        }
        if (e.raises.len > 0) {
            try w.writeAll("<h3>Raises</h3>\n<ul>\n");
            for (e.raises) |r| {
                try w.writeAll("<li>");
                try inline_(w, links, r);
                try w.writeAll("</li>\n");
            }
            try w.writeAll("</ul>\n");
        }
        if (e.since != null or e.stability != null) {
            try w.writeAll("<p class=\"meta\">");
            if (e.since) |s| try w.print("Since {s}.", .{s});
            if (e.since != null and e.stability != null) try w.writeAll(" ");
            if (e.stability) |s| try w.print("Stability: {s}.", .{s});
            try w.writeAll("</p>\n");
        }
        try w.writeAll("</section>\n");
    }
    try foot(w);
}

pub fn writeIndex(w: *Writer, links: *const Links, modules: []const doc.Module) Writer.Error!void {
    try head(w, "Index");
    try w.writeAll("<h1>Modules</h1>\n<ul>\n");
    for (modules) |m| {
        try w.writeAll("<li><a href=\"");
        try esc(w, m.name);
        try w.writeAll(".html\">");
        try esc(w, m.name);
        try w.writeAll("</a>");
        const s = summary(m.description);
        if (s.len > 0) {
            try w.writeAll(" <span class=\"summary\">");
            try inline_(w, links, s);
            try w.writeAll("</span>");
        }
        try w.writeAll("</li>\n");
    }
    try w.writeAll("</ul>\n");
    try foot(w);
}

fn jsString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '<' => try w.writeAll("\\u003c"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// The search index and the script of the search box.
pub fn writeSearch(w: *Writer, modules: []const doc.Module) Writer.Error!void {
    try w.writeAll("window.LUS_DOC_INDEX = [\n");
    for (modules) |m| {
        try w.writeAll("{\"n\": ");
        try jsString(w, m.name);
        try w.print(", \"u\": \"{s}.html\", \"s\": ", .{m.name});
        try jsString(w, summary(m.description));
        try w.writeAll("},\n");
        for (m.entries) |e| {
            try w.writeAll("{\"n\": ");
            try jsString(w, e.name);
            try w.print(", \"u\": \"{s}.html#{s}\", \"s\": ", .{ m.name, e.name });
            try jsString(w, summary(e.description));
            try w.writeAll("},\n");
        }
    }
    try w.writeAll("];\n");
    try w.writeAll(script);
}

const testing = std.testing;

test "markdown renders blocks, inline code, and intra-doc links" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var entries = [_]doc.Entry{.{ .name = "strings.trim", .kind = "function", .line = 1, .is_function = true }};
    const modules = [_]doc.Module{.{ .name = "strings", .entries = &entries }};
    const links = try Links.init(a, &modules);
    var out: std.Io.Writer.Allocating = .init(a);
    try markdown(&out.writer, a, &links,
        \\Removes spaces, see [`trim`] and [the module](strings).
        \\Uses **bold** and `a < b`.
        \\
        \\- one
        \\- two [unknown]
        \\
        \\```lus
        \\print(1 < 2)
        \\```
    );
    try testing.expectEqualStrings(
        \\<p>Removes spaces, see <a href="strings.html#strings.trim"><code>trim</code></a> and <a href="strings.html">the module</a>. Uses <strong>bold</strong> and <code>a &lt; b</code>.</p>
        \\<ul>
        \\<li>one</li>
        \\<li>two [unknown]</li>
        \\</ul>
        \\<pre><code class="language-lus">print(1 &lt; 2)</code></pre>
        \\
    , out.written());
}
