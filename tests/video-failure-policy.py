"""Regression: disconnect recovery must not recreate an invisible Mac desktop."""
import importlib.machinery
import importlib.util
from pathlib import Path
import unittest

loader = importlib.machinery.SourceFileLoader('handoff', str(Path(__file__).resolve().parents[1] / 'display-handoff'))
spec = importlib.util.spec_from_loader(loader.name, loader)
handoff = importlib.util.module_from_spec(spec)
loader.exec_module(handoff)

class VideoFailurePolicy(unittest.TestCase):
    def setUp(self):
        self.request = {'target': 'windows', 'id': 'ABC'}
        self.state = {'command': 'abc', 'mode': 'mac', 'error': 'device disconnected'}

    def test_disconnect_keeps_video_layout(self):
        self.assertTrue(handoff.preserve_video_on_input_failure('mac', self.request, self.state))

    def test_explicit_mac_request_is_allowed(self):
        self.assertFalse(handoff.preserve_video_on_input_failure('mac', dict(self.request, target='mac'), self.state))

    def test_external_keyboard_return_shortcut_is_allowed(self):
        self.assertFalse(handoff.preserve_video_on_input_failure('mac', self.request, dict(self.state, error='')))

    def test_different_request_or_direction_is_not_matched(self):
        self.assertFalse(handoff.preserve_video_on_input_failure('mac', self.request, dict(self.state, command='different')))
        self.assertFalse(handoff.preserve_video_on_input_failure('windows', self.request, self.state))

if __name__ == '__main__':
    unittest.main()
