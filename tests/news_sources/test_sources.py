import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import news_sources


class AihotNormalizationTests(unittest.TestCase):
    def test_hot_story_id_is_distinct_from_item_id_and_unknown_metrics_stay_empty(self):
        result = news_sources.normalize_aihot_hot({"items": [{
            "rank": 1,
            "id": "item-id-123",
            "title": "A real source headline",
            "source": {"name": "Source"},
            "links": {"aihot": "https://aihot.news/items/item-id-123", "story": "https://aihot.virxact.com/story/12345678-1234-1234-1234-123456789abc"},
            "sourceCount": 3,
            "signalCount": 8,
            "participantCount": 5,
            "sourceNames": ["Source"],
            "latestAt": "2026-10-02T12:00:00Z",
        }]})[0]
        self.assertEqual(result["id"], "12345678-1234-1234-1234-123456789abc")
        self.assertEqual(result["itemId"], "item-id-123")
        self.assertIsNone(result["heat"])
        self.assertIsNone(result["trend"])
        self.assertTrue(result["storyAvailable"])

    def test_story_id_rejects_wrong_host_and_missing_story(self):
        self.assertIsNone(news_sources.story_public_id("https://evil.example/story/12345678-1234-1234-1234-123456789abc"))
        self.assertIsNone(news_sources.story_public_id(None))

    def test_fetch_reuses_one_story_response_for_hot_card_and_event(self):
        story_id = "12345678-1234-1234-1234-123456789abc"
        hot = {"items": [
            {"id": "item-a", "rank": 1, "title": "A", "latestAt": "2026-10-02T10:00:00Z", "links": {"story": f"https://aihot.news/story/{story_id}"}},
            {"id": "item-b", "rank": 2, "title": "B", "latestAt": "2026-10-02T09:00:00Z", "links": {"story": f"https://aihot.news/story/{story_id}"}},
        ]}
        story = {"publicId": story_id, "status": "active", "latest": "AIHOT latest update", "digest": "AIHOT digest", "reports": [], "storyline": []}

        def fake_json(url):
            if url.endswith("/api/v1/hot-topics"):
                return hot, {}
            if "/api/v1/items?" in url:
                return {"items": []}, {}
            if f"/api/v1/stories/{story_id}" in url:
                return {"story": story}, {}
            self.fail(f"unexpected AIHOT request: {url}")

        with patch.object(news_sources, "_json", side_effect=fake_json) as request:
            result = news_sources.fetch_aihot(set())

        hot_rows = dict(result["datasets"])["hot"]
        self.assertEqual(request.call_count, 3)
        self.assertEqual([row["summary"] for row in hot_rows], ["AIHOT digest", "AIHOT digest"])
        self.assertEqual([row["status"] for row in hot_rows], ["active", "active"])
        self.assertEqual([row["latestUpdate"] for row in hot_rows], ["AIHOT latest update", "AIHOT latest update"])
        self.assertEqual(len(result["events"]), 1)
        self.assertEqual(result["events"][0]["publicId"], story_id)

    def test_story_failure_keeps_hot_source_fields_and_reports_detail_error(self):
        story_id = "12345678-1234-1234-1234-123456789abc"
        hot = {"items": [{"id": "item-a", "rank": 1, "title": "A", "latestAt": "2026-10-02T10:00:00Z", "links": {"story": f"https://aihot.news/story/{story_id}"}}]}

        def fake_json(url):
            if url.endswith("/api/v1/hot-topics"):
                return hot, {}
            if "/api/v1/items?" in url:
                return {"items": []}, {}
            if f"/api/v1/stories/{story_id}" in url:
                raise news_sources.SourceError("story unavailable")
            self.fail(f"unexpected AIHOT request: {url}")

        with patch.object(news_sources, "_json", side_effect=fake_json):
            result = news_sources.fetch_aihot(set())

        row = dict(result["datasets"])["hot"][0]
        self.assertEqual(row["itemId"], "item-a")
        self.assertEqual(row["latestUpdate"], "2026-10-02T10:00:00Z")
        self.assertIsNone(row["summary"])
        self.assertIsNone(row["status"])
        self.assertEqual(result["events"], [])
        self.assertEqual(result["eventErrors"], [{"storyId": story_id, "error": "story unavailable"}])


class GitHubTrendingTests(unittest.TestCase):
    def test_official_card_parser_keeps_daily_and_weekly_rank_and_metadata(self):
        html = '''
        <article class="Box-row"><h2><a href="/octo/one">one</a></h2>
        <p class="col-9 color-fg-muted my-1">A real description</p>
        <span itemprop="programmingLanguage">Rust</span><span>1,234 stars today</span></article>
        <article class="Box-row"><h2><a href="/octo/two">two</a></h2>
        <p class="col-9 color-fg-muted my-1">Weekly description</p>
        <span itemprop="programmingLanguage">Python</span><span>70 stars this week</span></article>
        '''
        daily = news_sources.parse_trending_html(html, "daily")
        weekly = news_sources.parse_trending_html(html, "weekly")
        self.assertEqual([row["repository"] for row in daily], ["octo/one", "octo/two"])
        self.assertEqual(daily[0]["starsInPeriod"], 1234)
        self.assertEqual(daily[0]["description"], "A real description")
        self.assertEqual(daily[0]["language"], "Rust")
        self.assertIsNone(daily[1]["starsInPeriod"])
        self.assertEqual(weekly[1]["starsInPeriod"], 70)
        self.assertEqual(weekly[0]["ranking"], 1)

    def test_source_request_rejects_private_and_non_https_hosts(self):
        with self.assertRaises(news_sources.SourceError):
            news_sources._request("http://127.0.0.1/latest")

    def test_empty_or_unrecognized_trending_page_fails_without_erasing_cache(self):
        with self.assertRaises(news_sources.SourceError):
            news_sources.parse_trending_html("<html><body>maintenance</body></html>", "daily")

    def test_metadata_failure_keeps_the_official_ranked_base_list(self):
        page = b'''<article class="Box-row"><h2><a href="/octo/one">one</a></h2>
        <p class="col-9 color-fg-muted">source description</p><span itemprop="programmingLanguage">Rust</span>
        <span>15 stars today</span></article>'''
        with patch.object(news_sources, "_request", return_value=(page, {})), patch.object(
            news_sources, "_github_api", side_effect=news_sources.SourceError("rate limited")
        ):
            rows = news_sources.fetch_github("daily", None)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["repository"], "octo/one")
        self.assertEqual(rows[0]["starsInPeriod"], 15)
        self.assertEqual(rows[0]["language"], "Rust")
        self.assertEqual(rows[0]["metadataError"], "rate limited")


if __name__ == "__main__":
    unittest.main()
