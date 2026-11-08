// Generated from docs/SCHEMA.md. Keep the two in sync.
enum SchemaDoc {
    static let markdown = #"""
# Comic Reader data format (schema 1)

Comic Reader keeps all of its own data as plain files in its iCloud Drive folder
(`iCloud Drive/Comic Reader/`). Comic files themselves are never modified. Any app,
on any platform, may read and write these files by following the rules below.

## Layout

```
Comic Reader/
  SCHEMA.md                         this file
  Libraries/<libraryId>/
    library.json                    which library folder this data belongs to
    books/<bookId>.json             one record per book
    covers/<bookId>.jpg             default cover (first page, about 1200 px tall)
    covers/<bookId>.custom.jpg      cover edited by the user, if any
```

## library.json

```json
{ "schema": 1, "libraryId": "UUID", "folderName": "Booklover", "createdAt": "2026-11-08T02:00:00.000Z" }
```

`folderName` is the name of the folder the user chose as their library. A device that
picks a folder with the same name uses the same `libraryId`.

## books/<bookId>.json

```json
{
  "schema": 1,
  "bookId": "UUID",
  "file": { "path": "Saga/Saga 001.cbz", "size": 48213377, "modified": "2026-10-02T18:11:04.000Z", "fingerprint": null },
  "metadata": { "series": "Saga", "number": "1", "title": null, "writers": [], "year": 2012, "updatedAt": "..." },
  "tags": { "value": ["sci-fi"], "updatedAt": "..." },
  "cover": { "page": 0, "crop": [0.02, 0.0, 0.96, 1.0], "rotation": 0, "updatedAt": "..." },
  "readerSettings": { "direction": "rtl", "layout": "auto", "updatedAt": "..." },
  "progress": {
    "apple-7a2c91d0": { "page": 14, "pageCount": 24, "finished": false, "updatedAt": "..." }
  }
}
```

- `file.path` is relative to the library folder and uses `/`.
- `page` values are zero-based.
- `crop` is `[x, y, width, height]` as fractions of the page; `rotation` is degrees clockwise.
- `direction` is `ltr` or `rtl`; `layout` is `auto`, `single` or `double`.
- Dates are ISO 8601 in UTC; writers should include milliseconds.
- Groups that have never been set are left out.

## Merge rules

Two devices may change the same record at the same time. When two copies differ
(for example an iCloud conflict copy), merge them like this:

1. For `metadata`, `tags`, `cover` and `readerSettings`, keep whichever copy has the later `updatedAt`.
2. For `progress`, keep every device key; for a key in both copies, keep the later `updatedAt`.
3. Write files atomically (write a temporary file, then rename over the original).

When opening a book, resume from the `progress` entry with the latest `updatedAt`.

## Versioning

`schema` is incremented only for changes that older readers cannot ignore. Readers
should ignore keys they do not know.
"""#
}
