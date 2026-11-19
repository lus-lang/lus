#!/usr/bin/env python3
"""Validate project-authored documentation prose, links, and anchors."""

from __future__ import annotations

import argparse
import posixpath
import re
import sys
from collections import defaultdict
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[1]
ROOT_DOCS = (
    "README.md",
    "CHANGELOG.md",
    "CONTRIBUTING.md",
    "LICENSE.md",
    "THIRD_PARTY_NOTICES.md",
    "lus-install/README.md",
    "lus-spec/README.md",
    "lus-tests/README.md",
    "lus-tests/h4/README.md",
    "lus-vscode/LICENSE",
    "lus-vscode/README.md",
    "lus-vscode/THIRD_PARTY_NOTICES.md",
)
DOC_TREES = (
    ROOT / "lus-site" / "src" / "manual",
    ROOT / "lus-site" / "src" / "news",
    ROOT / "lus-spec" / "stdlib",
    ROOT / "lus-spec" / "capi",
)
SITE_ROUTES = {
    "/",
    "/examples",
    "/faq",
    "/install.sh",
    "/manual",
    "/manual/api",
    "/manual/api/c",
    "/manual/tldr",
    "/news",
    "/playground",
    "/search",
}
API_SECTION_ANCHORS = {
    "environment-functions",
    "table-library",
    "string-library",
    "math-library",
    "io-library",
    "os-library",
    "debug-library",
    "coroutine-library",
    "package-library",
    "utf-8-library",
    "filesystem-library",
    "network-library",
    "vector-library",
    "archive-library",
    "worker-library",
    "time-library",
    "other",
}
CAPI_SECTION_ANCHORS = {
    "permission-system-c-api",
    "worker-system-c-api",
    "library-openers",
    "core-c-api",
    "auxiliary-c-api",
    "other",
}

FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.+?)\s*$")
INLINE_CODE_RE = re.compile(r"(`+)(.+?)\1")
HTML_TAG_RE = re.compile(r"<[^>]*>")
MARKDOWN_LINK_TEXT_RE = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
FRONTMATTER_NAME_RE = re.compile(r"^name:\s*(.+?)\s*$")
FRONTMATTER_PROSE_RE = re.compile(r"^(?:title|shortdesc):\s*(.+?)\s*$")
POSITIVE_FRAMING_RULES = (
    (
        re.compile(
            r"\bthere (?:is|are) no\b[^.]*\b"
            r"(?:method|function|global|api|type|object|module|syntax)s?\b",
            re.IGNORECASE,
        ),
        "rejected alternative phrasing",
    ),
    (
        re.compile(r"\bnot an? object\b", re.IGNORECASE),
        "rejected alternative phrasing",
    ),
    (
        re.compile(r"\bclauses rather than methods\b", re.IGNORECASE),
        "rejected alternative phrasing",
    ),
    (
        re.compile(
            r"\b(?:instead of|rather than) "
            r"(?:a new|an additional|adding|creating|introducing)\b",
            re.IGNORECASE,
        ),
        "rejected alternative phrasing",
    ),
)
LUA_FENCE_EXCEPTIONS = {
    ROOT / "lus-site" / "src" / "manual" / "ide-setup.mdx",
}


class Finding:
    def __init__(self, path: Path, line: int, message: str) -> None:
        self.path = path
        self.line = line
        self.message = message

    def render(self) -> str:
        return f"{self.path.relative_to(ROOT)}:{self.line}: {self.message}"


class RenderedPageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: set[str] = set()
        self.links: list[tuple[int, str]] = []
        self.prose: list[tuple[int, str]] = []
        self._ignored_depth = 0
        self._signature_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        classes = (attributes.get("class") or "").split()
        if tag in {"code", "pre", "script", "style", "svg"}:
            self._ignored_depth += 1
        if "api-signature" in classes:
            self._ignored_depth += 1
            self._signature_depth += 1
        element_id = attributes.get("id")
        if element_id:
            self.ids.add(element_id)
        if tag in {"a", "area"} and attributes.get("href"):
            self.links.append((self.getpos()[0], attributes["href"] or ""))

    def handle_endtag(self, tag: str) -> None:
        if tag in {"code", "pre", "script", "style", "svg"}:
            self._ignored_depth = max(0, self._ignored_depth - 1)
        if tag == "div" and self._signature_depth:
            self._ignored_depth = max(0, self._ignored_depth - 1)
            self._signature_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._ignored_depth == 0 and data.strip():
            self.prose.append((self.getpos()[0], data))


