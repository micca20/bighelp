#!/usr/bin/env python3
"""Write the Sparkle appcast for one bighelp for Mac release.

    python3 Scripts/mac_appcast.py --version 2.3.0 --build 61 --dmg bighelp-2.3.0-61-mac.dmg \
        --signature <sign_update -p output> --download-url <the DMG's release asset URL> \
        --notes notes.md --minimum-system-version 14.0 --output appcast.xml

The app reads the newest public release's appcast.xml (Info.plist SUFeedURL), so the feed
holds just this release. The release notes go in the item's description as Markdown: Sparkle
shows HTML notes as raw tags in a Catalyst app. Sign the written file with Sparkle's
sign_update afterwards; the app refuses an unsigned feed. Scripts/release-mac.sh runs this.
"""
import argparse
import base64
import email.utils
import ipaddress
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlsplit
from xml.etree import ElementTree
from xml.sax.saxutils import escape, quoteattr

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
RELEASES = "https://github.com/promptclickrun/bighelp/releases"
MAX_NOTES_BYTES = 256 * 1024


class AppcastError(ValueError):
    pass


def checked_url(value, name):
    """HTTPS, or plain HTTP to this Mac (local update tests)."""
    if len(value) > 2048 or any(c.isspace() for c in value):
        raise AppcastError(f"{name} isn't a usable URL: {value!r}")
    parts = urlsplit(value)
    host = (parts.hostname or "").lower()
    if parts.username or parts.password or not host:
        raise AppcastError(f"{name} isn't a usable URL: {value!r}")
    if parts.scheme == "https":
        return value
    if parts.scheme == "http" and (host == "localhost" or _is_loopback(host)):
        return value
    raise AppcastError(f"{name} must use HTTPS: {value!r}")


def _is_loopback(host):
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def cdata(text):
    # "]]>" can't appear inside one CDATA section; split it across two.
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def appcast(*, version, build, length, signature, download_url, notes,
            minimum_system_version, pub_date, release_url=None):
    if not re.fullmatch(r"\d+(\.\d+){1,3}", version):
        raise AppcastError(f"Version must look like 2.3.0: {version!r}")
    if not re.fullmatch(r"[1-9]\d{0,8}", build):
        raise AppcastError(f"Build must be a whole number: {build!r}")
    if not re.fullmatch(r"\d+(\.\d+){1,2}", minimum_system_version):
        raise AppcastError(f"Minimum macOS must look like 14.0: {minimum_system_version!r}")
    if not isinstance(length, int) or length <= 0:
        raise AppcastError("The disk image is empty.")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError
    except ValueError:
        raise AppcastError("The EdDSA signature isn't a 64-byte base64 value; pass sign_update -p output.")
    download_url = checked_url(download_url, "Download URL")
    release_url = checked_url(release_url or download_url, "Release URL")
    notes = notes.strip()
    if not notes:
        raise AppcastError("Release notes are empty.")
    if len(notes.encode()) > MAX_NOTES_BYTES:
        raise AppcastError("Release notes are too long for the update window.")

    title = f"bighelp {version} ({build})"
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>bighelp for Mac</title>
    <link>{RELEASES}</link>
    <description>Updates for bighelp for Mac.</description>
    <language>en</language>
    <item>
      <title>{escape(title)}</title>
      <link>{escape(release_url)}</link>
      <pubDate>{escape(pub_date)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum_system_version}</sparkle:minimumSystemVersion>
      <description sparkle:format="markdown">{cdata(notes)}</description>
      <enclosure url={quoteattr(download_url)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
"""
    ElementTree.fromstring(xml.encode())  # Well-formed, or nothing is written.
    return xml


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--release-url")
    parser.add_argument("--notes", required=True, help="Release notes, Markdown")
    parser.add_argument("--minimum-system-version", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        with open(args.notes, encoding="utf-8") as file:
            notes = file.read(MAX_NOTES_BYTES + 1)
        xml = appcast(
            version=args.version, build=args.build, length=os.path.getsize(args.dmg),
            signature=args.signature.strip(), download_url=args.download_url,
            release_url=args.release_url, notes=notes,
            minimum_system_version=args.minimum_system_version,
            pub_date=email.utils.format_datetime(datetime.now(timezone.utc)),
        )
    except (AppcastError, OSError) as error:
        sys.exit(f"mac_appcast: {error}")
    folder = os.path.dirname(os.path.abspath(args.output))
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=folder, delete=False) as temporary:
        temporary.write(xml)
    os.chmod(temporary.name, 0o644)
    os.replace(temporary.name, args.output)


if __name__ == "__main__":
    main()
