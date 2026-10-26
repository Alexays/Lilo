"""Check the deployed output, including the routes and metadata kept during migration."""
import json
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate import DIST, Node, Tree, plain, sync_json_ld

PAGES = ["index.html", "moving/index.html", "changelog/index.html",
         "fr/index.html", "fr/moving/index.html", "fr/changelog/index.html"]


def nodes(node):
    if isinstance(node, Node):
        yield node
        for child in node.children:
            yield from nodes(child)


def tree(path):
    parsed = Tree()
    parsed.feed(path.read_text())
    return list(nodes(parsed.root))


def inline_text(node):
    if isinstance(node, str):
        return node
    return "".join(inline_text(child) for child in node.children)


class SiteTests(unittest.TestCase):
    def test_page_landmarks_and_navigation(self):
        for page in PAGES + ["404.html"]:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                mains = [node for node in parsed if node.tag == "main"]
                self.assertEqual(len(mains), 1)
                main = mains[0]
                self.assertEqual(main.attrs.get("id"), "main-content")
                self.assertEqual(sum(node.tag == "h1" for node in nodes(main)), 1)
                footers = [node for node in parsed if node.tag == "footer"]
                self.assertEqual(len(footers), 1)
                self.assertEqual(footers[0].parent.tag, "body")
                header = next(node for node in parsed if "site-header" in node.classes)
                navigation = [node for node in nodes(header) if node.tag == "nav"]
                self.assertEqual(len(navigation), 1)
                links = [node.attrs["href"] for node in nodes(navigation[0]) if node.tag == "a"]
                home = "/fr/" if page.startswith("fr/") else "/"
                self.assertEqual(links, [home + "#" + section for section in
                                        ["native", "privacy", "extensions", "build", "agents"]]
                                 + [home + "moving/", "https://github.com/Alexays/Lilo/blob/main/docs/README.md",
                                    home + "changelog/"])

    def test_routes_language_alternates_and_markdown_copies(self):
        sitemap = ET.parse(DIST / "sitemap.xml")
        locations = {node.text for node in sitemap.findall(".//{*}loc")}
        for page in PAGES:
            with self.subTest(page=page):
                source = (DIST / page).read_text()
                parsed = tree(DIST / page)
                url = "https://getlilo.app/" + page.removesuffix("index.html")
                lang = "fr" if page.startswith("fr/") else "en"
                self.assertEqual(next(node for node in parsed if node.tag == "html").attrs["lang"], lang)
                self.assertIn(url, locations)
                self.assertIn('rel="canonical" href="' + url + '"', source)
                self.assertEqual({node.attrs["hreflang"] for node in parsed if "hreflang" in node.attrs}, {"en", "fr", "x-default"})
                self.assertEqual(source.count('<h1'), 1)
                title = next(node for node in parsed if node.tag == "title")
                self.assertNotIn("&nbsp;", "".join(title.children))
                description = next(node for node in parsed if node.tag == "meta" and node.attrs.get("name") == "description")
                self.assertNotIn("&nbsp;", description.attrs["content"])
                markdown = (DIST / page).with_suffix(".md").read_text()
                self.assertIn("Web page: " + url, markdown)
                self.assertNotIn("Skip to content", markdown)

    def test_local_links_fragments_and_assets_resolve(self):
        for page in PAGES + ["404.html"]:
            source = DIST / page
            parsed = tree(source)
            ids = [node.attrs["id"] for node in parsed if "id" in node.attrs]
            self.assertEqual(len(ids), len(set(ids)), f"Duplicate IDs in {page}")
            for node in parsed:
                targets = [(attribute, node.attrs.get(attribute, "")) for attribute in ["href", "src"]]
                targets += [("srcset", item.strip().split()[0])
                            for item in node.attrs.get("srcset", "").split(",") if item.strip()]
                for attribute, target in targets:
                    url = urlparse(target)
                    if not target or url.scheme or url.netloc:
                        continue
                    path = DIST / unquote(url.path.lstrip("/")) if url.path.startswith("/") else source.parent / unquote(url.path)
                    if not url.path:
                        path = source
                    elif path.is_dir():
                        path /= "index.html"
                    with self.subTest(page=page, target=target):
                        self.assertTrue(path.is_file(), f"Broken {attribute}: {target}")
                        if url.fragment and path.suffix == ".html":
                            ids = {item.attrs.get("id") for item in tree(path)}
                            self.assertIn(unquote(url.fragment), ids)

    def test_llms_index_and_full_content_ship_in_the_build(self):
        index = (DIST / "llms.txt").read_text()
        full = (DIST / "llms-full.txt").read_text()
        self.assertIn("https://getlilo.app/llms-full.txt", index)
        for page in PAGES:
            if not page.startswith("fr/"):
                with self.subTest(page=page):
                    markdown = (DIST / page).with_suffix(".md").read_text()
                    self.assertIn(markdown.strip(), full)

    def test_app_version_and_faq_metadata_match_the_page(self):
        config = (DIST.parents[1] / "Xcode/Configs/Base.xcconfig").read_text()
        version = re.search(r"^MARKETING_VERSION = (\S+)$", config, re.M)[1]
        for page in [path for path in PAGES if "changelog" not in path]:
            source = (DIST / page).read_text()
            graph = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', source, re.S)[1])["@graph"]
            faq = next(node for node in graph if node["@type"] == "FAQPage")["mainEntity"]
            visible = re.findall(r"<details>\s*<summary>(.*?)</summary>\s*<p>(.*?)</p>\s*</details>", source, re.S)
            self.assertGreater(len(faq), 0)
            self.assertEqual([(item["name"], item["acceptedAnswer"]["text"]) for item in faq],
                             [(plain(question), plain(answer)) for question, answer in visible])
            for node in graph:
                if node["@type"] == "SoftwareApplication":
                    self.assertEqual(node["softwareVersion"], version)
                    self.assertIn("getlilo.app/", node["releaseNotes"])

    def test_changelog_has_all_published_releases_in_static_html(self):
        source = (DIST.parents[1] / "CHANGELOG.md").read_text()
        versions = re.findall(r"^## \[([^\]]+)\] - ", source, re.M)
        for page in ["changelog/index.html", "fr/changelog/index.html"]:
            parsed = tree(DIST / page)
            self.assertEqual([node.attrs["id"] for node in parsed if "release" in node.classes], ["v" + version for version in versions])
            self.assertIn("First public release", (DIST / page).with_suffix(".md").read_text())
            current = next(node for node in parsed if node.attrs.get("aria-current") == "page")
            self.assertEqual(current.attrs["href"], "/" + page.removesuffix("index.html"))
        self.assertIn("First public release", (DIST / "llms-full.txt").read_text())

    def test_astro_bundles_header_and_keeps_demo_on_home_pages(self):
        shared = {node.attrs["src"] for node in tree(DIST / "changelog/index.html")
                  if node.tag == "script" and "src" in node.attrs}
        self.assertEqual(len(shared), 1)
        for page in PAGES:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                scripts = [node for node in parsed
                           if node.tag == "script" and "src" in node.attrs]
                for script in scripts:
                    self.assertEqual(script.attrs.get("type"), "module")
                    self.assertTrue(script.attrs["src"].startswith("/_astro/"))
                self.assertFalse(any(node.tag == "script" and "src" not in node.attrs
                                     and node.attrs.get("type") != "application/ld+json"
                                     for node in parsed))
                sources = {node.attrs["src"] for node in scripts}
                self.assertTrue(shared.issubset(sources))
                if page in ["index.html", "fr/index.html"]:
                    self.assertEqual(len(scripts), 2)
                else:
                    self.assertEqual(sources, shared)
        self.assertFalse((DIST / "app.js").exists())

    def test_home_previews_are_static_and_extensions_link_to_the_store(self):
        extension_ids = {"neebplgakaahbhdphmkckjjcegoiijjo", "eimadpbcbfnmbkopoojfekhnkhdbieeh",
                         "fmkadmapgofadopljbjfkapdkoienihi"}
        for page in ["index.html", "fr/index.html"]:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                demo = next(node for node in parsed if node.attrs.get("id") == "browser-demo")
                controls = [node for node in nodes(demo) if node.tag == "input"]
                self.assertEqual(len(controls), 3)
                self.assertTrue(all(node.attrs.get("type") == "radio" and node.attrs.get("aria-label") for node in controls))
                self.assertEqual(sum("checked" in node.attrs for node in controls), 1)
                self.assertTrue(all(any(label.tag == "label" and label.attrs.get("for") == control.attrs["id"]
                                        for label in nodes(demo)) for control in controls))
                self.assertIn("Lisbonne" if page.startswith("fr/") else "Lisbon", inline_text(demo))
                links = [node for node in parsed if "store-link" in node.classes]
                self.assertEqual({urlparse(node.attrs["href"]).path.split("/")[-1] for node in links}, extension_ids)
                self.assertTrue(all(urlparse(node.attrs["href"]).netloc == "chromewebstore.google.com" for node in links))
                self.assertTrue(all(inline_text(node).strip() in node.attrs["aria-label"] for node in links))
                self.assertFalse(any(node.tag == "button" and "add" in node.classes for node in parsed))

    def test_import_tables_can_be_scrolled_by_keyboard_and_have_row_groups(self):
        for page in ["moving/index.html", "fr/moving/index.html"]:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                region = next(node for node in parsed if "matrix" in node.classes)
                self.assertEqual(region.attrs.get("tabindex"), "0")
                self.assertTrue(any(node.attrs.get("id") == region.attrs.get("aria-labelledby") for node in parsed))
                groups = [node for node in nodes(region) if node.tag == "tbody"]
                self.assertEqual(len(groups), 3)
                for group in groups[1:]:
                    headers = [node for node in nodes(group) if node.attrs.get("scope") == "rowgroup"]
                    self.assertEqual(len(headers), 1)

    def test_faq_json_ld_preserves_html_examples_without_closing_the_script(self):
        source = r'''<script type="application/ld+json">{"@graph":[{"@type":"FAQPage","description":"Use \u003c/script> literally","mainEntity":[]}]}</script>
<details><summary>Can I show HTML?</summary><p>Yes: &lt;/script&gt; and &lt;b&gt;.</p></details>'''
        with TemporaryDirectory() as directory, patch("generate.DIST", Path(directory)):
            file = Path(directory) / "index.html"
            file.write_text(source)
            sync_json_ld("index.html")
            output = file.read_text()
        self.assertEqual(output.count("</script>"), 1)
        graph = json.loads(re.search(r'<script type="application/ld\+json">(.*?)</script>', output, re.S)[1])["@graph"]
        self.assertEqual(graph[0]["description"], "Use </script> literally")
        self.assertEqual(graph[0]["mainEntity"][0]["acceptedAnswer"]["text"], "Yes: </script> and <b>.")

    def test_cloudflare_assets_and_redirects_ship_in_the_build(self):
        redirects = (DIST / "_redirects").read_text()
        headers = (DIST / "_headers").read_text()
        self.assertIn("script-src 'self'", headers)
        self.assertIn("/_astro/*", headers)
        self.assertIn('name="robots" content="noindex"', (DIST / "404.html").read_text())
        for prefix in ["/changelog", "/fr/changelog"]:
            self.assertIn(f"{prefix} {prefix}/ 301", redirects)
            self.assertIn(f"{prefix}/index.html {prefix}/ 301", redirects)


if __name__ == "__main__":
    unittest.main()
