import argparse
import io
import os
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

from scripts import news_sources


class RefreshTests(unittest.TestCase):
    def args(self, mode="aihot"):
        return argparse.Namespace(refresh=mode, dry_run=False, base_url="http://publisher/api/v1/news", publisher_token="test-token", publisher_user_id="user-1", github_token=None)

    def test_aihot_partial_failure_does_not_discard_healthy_articles(self):
        def request(url):
            if url.endswith("hot-topics"):
                raise news_sources.SourceError("hot unavailable")
            return {"items": [{"id": "article-1", "title": "source headline"}]}, {}
        with patch.object(news_sources, "_json", side_effect=request):
            result = news_sources.fetch_aihot(set())
        datasets = dict(result["datasets"])
        self.assertEqual(datasets["hot"]["sourceError"], "hot unavailable")
        self.assertEqual(datasets["items"][0]["id"], "article-1")

    def test_empty_and_malformed_aihot_lists_preserve_existing_cache(self):
        for payload in ({"items": []}, {"message": "maintenance"}, {"items": [None]}):
            with self.subTest(payload=payload), patch.object(news_sources, "_json", return_value=(payload, {})):
                result = news_sources.fetch_aihot(set())
            self.assertTrue(all(isinstance(data, dict) and data.get("sourceError") for _, data in result["datasets"]))

    def test_all_channels_run_after_one_source_failure_and_exit_failed(self):
        result = {"datasets": [("hot", {"sourceError": "hot unavailable"}), ("items", [{"id": "article-1"}])], "events": [], "eventErrors": []}
        with patch.object(news_sources, "_load_state", return_value={}), patch.object(news_sources, "fetch_aihot", return_value=result), patch.object(news_sources, "fetch_github", return_value=[{"repository": "owner/repo"}]) as github, patch.object(news_sources, "_publish_or_print", return_value={"taskId": "run-1", "status": "succeeded"}) as publish, patch.object(news_sources, "_record_failure") as failure, redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(news_sources.SourceError, "hot unavailable"):
                news_sources.run_refresh(self.args("all"))
        self.assertEqual([call.args[0] for call in github.call_args_list], ["daily", "weekly"])
        self.assertEqual([call.args[1] for call in publish.call_args_list], ["/publish/aihot/items", "/publish/github/daily", "/publish/github/weekly"])
        self.assertEqual(failure.call_args.args[2], ["aihot:hot"])

    def test_failed_audit_does_not_block_other_datasets(self):
        with patch.object(news_sources, "publish", side_effect=news_sources.SourceError("publisher unavailable")), redirect_stderr(io.StringIO()) as output:
            news_sources._record_failure(self.args(), "aihot.news", ["aihot:hot"], "source unavailable")
        self.assertIn("auditError", output.getvalue())

    def test_publisher_user_environment_matches_pipeline(self):
        with patch.dict(os.environ, {"ORIALIS_NEWS_PUBLISHER_TOKEN": "test-token", "ORIALIS_NEWS_PUBLISHER_USER_ID": "user-new", "ORIALIS_AGENT_USER_ID": "user-old"}), patch.object(news_sources, "run_refresh") as run:
            self.assertEqual(news_sources.main(["--refresh", "aihot"]), 0)
        self.assertEqual(run.call_args.args[0].publisher_user_id, "user-new")


if __name__ == "__main__":
    unittest.main()