def documentation_files() -> list[Path]:
    files = [ROOT / name for name in ROOT_DOCS if (ROOT / name).is_file()]
    for tree in DOC_TREES:
        if tree.is_dir():
            files.extend(tree.rglob("*.md"))
            files.extend(tree.rglob("*.mdx"))
    return sorted(set(files))


def visible_lines(path: Path) -> list[tuple[int, str]]:
    """Return prose lines outside YAML frontmatter and fenced code blocks."""
    lines = path.read_text(encoding="utf-8").splitlines()
    frontmatter = bool(lines and lines[0].strip() == "---")
    fence_char = ""
    fence_len = 0
    result: list[tuple[int, str]] = []
    for number, line in enumerate(lines, 1):
        if frontmatter:
            if number > 1 and line.strip() == "---":
                frontmatter = False
            continue
        match = FENCE_RE.match(line)
        if match:
            marker = match.group(1)
            if not fence_char:
                fence_char = marker[0]
                fence_len = len(marker)
            elif marker[0] == fence_char and len(marker) >= fence_len:
                fence_char = ""
                fence_len = 0
            continue
        if not fence_char:
            result.append((number, line))
    return result


def frontmatter_prose_lines(path: Path) -> list[tuple[int, str]]:
    """Return user-visible prose fields while omitting signatures and schema data."""
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return []
    result: list[tuple[int, str]] = []
    for number, line in enumerate(lines[1:], 2):
        if line.strip() == "---":
            break
        match = FRONTMATTER_PROSE_RE.match(line)
        if not match:
            continue
        value = match.group(1).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result.append((number, value))
    return result


def prose_lines(path: Path) -> list[tuple[int, str]]:
    return frontmatter_prose_lines(path) + visible_lines(path)


def prose_style_messages(prose: str) -> list[str]:
    messages = []
    for character, label in (
        ("\u2014", "em dash"),
        ("\u2013", "en dash"),
        (";", "semicolon"),
    ):
        if character in prose:
            messages.append(f"{label} in prose")
    for pattern, label in POSITIVE_FRAMING_RULES:
        if pattern.search(prose):
            messages.append(label)
    return messages


def fence_language_findings(
    path: Path, *, allow_lua: bool | None = None
) -> list[Finding]:
    """Require Lus snippets to use the Lus fence while ignoring fence bodies."""
    if allow_lua is None:
        allow_lua = path.resolve() in {item.resolve() for item in LUA_FENCE_EXCEPTIONS}
    lines = path.read_text(encoding="utf-8").splitlines()
    frontmatter = bool(lines and lines[0].strip() == "---")
    fence_char = ""
    fence_len = 0
    findings: list[Finding] = []
    for number, line in enumerate(lines, 1):
        if frontmatter:
            if number > 1 and line.strip() == "---":
                frontmatter = False
            continue
        match = FENCE_RE.match(line)
        if not match:
            continue
        marker = match.group(1)
        if not fence_char:
            fence_char = marker[0]
            fence_len = len(marker)
            info = line[match.end() :].strip().split(maxsplit=1)
            language = info[0].lower() if info else ""
            if language == "lua" and not allow_lua:
                findings.append(
                    Finding(path, number, "Lus snippet must use a ```lus fence")
                )
        elif marker[0] == fence_char and len(marker) >= fence_len:
            fence_char = ""
            fence_len = 0
    return findings


def strip_inline_code(line: str) -> str:
    previous = None
    while line != previous:
        previous = line
        line = INLINE_CODE_RE.sub("", line)
    return line


def heading_slug(text: str) -> str:
    text = INLINE_CODE_RE.sub(lambda match: match.group(2), text)
    text = MARKDOWN_LINK_TEXT_RE.sub(lambda match: match.group(1), text)
    text = HTML_TAG_RE.sub("", text)
    text = re.sub(r"[\*_~]", "", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text, flags=re.UNICODE)
    text = re.sub(r"[\s\-]+", "-", text).strip("-")
    return text


def headings(path: Path) -> set[str]:
    anchors: set[str] = set()
    counts: defaultdict[str, int] = defaultdict(int)
    for _, line in visible_lines(path):
        match = HEADING_RE.match(line)
        if not match:
            continue
        base = heading_slug(match.group(2))
        if not base:
            continue
        count = counts[base]
        counts[base] += 1
        anchors.add(base if count == 0 else f"{base}-{count}")
    return anchors


