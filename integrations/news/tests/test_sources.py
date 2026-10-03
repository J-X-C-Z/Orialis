import unittest
from unittest.mock import patch

from scripts import news_sources


DAILY = '''<article class="card" data-full-name="acme/agent-kit">
<div class="rank-num">1</div><a class="repo-name" href="https://github.com/acme/agent-kit">acme/agent-kit</a>
<span class="lang">TypeScript</span><span class="gain-chip" aria-label="+1.4k today">+1.4k</span>
<h2 class="card-title"><a href="/repo/acme/agent-kit">代理工具包</a></h2>
<p class="card-desc">用于构建代理的工具集 &amp; SDK。</p><div class="topics"><span class="topic">agents</span><span class="topic">sdk</span></div></article>'''


class GithotSourceTests(unittest.TestCase):
    def test_parse_daily_card_preserves_chinese_source_copy_and_normalizes_gain(self):
        rows = news_sources.parse_githot_html(DAILY, "daily")

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["repository"], "acme/agent-kit")
        self.assertEqual(rows[0]["ranking"], 1)
        self.assertEqual(rows[0]["sourceTitle"], "代理工具包")
        self.assertEqual(rows[0]["sourceSummary"], "用于构建代理的工具集 & SDK。")
        self.assertEqual(rows[0]["sourceTopics"], ["agents", "sdk"])
        self.assertEqual(rows[0]["starsInPeriod"], 1400)
        self.assertEqual(rows[0]["source"], "githot.dev")
        self.assertEqual(rows[0]["sourceUrl"], "https://githot.dev/repo/acme/agent-kit")

    def test_weekly_fetch_uses_githot_weekly_and_native_detail(self):
        with patch.object(news_sources, "_request", return_value=(DAILY.encode(), {})) as request, patch.object(news_sources, "enrich_repository", side_effect=lambda row, token: row):
            rows = news_sources.fetch_github("weekly", None)

        self.assertEqual(request.call_args_list[0].args[0], "https://githot.dev/weekly")
        self.assertEqual(request.call_args_list[1].args[0], "https://githot.dev/repo/acme/agent-kit")
        self.assertEqual(rows[0]["period"], "weekly")

    def test_source_sections_keep_order_commands_and_exclude_personal_controls(self):
        document = '<section class="summary-hero"><h2>源标题</h2><p>源介绍</p></section><section class="summary-section"><h3>源自定义栏目</h3><ul><li><strong>要点</strong><span>原文</span></li></ul></section><section class="setup-section"><h3>快速试用</h3><code>$ echo a &amp;&amp; echo b</code><script>secret()</script><button>复制</button></section><section class="note"><textarea>私有备注</textarea></section><section class="history-card"><h2>上榜记录</h2><ol><li>2026-10-03 #1</li></ol></section>'
        content = news_sources.parse_githot_detail(document)
        self.assertLess(content.index('源标题'), content.index('源自定义栏目'))
        self.assertIn('**要点** 原文', content)
        self.assertIn('```\n$ echo a && echo b\n```', content)
        self.assertIn('上榜记录', content)
        self.assertNotIn('secret', content)
        self.assertNotIn('私有备注', content)
        self.assertNotIn('复制', content)
        self.assertNotIn('使用价值', content)

    def test_detail_failure_keeps_ranking_and_source_summary(self):
        with patch.object(news_sources, '_request', side_effect=[(DAILY.encode(), {}), news_sources.SourceError('offline')]), patch.object(news_sources, 'enrich_repository') as api:
            row = news_sources.fetch_github('daily', None)[0]
        self.assertEqual(row['sourceDetailStatus'], 'unavailable')
        self.assertEqual(row['sourceSummary'], '用于构建代理的工具集 & SDK。')
        api.assert_not_called()

    def test_github_readme_metadata_keeps_a_real_readme_url(self):
        item = {"repository": "acme/agent-kit"}
        repo = {
            "full_name": "acme/agent-kit",
            "html_url": "https://github.com/acme/agent-kit",
            "default_branch": "main",
        }
        release = {"tag_name": "v1", "html_url": "https://github.com/acme/agent-kit/releases/tag/v1"}
        with patch.object(news_sources, "_github_api", side_effect=[repo, release]), patch.object(news_sources, "_request", return_value=(b"# README", {})):
            result = news_sources.enrich_repository(item, None)

        self.assertEqual(result["readmeSource"], "https://raw.githubusercontent.com/acme/agent-kit/main/README.md")
        self.assertEqual(result["readme"], "# README")

    def test_rejects_unparseable_pages_and_invalid_periods(self):
        with self.assertRaises(news_sources.SourceError):
            news_sources.parse_githot_html("<html>empty</html>", "daily")
        with self.assertRaises(news_sources.SourceError):
            news_sources.parse_githot_html(DAILY, "monthly")


if __name__ == "__main__":
    unittest.main()
