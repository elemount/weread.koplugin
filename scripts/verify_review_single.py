#!/usr/bin/env python3
"""Check the native WeRead review detail endpoint without logging response text.

Set ``WEREAD_VID`` and ``WEREAD_ACCESS_TOKEN`` in the environment. The script
does not read KOReader settings or print credentials, comments, or review text.
"""

import argparse
import os
import sys

import requests


BASE_URL = "https://i.weread.qq.com/review/single"
REFERER = "https://weread.qq.com/"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review-id", required=True)
    parser.add_argument("--comments-count", type=int, default=20)
    args = parser.parse_args()
    vid = os.environ.get("WEREAD_VID", "")
    access_token = os.environ.get("WEREAD_ACCESS_TOKEN", "")
    if not vid or not access_token:
        parser.error("set WEREAD_VID and WEREAD_ACCESS_TOKEN")

    response = requests.get(
        BASE_URL,
        params={
            "reviewId": args.review_id,
            "commentsCount": args.comments_count,
            "commentsDirection": 0,
            "bookReviewCount": 0,
            "likesCount": 0,
            "likesDirection": 0,
            "synckey": 0,
        },
        headers={
            "Accept": "application/json, text/plain, */*",
            "Referer": REFERER,
            "vid": vid,
            "accessToken": access_token,
        },
        timeout=30,
    )
    print(f"HTTP status: {response.status_code}")
    response.raise_for_status()
    result = response.json()
    if not isinstance(result, dict):
        raise RuntimeError("Native endpoint returned a non-object response")
    comments = result.get("comments") or []
    print(f"Review ID present: {bool(result.get('reviewId'))}")
    print(f"Comment count: {len(comments) if isinstance(comments, list) else 'invalid'}")
    print("Response text and credentials were not printed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (requests.RequestException, ValueError, RuntimeError) as exc:
        print(f"Verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
