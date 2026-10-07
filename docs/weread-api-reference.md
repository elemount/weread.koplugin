# WeRead native API reference

The plugin sends book data requests to the native service used by the WeRead
e-ink APK. It does not use the WeRead Skill gateway or the Web Reader endpoints
for book data.

## Host and authentication

```text
https://i.weread.qq.com
```

Authenticated requests carry the QR login credentials in headers:

```text
vid: <account vid>
accessToken: <account access token>
```

The plugin stores these values in a dedicated auth record and adds them through
`Client:native_headers`. The `/login` response's `refreshToken` is persisted
alongside them. The shared HTTP transport strips Cookie headers and ignores
Set-Cookie responses. Login
uses the e-ink APK's `/wxticket` and `/login` endpoints with the WeChat DiffDev
QR authorization flow.

`/wxticket` and `/login` are login bootstrap endpoints and can be called before
the account credentials exist. All book data endpoints use the authenticated
headers above.

## Current native endpoints

| Purpose | Method and path | Client method |
| --- | --- | --- |
| WeChat QR ticket | `GET /wxticket?nonceStr=…` | `get_wechat_login_ticket` |
| Complete QR login | `POST /login` | `login_with_wechat_code` |
| Refresh credentials | `POST /login` | `refresh_native_auth` |
| Shelf | `GET /shelf/sync` | `get_shelf` |
| Book metadata | `GET /book/info?bookId=…` | `get_book_info` |
| Book reviews | `GET /review/list` | `get_book_reviews` |
| Reading progress | `GET /book/getProgress?bookId=…` | `get_progress` |
| Chapter catalog | `POST /book/chapterInfos` | `get_chapter_infos` |
| Book search | `GET /store/search` | `search_books` |
| Chapter underlines | `GET /book/underlines` | `get_chapter_underlines` |
| Chapter thoughts | `POST /book/readreviews` | `get_chapter_reviews_batch` |
| Review and comments | `GET /review/single` | `get_review_comments` |
| Chapter body | `GET /book/chapterdownload` | `NativeChapter.fetch` |

The JSON methods and request headers live in
[`weread/lib/client.lua`](../weread/lib/client.lua). The binary chapter flow
lives in [`weread/lib/native_chapter.lua`](../weread/lib/native_chapter.lua).
The chapter catalog also supplies a `tar` URL for EPUB image resources. The
e-ink APK downloads that TAR from `res.weread.qq.com`, then keys each member by
its basename under `https://res.weread.qq.com/wrepub/`. The plugin bundles those
image members into generated EPUBs and rewrites matching XHTML image URLs to
local EPUB paths.

## Chapter download

`/book/chapterdownload` returns an archive rather than JSON. The request
identifies one book and one chapter and includes the APK-style `pf`, `pfkey`,
`zoneId`, book version, and book type parameters.

For EPUB books, the response includes an `encryptkey` header. The chapter
module decodes that value, decrypts the ZIP password using an AES-128-CBC key
derived from the account `vid`, extracts the requested XHTML and its assets,
and reverses the book-specific byte transform where needed. TXT chapters use
the TAR response path.

The downloader requests a chapter when the user opens it or when the enabled
next-chapter prefetch runs. Whole-book caching is implemented by iterating the
chapter catalog and downloading each chapter through this same endpoint.

## QR login transport

The plugin requests a one-time WeChat signature from `GET /wxticket`, then
uses the WeChat DiffDev OAuth endpoints `open.weixin.qq.com/connect/sdk/qrconnect`
and `long.open.weixin.qq.com/connect/l/qrconnect` to display and poll the QR
code. After WeChat returns an authorization code, the plugin posts it to
`POST /login` on `i.weread.qq.com` and stores the returned `vid`, `accessToken`,
and `refreshToken`. When an authenticated API returns session-expired error
`-2012`, the plugin posts the APK-compatible refresh payload to `/login`, stores
the rotated credentials, and retries the original request once. It does not
call the Web Reader's `/api/auth/*` or `/web/confirm` endpoints.

## Non-API resource URLs

Book covers use the static resource URL returned by the native shelf or book
metadata response; the APK also loads covers from those URLs. Chapter images
come from the native chapter archive. Static cover resources are requested
without account credentials and are not reading API calls. Plugin update
checks use GitHub's release API and are unrelated to WeRead.
