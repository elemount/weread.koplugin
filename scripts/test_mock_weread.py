#!/usr/bin/env python3
"""Check the offline native API mock; no KOReader or network account needed."""

import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

from mock_weread import BOOK_ID, MockServer


class MockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = MockServer(0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        cls.opener = build_opener(ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path, data=None, method=None):
        body = None if data is None else json.dumps(data).encode()
        request = Request(
            self.base + path,
            data=body,
            method=method or ("POST" if body is not None else "GET"),
            headers={"Content-Type": "application/json"},
        )
        try:
            response = self.opener.open(request, timeout=3)
        except HTTPError as exc:
            response = exc
        with response:
            body = response.read()
            if response.headers.get("Content-Type") == "application/json":
                body = json.loads(body)
            return response.status, body, response.headers

    def setUp(self):
        self.request("/__control", dict(delay=0, match="", status=503, times=0,
                                        empty_shelf=False, empty_annotations=False))

    def test_native_api_contracts(self):
        status, shelf, _ = self.request("/shelf/sync?synckey=0&lectureSynckey=0")
        self.assertEqual(status, 200)
        self.assertEqual(len(shelf["books"]), 26)

        status, book, _ = self.request(f"/book/info?bookId={BOOK_ID}")
        self.assertEqual(status, 200)
        self.assertEqual(book["bookId"], BOOK_ID)

        status, catalog, _ = self.request(
            "/book/chapterInfos", {"bookIds": [BOOK_ID], "synckeys": [0]}
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(catalog["data"][0]["updated"]), 6)

        query = urlencode({
            "bookId": BOOK_ID, "chapters": "1", "pf": "test", "pfkey": "test",
            "zoneId": "1", "bookVersion": 1, "bookType": "epub",
        })
        status, archive, headers = self.request("/book/chapterdownload?" + query)
        self.assertEqual(status, 200)
        self.assertTrue(archive.startswith(b"PK"))
        self.assertTrue(headers.get("EncryptKey"))

        status, marks, _ = self.request(
            f"/book/underlines?bookId={BOOK_ID}&chapterUid=2&synckey=0"
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(marks["underlines"]), 1)
        status, thoughts, _ = self.request(
            "/book/readreviews",
            {"bookId": BOOK_ID, "chapterUid": 2,
             "reviews": [{"range": marks["underlines"][0]["range"]}]},
        )
        self.assertEqual(status, 200)
        self.assertEqual(len(thoughts["reviews"]), 1)

        status, review, _ = self.request("/review/single?reviewId=mock-review-1")
        self.assertEqual(status, 200)
        self.assertEqual(review["reviewId"], "mock-review-1")
        self.assertEqual(len(review["comments"]), 2)

        status, progress, _ = self.request(f"/book/getProgress?bookId={BOOK_ID}")
        self.assertEqual(status, 200)
        self.assertEqual(progress["book"]["chapterUid"], 1)

    def test_empty_state_failure_control_and_validation(self):
        self.request("/__control", dict(empty_shelf=True, empty_annotations=True))
        self.assertEqual(self.request("/shelf/sync")[1]["books"], [])
        marks = self.request(f"/book/underlines?bookId={BOOK_ID}&chapterUid=1")[1]
        self.assertEqual(marks["underlines"], [])

        self.request("/__control", dict(match="/book/info", status=503, times=1))
        self.assertEqual(self.request(f"/book/info?bookId={BOOK_ID}")[0], 503)
        self.assertEqual(self.request(f"/book/info?bookId={BOOK_ID}")[0], 200)
        self.assertEqual(self.request("/unknown")[0], 501)
        self.assertEqual(self.request("/book/info?bookId=unknown")[0], 400)
        self.assertEqual(self.request("/book/underlines?chapterUid=1")[0], 400)
        self.assertEqual(self.request(
            "/book/chapterInfos", {"bookIds": ["unknown"], "synckeys": [0]}
        )[0], 400)
        self.assertEqual(self.request(
            "/book/chapterdownload?bookId=unknown&chapters=bad"
        )[0], 400)


if __name__ == "__main__":
    unittest.main()
