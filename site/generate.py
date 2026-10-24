#!/usr/bin/env python3
"""Derive Markdown copies, llms-full.txt and FAQ metadata from Astro's built HTML."""
import html
import json
import re
from html.parser import HTMLParser
from pathlib import Path

SITE = "https://getlilo.app"
DIST = Path(__file__).resolve().parent / "dist"

VOID = {"meta", "link", "br", "img", "input", "hr", "source"}
BLOCK = {"main", "section", "article", "header", "div", "p", "h1", "h2", "h3", "h4", "details", "summary", "table", "footer", "ul", "ol", "li", "time"}
# Interactive mockups and decoration: their text is illustration, not page content.
SKIP_TAGS = {"script", "style", "svg", "button", "head", "nav"}
SKIP_CLASSES = {"window", "store", "termcard", "tag", "mark", "nav", "skip-link"}
LIST_PARENTS = {"cta", "foot-links", "cats", "feat-list", "ag-list", "release-meta"}


class Node:
    def __init__(self, tag, attrs, parent):
        self.tag, self.attrs, self.parent, self.children = tag, dict(attrs), parent, []

    @property
    def classes(self):
        return set((self.attrs.get("class") or "").split())


class Tree(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = self.cur = Node("root", {}, None)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs, self.cur)
        self.cur.children.append(node)
        if tag not in VOID:
            self.cur = node

    def handle_startendtag(self, tag, attrs):
        self.cur.children.append(Node(tag, attrs, self.cur))

    def handle_endtag(self, tag):
        node = self.cur
        while node is not self.root and node.tag != tag:
            node = node.parent
        if node is not self.root:
            self.cur = node.parent

    def handle_data(self, data):
        self.cur.children.append(data)


def skipped(n):
    return n.tag in SKIP_TAGS or n.classes & SKIP_CLASSES or n.attrs.get("aria-hidden") == "true" or n.attrs.get("role") == "img"


def is_block(n):
    if not isinstance(n, Node):
        return False
    return (
        n.tag in BLOCK
        or "pill" in n.classes
        or n.classes & {"move-in", "brew", "beta"}
        or n.tag in {"span", "a"} and (n.parent.classes & (LIST_PARENTS | {"soon", "ag-cta"}) or n.parent.tag == "footer")
    )


def absolute(href, page_url):
    if href.startswith("#"):
        return page_url + href
    return SITE + href if href.startswith("/") else href


def inline(n, page_url):
    if isinstance(n, str):
        return re.sub(r"\s+", " ", n)
    if skipped(n):
        return ""
    if n.tag == "br":
        return " "
    inner = "".join(inline(c, page_url) for c in n.children)
    if n.tag == "a":
        return f"[{inner.strip()}]({absolute(n.attrs['href'], page_url)})"
    if n.tag in {"b", "strong"} and inner.strip():
        return f"**{inner.strip()}**"
    if n.tag == "code":
        return f"`{inner.strip()}`"
    if n.tag == "kbd":
        return f" `{inner.strip()}` "
    return inner


def table(n, page_url):
    rows = []
    for tr in (r for part in n.children if isinstance(part, Node) for r in part.children if isinstance(r, Node) and r.tag == "tr"):
        cells = [c for c in tr.children if isinstance(c, Node)]
        if len(cells) == 1:
            cells_text = [f"**{inline(cells[0], page_url).strip()}**"] + [""] * (int(cells[0].attrs.get("colspan", 1)) - 1)
        else:
            cells_text = [inline(c, page_url).strip() for c in cells]
        rows.append("| " + " | ".join(cells_text) + " |")
        if len(rows) == 1:
            rows.append("|" + "---|" * len(cells_text))
    return "\n".join(rows)


def blocks(n, page_url):
    """Returns the Markdown blocks of a block-level node."""
    if skipped(n):
        return []
    if n.tag in {"h1", "h2", "h3", "h4"}:
        return ["#" * int(n.tag[1]) + " " + inline(n, page_url).strip()]
    if n.tag == "summary":
        return ["### " + inline(n, page_url).strip()]
    if n.tag == "li":
        return ["- " + inline(n, page_url).strip()]
    if n.tag == "table":
        return [table(n, page_url)]
    if "brew" in n.classes:
        return ["```sh\n" + inline(n, page_url).strip() + "\n```"]
    if "pill" in n.classes or n.tag in {"a", "span"} and n.parent.classes & LIST_PARENTS or n.parent.classes & {"feat-list", "ag-list"}:
        return ["- " + inline(n, page_url).strip()]
    out, run = [], []

    def flush():
        text = re.sub(r" {2,}", " ", "".join(run)).strip()
        if text:
            out.append(text)
        run.clear()

    for c in n.children:
        if is_block(c):
            flush()
            out += blocks(c, page_url)
        else:
            run.append(inline(c, page_url))
    flush()
    return out


def join(parts):
    text = ""
    for prev, cur in zip([None] + parts, parts):
        sep = "\n" if prev and prev.startswith("- ") and cur.startswith("- ") else "\n\n"
        text += (sep if prev is not None else "") + cur
    return text + "\n"


def convert(path):
    src = (DIST / path).read_text()
    page_url = SITE + "/" + path.removesuffix("index.html")
    tree = Tree()
    tree.feed(src)
    body = next(n for n in tree.root.children if isinstance(n, Node) and n.tag == "html")
    body = next(n for n in body.children if isinstance(n, Node) and n.tag == "body")
    parts = []
    for part in blocks(body, page_url):
        # A numbered step badge belongs to the step's heading.
        if parts and parts[-1].isdigit() and part.startswith("### "):
            part = f"### {parts.pop()}. {part[4:]}"
        parts.append(part)
    meta = lambda pattern: html.unescape(re.search(pattern, src).group(1))
    h1 = next(i for i, p in enumerate(parts) if p.startswith("# "))
    head = ["# " + meta(r"<title>([^<]*)</title>"), "> " + meta(r'<meta name="description" content="([^"]*)"'), f"Web page: {page_url}"]
    return join(head + ["**" + parts[h1][2:] + "**"] + parts[h1 + 1 :])


def plain(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", fragment))).strip()


def sync_json_ld(path):
    """Keep FAQPage equal to the visible FAQ, including Astro's rendered whitespace."""
    file = DIST / path
    src = file.read_text()
    faq = [
        {"@type": "Question", "name": plain(q), "acceptedAnswer": {"@type": "Answer", "text": plain(a)}}
        for q, a in re.findall(r"<details>\s*<summary>(.*?)</summary>\s*<p>(.*?)</p>\s*</details>", src, re.S)
    ]
    match = re.search(r'<script type="application/ld\+json">(.*?)</script>', src, re.S)
    if not match:
        return
    data = json.loads(match.group(1))
    for node in data["@graph"]:
        if node["@type"] == "FAQPage":
            node["mainEntity"] = faq
    ld = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    file.write_text(src[: match.start(1)] + ld + src[match.end(1) :])


def main():
    pages = sorted(path.relative_to(DIST).as_posix() for path in DIST.rglob("index.html"))
    full = []
    for path in sorted(pages, key=lambda path: (path != "index.html", path)):
        sync_json_ld(path)
        md = convert(path)
        (DIST / path).with_suffix(".md").write_text(md)
        if not path.startswith("fr/"):
            full.append(md)
    (DIST / "llms-full.txt").write_text("\n".join(full))


if __name__ == "__main__":
    main()
