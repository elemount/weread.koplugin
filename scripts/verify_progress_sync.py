#!/usr/bin/env python3
"""Read a book's progress from the native WeRead API without printing it.

Set ``WEREAD_VID`` and ``WEREAD_ACCESS_TOKEN`` in the environment. This is a
read-only check; it does not read KOReader settings or upload progress.
"""

import argparse
import os
import sys

import requests


BASE_URL = "https://i.weread.qq.com/book/getProgress"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--book-id", required=True)
    args = parser.parse_args()
    vid = os.environ.get("WEREAD_VID", "")
    access_token = os.environ.get("WEREAD_ACCESS_TOKEN", "")
    if not vid or not access_token:
        parser.error("set WEREAD_VID and WEREAD_ACCESS_TOKEN")

    response = requests.get(
        BASE_URL,
        params={"bookId": args.book_id},
        headers={
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://weread.qq.com/",
            "vid": vid,
            "accessToken": access_token,
        },
        timeout=30,
    )
    print(f"HTTP status: {response.status_code}")
    response.raise_for_status()
    result = response.json()
    if not isinstance(result, dict):
        raise RuntimeError("Native progress endpoint returned a non-object response")
    print(f"Top-level response keys: {', '.join(sorted(map(str, result.keys())))}")
    print("Progress values and credentials were not printed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (requests.RequestException, ValueError, RuntimeError) as exc:
        print(f"Progress request failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
