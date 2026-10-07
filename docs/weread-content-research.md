# WeRead e-ink content API notes

The plugin uses the e-ink APK's native chapter download endpoint for book
content. Legacy Web Reader shard endpoints are not part of the active reading
flow.

## Endpoint and request shape

```text
GET https://i.weread.qq.com/book/chapterdownload
```

The request is authenticated with `vid` and `accessToken` headers and asks for
one chapter by `bookId` and chapter UID. APK-style platform and book format
parameters are assembled in [`native_chapter.lua`](../weread/lib/native_chapter.lua).

## EPUB response processing

The service returns binary archive data. The response's `encryptkey` header
contains a base64-encoded AES-CBC ciphertext. The plugin derives the 128-bit
AES key and IV from the account `vid`, decrypts the ZIP password, and opens the
chapter archive. It selects the XHTML associated with the requested chapter,
loads CSS and image resources, and reverses the book-specific XOR transform on
files that are encoded.

The chapter content is then converted into the plugin's reader document and
cached chapter by chapter. A whole-book download is a sequence of these
chapter requests, not a separate EPUB export endpoint.

## EPUB image resources

The e-ink APK gets EPUB images from the `tar` field on each chapter catalog
record. After chapter content has downloaded, it requests that TAR URL from
`res.weread.qq.com`, iterates its regular files, and stores each file as raw
bytes in the account's book image cache. Cache keys use
`https://res.weread.qq.com/wrepub/<member-basename>` plus the book ID. This
image path is separate from the encrypted chapter ZIP; the APK does not apply
the chapter byte transform to TAR members.

TXT books use the same endpoint with the TXT format and return a TAR archive.
The plugin selects the file named for the book and chapter from that archive.

## Other native book APIs

Shelf, metadata, chapter catalogs, progress, search, reviews, underlines, and
thoughts use direct native endpoints on `i.weread.qq.com`; there is no Agent
Gateway wrapper. See [`weread-api-reference.md`](weread-api-reference.md) for
the current endpoint inventory.

## Login

The e-ink APK obtains a one-time WeChat QR signature from `/wxticket`, uses the
WeChat DiffDev OAuth QR endpoints to request and poll a QR code, and sends the
returned authorization code to the native `/login` endpoint. The plugin follows
the same sequence and stores the resulting `vid` and `accessToken` for native
book API calls. It does not use the Web Reader QR endpoints.
