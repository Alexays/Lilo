"""Check release announcements without sending Discord messages."""
import json
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

from release_discord import publish


class DiscordReleaseTests(unittest.TestCase):
    def setUp(self):
        self.webhook = "https://example.com/api/webhooks/123/secret"
        self.url = "https://example.com/releases/tag/v1.2.3"
        self.event = {
            "action": "published",
            "release": {
                "tag_name": "v1.2.3", "draft": False, "prerelease": False,
                "html_url": self.url,
                "body": "## [1.2.3] - 2026-01-01\n\n### Fixed\n\n- Tabs stay open.\n\n"
                        "[1.2.3]: https://example.com/compare/v1.2.2...v1.2.3\n",
            },
        }
        self.network = patch("release_discord.urlopen")
        self.urlopen = self.network.start()
        self.addCleanup(self.network.stop)

    def payload(self):
        request = self.urlopen.call_args.args[0]
        return json.loads(request.data)

    def test_publishes_changie_notes_with_working_links_and_no_mentions(self):
        self.event["release"]["body"] += '\n- Keep "quoted" text, @everyone and <@123> as text.\n'
        self.event["release"]["body"] += '\n## [Already linked](https://example.com)\n'
        publish(self.event, self.webhook)
        self.urlopen.assert_called_once()
        request = self.urlopen.call_args.args[0]
        self.assertEqual(request.full_url, self.webhook + "?wait=true")
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertEqual(self.urlopen.call_args.kwargs["timeout"], 30)
        payload = self.payload()
        self.assertEqual(payload["allowed_mentions"], {"parse": []})
        embed = payload["embeds"][0]
        self.assertEqual(embed["title"], "Lilo v1.2.3")
        self.assertEqual(embed["url"], self.url)
        self.assertIn("## 1.2.3 - 2026-01-01", embed["description"])
        self.assertIn("### Fixed\n\n- Tabs stay open.", embed["description"])
        self.assertIn("[Compare changes](https://example.com/compare/v1.2.2...v1.2.3)", embed["description"])
        self.assertIn('"quoted" text, @everyone and <@123>', embed["description"])
        self.assertIn("## [Already linked](https://example.com)", embed["description"])

    def test_long_notes_fit_discord_and_link_to_the_full_changelog(self):
        for body in ["- A change.\n" * 1000, "x" * 8000]:
            with self.subTest(body=body[:20]):
                self.event["release"]["body"] = body
                publish(self.event, self.webhook)
                description = self.payload()["embeds"][0]["description"]
                self.assertLessEqual(len(description), 4096)
                self.assertTrue(description.endswith(f"[Read the full changelog]({self.url})"))

    def test_empty_notes_still_link_to_the_release(self):
        for body in [None, "", "  \n"]:
            with self.subTest(body=body):
                self.event["release"]["body"] = body
                publish(self.event, self.webhook)
                self.assertEqual(self.payload()["embeds"][0]["description"], f"[Read the changelog]({self.url})")

    def test_skips_drafts_prereleases_tooling_releases_and_edits(self):
        for field, value in [("draft", True), ("prerelease", True), ("tag_name", "ghostty-vt-abc123"),
                             ("tag_name", "v1.2.3-beta.1"), ("action", "edited")]:
            with self.subTest(field=field):
                target = self.event if field == "action" else self.event["release"]
                original = target[field]
                target[field] = value
                publish(self.event, "")
                target[field] = original
        self.urlopen.assert_not_called()

    def test_missing_webhook_fails_before_posting(self):
        with self.assertRaisesRegex(RuntimeError, "Set DISCORD_WEBHOOK_URL"):
            publish(self.event, "")
        self.urlopen.assert_not_called()

    def test_http_and_network_failures_do_not_expose_the_webhook(self):
        for error in [HTTPError(self.webhook, 429, "Rate limited", {}, None),
                      URLError(self.webhook), TimeoutError(self.webhook), ValueError(self.webhook)]:
            with self.subTest(error=type(error).__name__):
                self.urlopen.side_effect = error
                with self.assertRaises(RuntimeError) as raised:
                    publish(self.event, self.webhook)
                self.assertNotIn(self.webhook, str(raised.exception))
                if isinstance(error, HTTPError):
                    self.assertIn("HTTP 429", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
