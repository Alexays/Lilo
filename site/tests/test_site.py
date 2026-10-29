"""Check the deployed output, including the routes and metadata kept during migration."""
import base64
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

PAGES = ["index.html", "moving/index.html", "arc-alternative/index.html", "compare/index.html", "ai-agents/index.html",
         "changelog/index.html", "fr/index.html", "fr/moving/index.html", "fr/arc-alternative/index.html",
         "fr/compare/index.html", "fr/ai-agents/index.html", "fr/changelog/index.html"]


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
    def test_every_public_page_uses_the_shared_top_sections_and_bottom(self):
        for page in PAGES + ["404.html"]:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                main = next(node for node in parsed if node.tag == "main")
                content = [node for node in main.children
                           if isinstance(node, Node) and node.tag not in {"script", "style"}]
                self.assertTrue(all(node.tag == "section" for node in content),
                                f"Unframed content in {page}")
                sections = [node for node in main.children
                            if isinstance(node, Node) and node.tag == "section"]
                self.assertEqual(sum("page-hero" in node.classes for node in parsed), 1)
                self.assertEqual(sum("page-end" in node.classes for node in parsed), 1)
                self.assertIn("page-hero", sections[0].classes)
                self.assertIn("page-end", sections[-1].classes)
                for section in sections:
                    frames = [node for node in section.children
                              if isinstance(node, Node) and "page-frame" in node.classes]
                    self.assertEqual(len(frames), 1)
                    frame = frames[0]
                    self.assertIn("wrap", frame.classes)
                    self.assertIn("page-frame", frame.classes)
                    self.assertNotIn("style", frame.attrs)

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
                self.assertEqual(links, [home + "moving/",
                                         "https://github.com/Alexays/Lilo/blob/main/docs/README.md",
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

    def test_release_story_keeps_translated_highlights_and_complete_notes_in_static_html(self):
        for language, page in [("en", "changelog/index.html"), ("fr", "fr/changelog/index.html")]:
            with self.subTest(language=language):
                parsed = tree(DIST / page)
                release = next(node for node in parsed if node.attrs.get("id") == "v0.7.0")
                highlights = [node for node in nodes(release) if "release-highlight" in node.classes]
                self.assertEqual(len(highlights), 3)
                self.assertTrue(all(node.attrs.get("lang") == language for node in highlights))
                capture = next(node for node in nodes(highlights[0]) if "capture" in node.classes)
                images = [node for node in nodes(capture) if node.tag == "img"]
                self.assertEqual(len(images), 2)
                for image in images:
                    self.assertTrue(image.attrs.get("alt"))
                    self.assertGreater(int(image.attrs["width"]), 0)
                    self.assertGreater(int(image.attrs["height"]), 0)
                    self.assertEqual(image.attrs.get("loading"), "lazy")
                disclosure = next(node for node in nodes(release) if node.tag == "details")
                self.assertNotIn("open", disclosure.attrs)
                self.assertIn("A call card in the sidebar", inline_text(disclosure))
                self.assertIn("chrome.mdns", (DIST / page).with_suffix(".md").read_text())
                demo_link = next(node for node in nodes(highlights[0]) if node.tag == "a")
                self.assertEqual(demo_link.attrs["href"], ("/fr/" if language == "fr" else "/") + "#browser-demo")

    def test_release_recording_has_local_animation_controls_and_a_contextual_action(self):
        for page in ["changelog/index.html", "fr/changelog/index.html"]:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                recording = [node for node in parsed if "release-recording" in node.classes]
                self.assertGreaterEqual(len(recording), 3)
                for player in recording:
                    button = next(node for node in nodes(player) if node.tag == "button")
                    self.assertEqual(button.attrs.get("aria-pressed"), "false")
                    self.assertTrue(button.attrs.get("aria-label"))
                    self.assertTrue(any(node.tag == "svg" for node in nodes(button)))
                    self.assertFalse(any(node.tag in ["time", "figcaption", "a"] for node in nodes(player)))
                    for image in (node for node in nodes(player) if node.tag == "img"):
                        animation = image.attrs.get("data-recording", "")
                        self.assertTrue(animation.endswith(".webp"))
                        self.assertTrue((DIST / animation.lstrip("/")).is_file())
                        self.assertNotEqual(image.attrs["src"], animation)
                highlight = next(node for node in parsed if node.attrs.get("id") == "v0.7.0-peek")
                action = next(node for node in nodes(highlight) if "recording-action" in node.classes)
                self.assertEqual(action.parent, highlight)
                for name in ["calls", "languages"]:
                    highlight = next(node for node in parsed if node.attrs.get("id") == "v0.7.0-" + name)
                    self.assertFalse(any(node.tag == "a" for node in nodes(highlight)))

    def test_astro_bundles_header_and_keeps_demo_on_home_pages(self):
        shared = {node.attrs["src"] for node in tree(DIST / "moving/index.html")
                  if node.tag == "script" and "src" in node.attrs}
        self.assertEqual(len(shared), 3)
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
                if page in ["index.html", "fr/index.html", "changelog/index.html", "fr/changelog/index.html"]:
                    self.assertEqual(len(scripts), 4)
                else:
                    self.assertEqual(sources, shared)
        self.assertFalse((DIST / "app.js").exists())

    def test_home_demo_embeds_the_real_interface_and_extensions_link_to_the_store(self):
        extension_ids = {"neebplgakaahbhdphmkckjjcegoiijjo", "eimadpbcbfnmbkopoojfekhnkhdbieeh",
                         "fmkadmapgofadopljbjfkapdkoienihi"}
        for page in ["index.html", "fr/index.html"]:
            with self.subTest(page=page):
                parsed = tree(DIST / page)
                demo = next(node for node in parsed if node.attrs.get("id") == "browser-demo")
                frames = [node for node in nodes(demo) if node.tag == "iframe"]
                self.assertEqual(len(frames), 1)
                self.assertEqual(frames[0].attrs["src"], "/demo/?lang=" + ("fr" if page.startswith("fr/") else "en"))
                self.assertEqual(frames[0].attrs.get("loading"), "lazy")
                self.assertTrue(frames[0].attrs.get("title"))
                actions = {node.attrs.get("data-action") for node in nodes(demo)}
                self.assertTrue({"settings", "newTab", "terminal", "newSpace", "reset", "fullscreen"}.issubset(actions))
                self.assertFalse(any("data-demo-space" in node.attrs for node in nodes(demo)))
                links = [node for node in parsed if "store-link" in node.classes]
                self.assertEqual({urlparse(node.attrs["href"]).path.split("/")[-1] for node in links}, extension_ids)
                self.assertTrue(all(urlparse(node.attrs["href"]).netloc == "chromewebstore.google.com" for node in links))
                self.assertTrue(all(inline_text(node).strip() in node.attrs["aria-label"] for node in links))
                self.assertFalse(any(node.tag == "button" and "add" in node.classes for node in parsed))

    def test_demo_assets_and_scoped_frame_policy_ship_together(self):
        parsed = tree(DIST / "demo/index.html")
        self.assertTrue(any(node.attrs.get("name") == "robots" and node.attrs.get("content") == "noindex" for node in parsed))
        scripts = [node.attrs["src"] for node in parsed if node.tag == "script" and "src" in node.attrs]
        self.assertTrue(scripts)
        for source in scripts:
            self.assertTrue(source.startswith("/_astro/"))
            self.assertTrue((DIST / source.lstrip("/")).is_file())
        headers = (DIST / "_headers").read_text()
        self.assertIn("frame-src 'self'", headers)
        self.assertRegex(headers, r"/demo/\*\s+! Content-Security-Policy\s+Content-Security-Policy:.*frame-ancestors 'self'")

    def test_demo_assets_match_the_native_icon_catalog_and_ship_locally(self):
        parsed = tree(DIST / "demo/index.html")
        app = next(node for node in parsed if node.attrs.get("id") == "app")
        assets = json.loads(app.attrs["data-assets"])
        root = Path(__file__).resolve().parents[2]
        source = (root / "Lilo/App/AppIconPreference.swift").read_text()
        variants = re.search(r"static let variants = \[(.*?)\]", source).group(1)
        self.assertEqual([icon["id"] for icon in assets["appIcons"]], re.findall(r'"([a-z]+)"', variants))
        for url in [icon["dataURL"] for icon in assets["appIcons"]] + list(assets["images"].values()):
            with self.subTest(url=url):
                if not url.startswith("data:image/"):
                    self.assertTrue(url.startswith("/"))
                    self.assertTrue((DIST / url.lstrip("/")).is_file())
        for key, source in {
            "bitwarden": root / "lilo-ui/public/password-managers/nngceckbapebfimnlniiiahkandclblb.png",
            "darkReader": root / "site/src/assets/extensions/dark-reader.png",
            "codex": root / "site/src/assets/demo/codex.png",
        }.items():
            with self.subTest(embedded=key):
                prefix, encoded = assets["images"][key].split(",", 1)
                self.assertEqual(prefix, "data:image/png;base64")
                self.assertEqual(base64.b64decode(encoded), source.read_bytes())
        for source in (root / "lilo-ui/public/password-managers").glob("*.png"):
            with self.subTest(manager=source.name):
                self.assertFalse((DIST / "demo/password-managers" / source.name).is_symlink())
                self.assertEqual((DIST / "demo/password-managers" / source.name).read_bytes(), source.read_bytes())

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
