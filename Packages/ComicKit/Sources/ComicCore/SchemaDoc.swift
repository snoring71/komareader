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
  "flags": { "favorite": true, "bookmarked": false, "updatedAt": "..." },
  "readerSettings": { "direction": "rtl", "layout": "auto", "updatedAt": "..." },
  "progress": {
    "apple-7a2c91d0": { "page": 14, "pageCount": 24, "finished": false, "updatedAt": "..." }
  }
}
```

- `file.path` is relative to the library folder and uses `/`.
- `page` values are zero-based.
- Pages are numbered in this order, so that a page number means the same page in every app:
  entry paths are compared one folder name at a time; within a name, runs of ASCII digits
  compare as numbers ("2" before "10"); otherwise punctuation and spaces come before digits,
  and digits before letters ("_01.jpg" before "01.jpg" before "a.jpg"); case, full-width forms
  and accents are ignored. This is the order Windows Explorer and Finder show.
- `crop` is `[x, y, width, height]` as fractions of the page after `rotation` (degrees
  clockwise: 0, 90, 180 or 270) is applied. To re-render a cover: rotate the page, then crop.
  `covers/<bookId>.custom.jpg` holds the result. A `cover` of page 0, uncropped and not rotated
  means the user went back to the default cover; there is then no `.custom.jpg`.
- `flags` holds the user's Favorite and Bookmarked marks.
- `direction` is `ltr` or `rtl`; `layout` is `auto`, `single` or `double`.
- Dates are ISO 8601 in UTC; writers should include milliseconds.
- Groups that have never been set are left out.

## Ids

Two devices can meet the same library or book before iCloud has synced, so new ids are
worked out from names rather than picked at random:

- A new library's `libraryId` comes from its `folderName`.
- A book seen for the first time gets its `bookId` from its `file.path`. A book that moves
  keeps the id it already has.

The id is SHA-256 of the UTF-8 text `komareader:library:<folderName>` or
`komareader:book:<path>`, with the name in Unicode NFC. Take the first 16 bytes, set the high
nibble of byte 6 to `8` and the top two bits of byte 8 to `10` (an RFC 9562 version 8 UUID),
and write it as an upper-case UUID string. Ids made earlier at random stay valid.
For example, the folder `Booklover` gives `352A9655-843C-82E4-BDCC-9A7C0DA6E14A` and the path
`Saga/Saga 001.cbz` gives `D0E63AF5-7548-8B27-8544-DCCDDEB4C6FA`.

If two `library.json` files name the same folder, use the one whose `libraryId` is the
worked-out id, else the lowest `libraryId` (compared as text), and merge the other's records into it. If two
records in one library have the same `file.path` and do not disagree on `file.size`, keep the
record whose `bookId` is the worked-out id, else the lowest `bookId`, merge the other into it
(rules below) and delete the other.

## Merge rules

Two devices may change the same record at the same time. When two copies differ
(for example an iCloud conflict copy), merge them like this:

1. For `metadata`, `tags`, `cover`, `flags` and `readerSettings`, keep whichever copy has the later `updatedAt`.
2. For `progress`, keep every device key; for a key in both copies, keep the later `updatedAt`.
3. Write files atomically (write a temporary file, then rename over the original).

When opening a book, resume from the `progress` entry with the latest `updatedAt`.

## Versioning

`schema` is incremented only for changes that older readers cannot ignore. Readers
should ignore keys they do not know.
"""#
}
