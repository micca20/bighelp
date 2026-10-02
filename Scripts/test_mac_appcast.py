"""Tests for Scripts/mac_appcast.py, the Mac app's Sparkle feed.

    python3 Scripts/test_mac_appcast.py

Set SPARKLE_BIN to Sparkle's bin folder (sign_update) to also sign and verify a feed
with a throwaway key; release-mac.sh's DerivedData has it under
SourcePackages/artifacts/sparkle/Sparkle/bin.
"""
import base64
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
SIGNATURE = base64.b64encode(bytes(range(64))).decode()
DOWNLOAD = "https://github.com/promptclickrun/bighelp/releases/download/mac-v2.3.0-61/bighelp-2.3.0-61-mac.dmg"


def load():
    spec = importlib.util.spec_from_file_location("mac_appcast", ROOT / "Scripts/mac_appcast.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MacAppcastTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.appcast = load()

    def make(self, **changes):
        values = dict(
            version="2.3.0", build="61", length=60156830, signature=SIGNATURE,
            download_url=DOWNLOAD, notes="**Fixed**\n- Things.",
            minimum_system_version="14.0", pub_date="Thu, 01 Oct 2026 20:00:00 +0000",
        )
        values.update(changes)
        return self.appcast.appcast(**values)

    def test_item_has_what_sparkle_needs(self):
        item = ElementTree.fromstring(self.make()).find("channel/item")
        self.assertEqual(item.findtext(f"{SPARKLE}version"), "61")
        self.assertEqual(item.findtext(f"{SPARKLE}shortVersionString"), "2.3.0")
        self.assertEqual(item.findtext(f"{SPARKLE}minimumSystemVersion"), "14.0")
        self.assertEqual(item.findtext("title"), "bighelp 2.3.0 (61)")
        self.assertEqual(item.findtext("description"), "**Fixed**\n- Things.")
        # Sparkle shows HTML notes as raw tags in a Catalyst app; Markdown renders.
        self.assertEqual(item.find("description").get(f"{SPARKLE}format"), "markdown")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), DOWNLOAD)
        self.assertEqual(enclosure.get("length"), "60156830")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(f"{SPARKLE}edSignature"), SIGNATURE)

    def test_notes_survive_cdata_terminators_and_markup(self):
        notes = 'Use `a]]>b` & "quotes" <not a tag>\n\n- One\n- **Two**'
        item = ElementTree.fromstring(self.make(notes=notes)).find("channel/item")
        self.assertEqual(item.findtext("description"), notes)

    def test_rejects_unusable_input(self):
        for changes in [
            dict(download_url="http://example.com/bighelp.dmg"),
            dict(download_url="https://user:pass@example.com/bighelp.dmg"),
            dict(download_url="ftp://127.0.0.1/bighelp.dmg"),
            dict(build="61a"),
            dict(build="0"),
            dict(version="2"),
            dict(version="2.3.0-beta"),
            dict(minimum_system_version="Sonoma"),
            dict(signature="not base64"),
            dict(signature=base64.b64encode(b"short").decode()),
            dict(length=0),
            dict(notes="   "),
            dict(notes="x" * (300 * 1024)),
        ]:
            with self.subTest(changes=changes), self.assertRaises(self.appcast.AppcastError):
                self.make(**changes)

    def test_local_test_feeds_may_use_http_to_this_mac(self):
        for url in ["http://127.0.0.1:8471/bighelp.dmg", "http://localhost:8471/bighelp.dmg", "http://[::1]:8471/x.dmg"]:
            with self.subTest(url=url):
                enclosure = ElementTree.fromstring(self.make(download_url=url)).find("channel/item/enclosure")
                self.assertEqual(enclosure.get("url"), url)

    def test_command_line_writes_the_feed_with_the_disk_image_size(self):
        with tempfile.TemporaryDirectory(prefix="bighelp-appcast-") as folder:
            folder = Path(folder)
            dmg = folder / "bighelp-2.3.0-61-mac.dmg"
            dmg.write_bytes(b"\0" * 4321)
            notes = folder / "notes.md"
            notes.write_text("Hello")
            output = folder / "appcast.xml"
            self.run_cli(dmg, notes, output)
            enclosure = ElementTree.parse(output).find("channel/item/enclosure")
            self.assertEqual(enclosure.get("length"), "4321")
            self.assertEqual(sorted(p.name for p in folder.iterdir()), ["appcast.xml", dmg.name, "notes.md"])

    def test_command_line_fails_without_writing(self):
        with tempfile.TemporaryDirectory(prefix="bighelp-appcast-") as folder:
            folder = Path(folder)
            dmg = folder / "bighelp.dmg"
            dmg.write_bytes(b"\0")
            notes = folder / "notes.md"
            notes.write_text("Hello")
            output = folder / "appcast.xml"
            result = self.run_cli(dmg, notes, output, signature="bad", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("signature", result.stderr)
            self.assertFalse(output.exists())

    @unittest.skipUnless(os.environ.get("SPARKLE_BIN"), "SPARKLE_BIN isn't set")
    def test_sparkle_signs_and_verifies_the_feed(self):
        sign_update = Path(os.environ["SPARKLE_BIN"]) / "sign_update"
        with tempfile.TemporaryDirectory(prefix="bighelp-appcast-") as folder:
            folder = Path(folder)
            key = folder / "throwaway.key"
            key.write_text(base64.b64encode(os.urandom(32)).decode())
            dmg = folder / "bighelp.dmg"
            dmg.write_bytes(os.urandom(2048))
            signature = subprocess.run([sign_update, "--ed-key-file", key, "-p", dmg], check=True,
                                       capture_output=True, text=True).stdout.strip()
            notes = folder / "notes.md"
            notes.write_text("Hello")
            output = folder / "appcast.xml"
            self.run_cli(dmg, notes, output, signature=signature)
            subprocess.run([sign_update, "--ed-key-file", key, output], check=True, capture_output=True)
            self.assertIn("sparkle-signatures", output.read_text())
            subprocess.run([sign_update, "--ed-key-file", key, "--verify", output], check=True, capture_output=True)
            subprocess.run([sign_update, "--ed-key-file", key, "--verify", dmg, signature], check=True,
                           capture_output=True)
            # A changed feed no longer verifies.
            output.write_text(output.read_text().replace("Hello", "Hullo"))
            changed = subprocess.run([sign_update, "--ed-key-file", key, "--verify", output], capture_output=True)
            self.assertNotEqual(changed.returncode, 0)

    def run_cli(self, dmg, notes, output, signature=SIGNATURE, check=True):
        return subprocess.run(
            ["python3", str(ROOT / "Scripts/mac_appcast.py"), "--version", "2.3.0", "--build", "61",
             "--dmg", str(dmg), "--signature", signature, "--download-url", DOWNLOAD,
             "--notes", str(notes), "--minimum-system-version", "14.0", "--output", str(output)],
            check=check, capture_output=True, text=True,
        )


if __name__ == "__main__":
    unittest.main()
