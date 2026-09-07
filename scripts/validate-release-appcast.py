#!/usr/bin/env python3
from __future__ import annotations

import argparse
import xml.etree.ElementTree as ElementTree
from pathlib import Path


SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast", type=Path)
    parser.add_argument("repository")
    parser.add_argument("release_tag")
    parser.add_argument("dmg_name")
    parser.add_argument("sparkle_channel")
    arguments = parser.parse_args()

    root = ElementTree.parse(arguments.appcast).getroot()
    channel = root.find("./channel")
    if channel is None:
        raise SystemExit("Generated appcast is missing its channel")

    channel_link = (channel.findtext("link") or "").strip()
    if channel_link != "https://www.semper.systems/":
        raise SystemExit(
            f"Expected appcast channel link 'https://www.semper.systems/', found {channel_link!r}"
        )

    expected_url = (
        f"https://github.com/{arguments.repository}/releases/download/"
        f"{arguments.release_tag}/{arguments.dmg_name}"
    )
    matches = []
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        if enclosure is not None and enclosure.get("url") == expected_url:
            matches.append((item, enclosure))

    if len(matches) != 1:
        raise SystemExit(
            f"Expected one appcast item for {expected_url}, found {len(matches)}"
        )

    item, enclosure = matches[0]
    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        raise SystemExit("Generated appcast item is missing an Ed25519 signature")
    if not enclosure.get("length"):
        raise SystemExit("Generated appcast item is missing its file length")

    channel_element = item.find(f"{{{SPARKLE_NAMESPACE}}}channel")
    actual_channel = channel_element.text if channel_element is not None else ""
    if actual_channel != arguments.sparkle_channel:
        raise SystemExit(
            f"Expected Sparkle channel {arguments.sparkle_channel!r}, found {actual_channel!r}"
        )

    print(signature)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
