#!/usr/bin/env python3
"""Inspect an already downloaded EPUB for footnote markup without API calls."""

import argparse
import re
import sys
import zipfile


FOOTNOTE_RE = re.compile(rb"epub:type\s*=\s*['\"]footnote['\"]", re.IGNORECASE)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("epub", help="path to a locally cached EPUB")
    args = parser.parse_args()
    with zipfile.ZipFile(args.epub) as epub:
        chapters = [
            name for name in epub.namelist()
            if name.lower().endswith((".xhtml", ".html", ".htm"))
        ]
        footnote_chapters = 0
        footnotes = 0
        for name in chapters:
            body = epub.read(name)
            found = len(FOOTNOTE_RE.findall(body))
            if found:
                footnote_chapters += 1
                footnotes += found
    print(f"XHTML/HTML entries: {len(chapters)}")
    print(f"Chapters with footnotes: {footnote_chapters}")
    print(f"Footnote markers: {footnotes}")
    print("Book text was not printed.")
    return 0 if footnotes else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, zipfile.BadZipFile) as exc:
        print(f"EPUB inspection failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