def frontmatter_name(path: Path) -> str | None:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    for line in lines[1:]:
        if line.strip() == "---":
            break
        match = FRONTMATTER_NAME_RE.match(line)
        if match:
            value = match.group(1).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            return value
    return None


def markdown_links(line: str) -> list[str]:
    """Extract inline Markdown destinations while balancing parentheses."""
    links: list[str] = []
    index = 0
    while index < len(line):
        label_start = line.find("[", index)
        if label_start < 0:
            break
        label_end = line.find("](", label_start + 1)
        if label_end < 0:
            break
        cursor = label_end + 2
        depth = 1
        angle = cursor < len(line) and line[cursor] == "<"
        if angle:
            cursor += 1
            end = line.find(">", cursor)
            if end >= 0 and end + 1 < len(line) and line[end + 1] == ")":
                links.append(line[cursor:end])
                index = end + 2
                continue
        start = cursor
        while cursor < len(line):
            char = line[cursor]
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    destination = line[start:cursor].strip().split(maxsplit=1)[0]
                    if destination:
                        links.append(destination)
                    index = cursor + 1
                    break
            cursor += 1
        else:
            index = label_end + 2
    return links


def collect_site_targets() -> tuple[dict[str, Path], dict[Path, set[str]], set[str], set[str]]:
    manual_paths: dict[str, Path] = {}
    anchors: dict[Path, set[str]] = {}
    for path in sorted((ROOT / "lus-site" / "src" / "manual").glob("*.mdx")):
        manual_paths[f"/manual/{path.stem}"] = path
        anchors[path] = headings(path)

    news = {
        path.stem
        for path in (ROOT / "lus-site" / "src" / "news").glob("*.md")
    }
    stdlib = {
        name
        for path in (ROOT / "lus-spec" / "stdlib").rglob("*.md")
        if (name := frontmatter_name(path))
    }
    capi = {
        name
        for path in (ROOT / "lus-spec" / "capi").rglob("*.md")
        if (name := frontmatter_name(path))
    }
    return manual_paths, anchors, news, stdlib | API_SECTION_ANCHORS, capi | CAPI_SECTION_ANCHORS


def check_link(
    source: Path,
    line: int,
    destination: str,
    manual_paths: dict[str, Path],
    anchor_map: dict[Path, set[str]],
    news: set[str],
    stdlib_anchors: set[str],
    capi_anchors: set[str],
) -> Finding | None:
    if destination.startswith(("http://", "https://", "mailto:", "tel:", "data:")):
        return None
    if destination.startswith(("{", "$")):
        return None
    parts = urlsplit(destination)
    route = unquote(parts.path)
    fragment = unquote(parts.fragment)

    if route == "":
        if fragment and fragment not in anchor_map.get(source, set()):
            return Finding(source, line, f"unknown anchor #{fragment}")
        return None

    if route.startswith("/"):
        normalized = route.rstrip("/") or "/"
        repository_target = (ROOT / normalized.lstrip("/")).resolve()
        if not source.is_relative_to(ROOT / "lus-site" / "src") and repository_target.exists():
            if fragment and repository_target.suffix in {".md", ".mdx"}:
                target_anchors = anchor_map.setdefault(repository_target, headings(repository_target))
                if fragment not in target_anchors:
                    return Finding(source, line, f"unknown anchor {normalized}#{fragment}")
            return None
        if normalized == "/manual/api":
            if fragment and fragment not in stdlib_anchors:
                return Finding(source, line, f"unknown standard library anchor #{fragment}")
            return None
        if normalized == "/manual/api/c":
            if fragment and fragment not in capi_anchors:
                return Finding(source, line, f"unknown C API anchor #{fragment}")
            return None
        if normalized in manual_paths:
            target = manual_paths[normalized]
            if fragment and fragment not in anchor_map[target]:
                return Finding(source, line, f"unknown anchor {normalized}#{fragment}")
            return None
        if normalized.startswith("/news/"):
            if normalized.removeprefix("/news/") not in news:
                return Finding(source, line, f"unknown site route {normalized}")
            return None
        if normalized not in SITE_ROUTES:
            return Finding(source, line, f"unknown site route {normalized}")
        return None

    relative_path = (source.parent / route).resolve()
    try:
        relative_path.relative_to(ROOT)
    except ValueError:
        return Finding(source, line, f"link escapes repository: {destination}")
    if not relative_path.exists():
        return Finding(source, line, f"missing relative link target {route}")
    if fragment and relative_path.suffix in {".md", ".mdx"}:
        target_anchors = anchor_map.setdefault(relative_path, headings(relative_path))
        if fragment not in target_anchors:
            return Finding(source, line, f"unknown anchor {route}#{fragment}")
    return None


