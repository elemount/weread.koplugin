# Native API mock

The local mock serves synthetic data at the native WeRead API paths used by
the plugin. It never forwards requests upstream and rejects unknown paths.

## Offline contract check

```bash
python3 scripts/test_mock_weread.py
```

The check covers shelf, book info, chapter catalog and download, progress,
reviews, underlines, thoughts, injected failures, and malformed requests. Its
chapter archive fixture uses mock-only credentials and synthetic text.

## Isolated KOReader run

Use a built KOReader runtime and a new run directory each time:

```bash
python3 scripts/mock_weread.py --koreader /path/to/koreader-runtime \
  --run-dir /tmp/weread-mock-run --port 8765
```

Open KOReader with the generated isolated profile. The launcher installs the
candidate plugin into that profile and enables the mock environment there. It
does not read or change the regular KOReader profile. On startup, the plugin
requests the mock's native `/shelf/sync`, then its book info, chapter catalog,
and `/book/chapterdownload` endpoints. A successfully downloaded chapter can
be opened in the real KOReader reader; whole-book caching exercises repeated
chapter downloads.

The mock also supports `/book/getProgress`, `/review/list`, `/review/single`,
`/book/underlines`, `/book/readreviews`, `/store/search`, and static cover
resources. Chapter illustrations are bundled in the native chapter archive.
QR login and update checks are not simulated.

## Failure controls

The control endpoint accepts a JSON patch:

```bash
curl -X POST http://127.0.0.1:8765/__control \
  -H 'Content-Type: application/json' \
  -d '{"match":"/book/chapterdownload","delay":2,"times":-1}'
```

Fields include `match` (native path substring), `delay` (0–60 seconds),
`times` (`-1` for every match), `status` (HTTP error status), `empty_shelf`,
and `empty_annotations`. `GET /__state` returns request metadata and current
controls without recording credentials or response contents.

To exercise the annotation UI flow in a real KOReader build, start the isolated
launcher and run `spec/koreader/weread_annotations_mock.lua` as described in
[`macos-release-testing.md`](macos-release-testing.md).
