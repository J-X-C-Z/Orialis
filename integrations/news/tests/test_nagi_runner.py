import unittest
from integrations.news.nagi_runner import build_ssh_args


class NagiRunnerTests(unittest.TestCase):
    def args(self, **extra):
        return build_ssh_args(host="test-host", remote_port=45678, proxy_host="127.0.0.1", proxy_port=7890, codex_path="/home/test/codex", **extra)

    def test_default_preserves_remote_model_configuration(self):
        self.assertNotIn("--model", self.args()[-1])
        self.assertIn("--sandbox read-only", self.args()[-1])

    def test_explicit_model_override_is_preserved(self):
        self.assertIn("--model custom-model", self.args(model="custom-model")[-1])
