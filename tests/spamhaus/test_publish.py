import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / "kubernetes/apps/network/spamhaus/app/publish.py"
spec = importlib.util.spec_from_file_location("spamhaus_publish", SCRIPT)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def feed(cidr: str) -> bytes:
    return (json.dumps({"cidr": cidr}) + "\n" + json.dumps({"type": "metadata", "records": 1}) + "\n").encode()


class Response:
    def __init__(self, body: bytes):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self, size):
        return self.body


class PublisherTests(unittest.TestCase):
    def test_rejects_truncated_and_wrong_family(self):
        with self.assertRaises(ValueError):
            publisher.convert(b'{"cidr":"8.8.8.0/24"}\n', 4)
        with self.assertRaises(ValueError):
            publisher.convert(
                b'{"cidr":"8.8.8.0/24"}\n{"type":"metadata","records":2}\n', 4
            )
        with self.assertRaises(ValueError):
            publisher.convert(feed("8.8.8.0/24"), 6)
        with self.assertRaises(ValueError):
            publisher.convert(feed("0.0.0.0/0"), 4)
        with self.assertRaises(ValueError):
            publisher.convert(feed("::/0"), 6)

    def test_failed_refresh_keeps_previous_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(publisher, "ROOT", Path(directory)):
                with patch.object(publisher, "urlopen", side_effect=[Response(feed("8.8.8.0/24")), Response(feed("2606:4700::/32"))]):
                    publisher.publish()
                original = (Path(directory) / "current").resolve()
                with patch.object(publisher, "urlopen", side_effect=[Response(feed("1.1.1.0/24")), Response(b"bad")]):
                    with self.assertRaises(ValueError):
                        publisher.publish()
                self.assertEqual((Path(directory) / "current").resolve(), original)
                self.assertEqual((original / "drop_v4.txt").read_text(), "8.8.8.0/24\n")

    def test_failed_atomic_switch_keeps_both_previous_lists(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(publisher, "ROOT", Path(directory)):
                original_feeds = [Response(feed("8.8.8.0/24")), Response(feed("2606:4700::/32"))]
                with patch.object(publisher, "urlopen", side_effect=original_feeds):
                    publisher.publish()
                current = Path(directory) / "current"
                original = current.resolve()
                replacement_feeds = [Response(feed("1.1.1.0/24")), Response(feed("2001:4860::/32"))]
                with patch.object(publisher, "urlopen", side_effect=replacement_feeds):
                    with patch.object(publisher.os, "replace", side_effect=OSError("simulated failure")):
                        with self.assertRaises(OSError):
                            publisher.publish()
                self.assertEqual(current.resolve(), original)
                self.assertEqual((current / "drop_v4.txt").read_text(), "8.8.8.0/24\n")
                self.assertEqual((current / "drop_v6.txt").read_text(), "2606:4700::/32\n")


if __name__ == "__main__":
    unittest.main()
