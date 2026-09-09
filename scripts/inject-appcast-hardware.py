#!/usr/bin/env python3
"""Insert sparkle:hardwareRequirements without rewriting the rest of an appcast."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ITEM_RE = re.compile(r"(<item\b[^>]*>)(.*?)(</item>)", re.DOTALL)
ENCLOSURE_RE = re.compile(r"<enclosure\b[^>]*\burl=\"([^\"]*)\"[^>]*/?>")
HARDWARE_RE = re.compile(
    r"(<sparkle:hardwareRequirements>)(.*?)(</sparkle:hardwareRequirements>)",
    re.DOTALL,
)


def required_architecture(url: str) -> str | None:
    if "-arm64.dmg" in url:
        return "arm64"
    if "-x86_64.dmg" in url:
        return "x86_64"
    return None


def inject_item(prefix: str, body: str, suffix: str) -> str:
    enclosure = ENCLOSURE_RE.search(body)
    if enclosure is None:
        return prefix + body + suffix

    required = required_architecture(enclosure.group(1))
    if required is None:
        return prefix + body + suffix

    if HARDWARE_RE.search(body):
        body = HARDWARE_RE.sub(rf"\g<1>{required}\g<3>", body, count=1)
        return prefix + body + suffix

    start = enclosure.start()
    line_start = body.rfind("\n", 0, start) + 1
    indent = body[line_start:start]
    tag = f"{indent}<sparkle:hardwareRequirements>{required}</sparkle:hardwareRequirements>\n"
    body = body[:start] + tag + body[start:]
    return prefix + body + suffix


def inject_hardware_requirements(xml: str) -> str:
    return ITEM_RE.sub(lambda match: inject_item(*match.groups()), xml)


def inject_file(path: Path) -> None:
    original = path.read_text(encoding="utf-8")
    updated = inject_hardware_requirements(original)
    if updated != original:
        path.write_text(updated, encoding="utf-8")


def _self_test() -> None:
    sample = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <title>arm</title>
            <sparkle:shortVersionString>0.1.11</sparkle:shortVersionString>
            <description sparkle:format="markdown"><![CDATA[# Keep CDATA
]]></description>
            <enclosure url="https://example.com/releases/download/v0.1.11/Tunnelful-0.1.11-arm64.dmg" sparkle:edSignature="keep+signature/" length="12" type="application/octet-stream" />
        </item>
        <item>
            <title>intel</title>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="https://example.com/releases/download/v0.1.11/Tunnelful-0.1.11-x86_64.dmg" sparkle:edSignature="intel-signature" />
        </item>
    </channel>
</rss>
"""
    once = inject_hardware_requirements(sample)
    twice = inject_hardware_requirements(once)

    assert "standalone=\"yes\"" in once
    assert "<![CDATA[# Keep CDATA\n]]>" in once
    assert 'sparkle:edSignature="keep+signature/"' in once
    assert once.count("<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>") == 1
    assert once.count("<sparkle:hardwareRequirements>x86_64</sparkle:hardwareRequirements>") == 1
    assert "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n            <enclosure url=\"https://example.com/releases/download/v0.1.11/Tunnelful-0.1.11-x86_64.dmg\"" not in once
    assert twice == once


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appcast", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        _self_test()
        return 0
    if args.appcast is None:
        parser.error("appcast path is required unless --self-test is set")
    inject_file(args.appcast)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
