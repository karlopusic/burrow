#!/usr/bin/env python3
"""Prepend one generated Sparkle item while retaining older release entries."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

feed_path, generated_path, version = map(str, sys.argv[1:4])
feed = ET.parse(feed_path)
generated = ET.parse(generated_path)
channel = feed.getroot().find("channel")
new_channel = generated.getroot().find("channel")
if channel is None or new_channel is None:
    raise SystemExit("Invalid appcast channel")

matches = [item for item in new_channel.findall("item")
           if item.findtext(f"{{{SPARKLE}}}version") == version]
if len(matches) != 1:
    raise SystemExit(f"Expected one generated item for {version}, found {len(matches)}")
item = matches[0]
enclosure = item.find("enclosure")
expected = f"/releases/download/v{version}/StorageBox-Sync-{version}.dmg"
if enclosure is None or expected not in enclosure.get("url", "") or not enclosure.get(f"{{{SPARKLE}}}edSignature"):
    raise SystemExit("Generated item has an unexpected URL or no EdDSA signature")

for old in list(channel.findall("item")):
    if old.findtext(f"{{{SPARKLE}}}version") == version:
        channel.remove(old)
channel.insert(3, item)
ET.indent(feed, space="  ")
feed.write(feed_path, encoding="utf-8", xml_declaration=True)