def rendered_route(path: Path, site_dir: Path) -> str:
    relative = path.relative_to(site_dir).as_posix()
    if relative == "index.html":
        return "/"
    if relative.endswith("/index.html"):
        return "/" + relative.removesuffix("/index.html")
    return "/" + relative


def rendered_target(route: str, site_dir: Path) -> Path | None:
    relative = route.lstrip("/")
    direct = site_dir / relative
    if direct.is_file():
        return direct
    index = direct / "index.html"
    if index.is_file():
        return index
    if route == "/" and (site_dir / "index.html").is_file():
        return site_dir / "index.html"
    return None


def is_application_fragment(route: str, fragment: str) -> bool:
    """Return whether a fragment carries client state rather than an HTML id."""
    return route == "/playground" and fragment.startswith("code=")


def validate_rendered_site(site_dir: Path) -> list[Finding]:
    site_dir = site_dir.resolve()
    if not site_dir.is_dir():
        return [Finding(site_dir, 1, "rendered site directory does not exist")]

    parsed: dict[Path, RenderedPageParser] = {}

    def page(path: Path) -> RenderedPageParser:
        if path not in parsed:
            parser = RenderedPageParser()
            parser.feed(path.read_text(encoding="utf-8"))
            parsed[path] = parser
        return parsed[path]

    findings: list[Finding] = []
    for source in sorted(site_dir.rglob("*.html")):
        source_route = rendered_route(source, site_dir)
        source_url = source_route
        if source.name == "index.html" and not source_url.endswith("/"):
            source_url += "/"
        source_page = page(source)
        for line, prose in source_page.prose:
            for message in prose_style_messages(prose):
                findings.append(Finding(source, line, f"{message} in rendered page"))
        for line, href in source_page.links:
            parts = urlsplit(href)
            if parts.scheme or parts.netloc:
                continue
            if parts.path == "":
                target = source
            else:
                target_route = unquote(urlsplit(urljoin(source_url, href)).path)
                target_route = "/" + posixpath.normpath(target_route).lstrip("/")
                target = rendered_target(target_route, site_dir)
                if target is None:
                    findings.append(Finding(source, line, f"missing rendered link target {target_route}"))
                    continue
            fragment = unquote(parts.fragment)
            target_route = rendered_route(target, site_dir)
            if (
                fragment
                and not is_application_fragment(target_route, fragment)
                and target.suffix == ".html"
                and fragment not in page(target).ids
            ):
                findings.append(Finding(source, line, f"unknown rendered anchor {target_route}#{fragment}"))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--site-dir",
        type=Path,
        help="also validate links and anchors in a rendered static site",
    )
    args = parser.parse_args()
    files = documentation_files()
    manual_paths, anchor_map, news, stdlib_anchors, capi_anchors = collect_site_targets()
    findings: list[Finding] = []

    for path in files:
        anchor_map.setdefault(path, headings(path))
        findings.extend(fence_language_findings(path))
        for line_number, raw_line in prose_lines(path):
            prose = strip_inline_code(raw_line)
            for message in prose_style_messages(prose):
                findings.append(Finding(path, line_number, message))
            for destination in markdown_links(prose):
                finding = check_link(
                    path,
                    line_number,
                    destination,
                    manual_paths,
                    anchor_map,
                    news,
                    stdlib_anchors,
                    capi_anchors,
                )
                if finding:
                    findings.append(finding)

    if args.site_dir:
        findings.extend(validate_rendered_site(args.site_dir))

    if findings:
        for finding in findings:
            print(finding.render())
        print(f"documentation validation failed with {len(findings)} finding(s)", file=sys.stderr)
        return 1
    suffix = ""
    if args.site_dir:
        rendered_count = len(list(args.site_dir.resolve().rglob("*.html")))
        suffix = f" and {rendered_count} rendered pages"
    print(f"documentation validation passed for {len(files)} files{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
