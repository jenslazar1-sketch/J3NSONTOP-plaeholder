# File Tools

Section `/files`. Six tools plus the terminal `hash` command, all local and
offline. Code: `lib/features/file_tools/` (pure logic in `domain/`, pages and
controllers in `presentation/`, the command in `commands/`). Tests:
`test/features/file_tools/`.

| Tool | Id | In one line |
| --- | --- | --- |
| Hash & Checksum | `files.hash` | Digests of text/files, compare, verify and create checksum lists |
| Duplicate Finder | `files.duplicates` | Identical files by size + SHA-256, reversible quarantine |
| Line Endings | `files.line_endings` | Count and convert LF / CRLF / CR, keeping the encoding |
| Whitespace Cleanup | `files.whitespace` | Trailing spaces, tabs, blank lines, final newline, BOM, invisible spaces |
| ZIP Studio | `files.zip` | Create archives; inspect and extract them safely |
| Log Viewer | `files.logs` | Big logs, severity filters, plain/regex search, selection export |

Common rules:

* Inputs come from the **active workspace** (in-app browser) or the **device**
  (system picker; the file is copied into app storage first). Device copies are
  never rewritten in place - their results are exported instead.
* Long work runs as a tracked operation (Activity panel) with real progress
  and a working **Cancel**.
* Nothing is overwritten silently: rewrites go through
  `WorkspaceFileWriter.replaceWithBackup` (backup to
  `<workspace meta>/backups/<yyyyMMdd-HHmmss>/<relative path>`, then an atomic
  replace); new files get a free name (`name (2).ext`).
* Folder scans never follow symbolic links (so link loops are impossible).
* Unfinished input (text, options, file lists, results) survives switching
  tools.

## Hash & Checksum (`files.hash`)

Algorithms: **SHA-256** (default), SHA-512, SHA-1 and MD5. SHA-1 and MD5 are
labelled *legacy* and badged "compatibility only - not collision resistant";
use them only to compare with published checksums.

* **Text** - UTF-8 bytes exactly as typed; the digest updates live.
* **Files** - add workspace files, a whole workspace folder (recursive, up to
  5 000 files) or device files. Files are streamed in chunks (never loaded
  whole) with overall progress by bytes and per-file progress. Unreadable
  files are listed as ERROR; the rest continue.
* **Expected digest** - paste a published value. Case, whitespace and an
  `algo:` prefix (`sha256:...`) are ignored. The result is shown as
  **MATCH** / **MISMATCH** (icon + text). If the pasted digest's length fits
  another algorithm, the tool offers to switch.
* **Verify list** - a checksum file (workspace or device) or pasted lines.
  Paths are resolved relative to the checksum file's folder by default (or a
  folder you pick; device copies default to the workspace root).
* **Generate** - after hashing files: *Copy* the lines, *Save / export...*
  (`saveOutput`), or *Save next to files*, which writes `SHA256SUMS`
  (`SHA512SUMS`, `SHA1SUMS`, `MD5SUMS`) into the common folder of the files
  (only when all files are in the workspace; an existing file is never
  replaced).

### Checksum file formats

Accepted when reading (one entry per line, `#` comments and blank lines
ignored, CRLF and a UTF-8 BOM accepted, hex in any case):

| Format | Example |
| --- | --- |
| GNU text mode | `9f86d0...  path/to/file.txt` (hash, two spaces, path) |
| GNU binary mode | `9f86d0... *path/to/file.bin` |
| GNU escaped name | `\9f86d0...  back\\slash\nnewline.txt` (leading `\`; `\\`, `\n`, `\r` escapes) |
| BSD / `--tag` | `SHA256 (path/to/file.txt) = 9f86d0...` (tags `MD5`, `SHA1`, `SHA256`, `SHA512`) |
| Lenient | `9f86d0... path` (single space) |

Names may contain spaces and any Unicode. Written files use GNU text mode,
forward slashes, paths relative to the checksum file's folder, **sorted by
path in code-unit order** (like `LC_ALL=C sort`) so output is identical
between runs and platforms, and end with a newline. They verify with
`sha256sum -c SHA256SUMS`.

Algorithm per line: the BSD tag, else the checksum file name (`SHA256SUMS`,
`*.sha512`, `md5sum.txt`...), else the digest length (32 MD5, 40 SHA-1, 64
SHA-256, 128 SHA-512). *Auto-detect* can be overridden.

Verification statuses: **OK**, **FAILED** (digest differs; expected and
actual are shown), **MISSING** (no such file), **INVALID** (absolute path,
`..`, a path through a symbolic link, a non-regular file, a digest length
that does not fit the algorithm - such files are never read). Unparseable
lines are listed separately. The report can be exported as text.

## Duplicate Finder (`files.duplicates`)

Scans a workspace folder (default: the root) recursively.

1. Walk with include/exclude globs and a minimum size (default: skip empty
   files). Symbolic links are skipped and counted.
2. Group by size; unique sizes are dropped without reading.
3. Hard links (same device + inode, detected with
   `FileSystemEntity.identical`) are collapsed - they share storage, so they
   are not duplicates.
4. Files over 256 KiB first compare a SHA-256 of their first 64 KiB.
5. Remaining candidates get a full streamed SHA-256.

Groups are sorted by reclaimable bytes (`size x (copies - 1)`). Limits:
200 000 files per scan (a notice says when results are partial).

**Keepers**: each group keeps one file (radio). The default rule is *Fewest
folders*, *Oldest*, *Newest* or *A - Z*; ties fall back to path order. Every
other copy is ticked for quarantine and can be unticked.

**Reports** (`saveOutput`): text, CSV (`group,sha256,size_bytes,role,path,modified_utc`,
roles `keep`/`quarantine`/`copy`) or JSON (`tool, folder, generatedAt, filter,
minSizeBytes, filesScanned, bytesScanned, hashedFiles, reclaimableBytes,
truncated, skippedLinks, hardLinks, groups[{group, sha256, sizeBytes,
reclaimableBytes, files[{path, role, modified}]}]`).

### Quarantine (never a permanent delete)

"Move selected copies to quarantine" moves files to

```
<workspace meta>/quarantine/<yyyyMMdd-HHmmss>/<path relative to the workspace>
<workspace meta>/quarantine/<yyyyMMdd-HHmmss>.json      <- journal
```

The workspace meta folder lives in app storage, so a linked game folder stays
clean. Before each move the copy **and its keeper** are re-checked (regular
file, same size, same SHA-256); a copy whose keeper is also selected, whose
keeper vanished or whose content changed is skipped with a reason. The
journal is written before the first move. Moves use rename; across volumes
the file is copied, the copy verified by SHA-256, and only then the original
removed.

Journal (`schema: j3nsontop.files.quarantine`, `version: 1`): `id`,
`createdAt`, `workspaceId`, `entries[{path, keeper, size, sha256, state,
restoredAs?, note?, at?}]` with `state` = `pending | quarantined | restored |
skipped | missing`.

**Undo / restore** ("Quarantine & undo"): restore a whole session or single
files. Restoring never overwrites - if the original path is occupied the file
comes back as `name (2).ext` and the journal records it. Empty quarantine
folders are removed afterwards; journals are kept as history. Paths are
recomputed from the journal's relative paths and validated, so a tampered
journal cannot restore outside the workspace.

## Line Endings (`files.line_endings`)

* **Text** - counts LF, CRLF and lone CR, flags *mixed*, previews the
  conversion (first 40 lines with visible `«LF»`, `«CRLF»`, `«CR»` markers)
  with before/after counts; copy or save the result.
* **Files** - chosen files, or a workspace folder with include/exclude globs.
  *Analyse* is a dry run listing per file: encoding, counts before -> after,
  and status (`WILL CHANGE`, `UNCHANGED`, `SKIPPED: BINARY`, `SKIPPED: TOO
  LARGE`, `SKIPPED: ENCODING`, `ERROR`, `DEVICE COPY`). *Convert files*
  (after a confirmation) rewrites changed workspace files with backups.
  Device copies get an export button instead.

Encoding preservation: files are decoded with `TextCodec` (UTF-8, UTF-8 with
BOM, UTF-16 LE/BE with BOM, Latin-1 fallback for invalid UTF-8) and written
back in the same encoding. A file is only touched if its original bytes
survive a decode/encode round trip exactly; otherwise it is skipped
(`SKIPPED: ENCODING`, e.g. a UTF-16 file with an odd byte count). So only the
terminators change, byte for byte.

Limits: 32 MiB per file (larger files are skipped and listed), 5 000 files
per batch, binaries detected with `TextCodec.looksBinary` are skipped.

## Whitespace Cleanup (`files.whitespace`)

Rules (each optional; applied in this order):

1. **Strip UTF-8 BOM** - text: removes a leading U+FEFF; files: UTF-8-with-BOM
   files are saved as plain UTF-8 (UTF-16 keeps its BOM - it defines the byte
   order).
2. **Fix special spaces** - NBSP (U+00A0), narrow NBSP (U+202F) and figure
   space (U+2007) become spaces; zero-width space (U+200B), word joiner
   (U+2060) and stray U+FEFF are removed. ZWJ/ZWNJ are kept (emoji and
   several scripts need them). Skipped for Latin-1-fallback files.
3. **Indentation** - keep, *tabs -> spaces* (leading indentation only unless
   "also expand tabs inside lines" is on, so TSV data survives; tab stops of
   the chosen width), or *leading spaces -> tabs* (remainder kept as spaces).
4. **Trim trailing whitespace** (spaces, tabs, form feeds).
5. **Collapse blank lines** to at most N (0 removes all).
6. **Exactly one final newline** - trailing blank lines removed, a missing
   last line break added (using the file's dominant line ending).
7. **Normalise line endings** (optional) - otherwise every line keeps its
   own ending.

Text mode shows a live preview: counts per rule, a line diff (`LineDiff`)
with changed lines and two lines of context, invisible characters shown as
`·` (trailing space), `→` (tab), `°` (no-break space), `¤` (zero-width).
Inputs over 262 144 characters are previewed on request. The preview diff's edit budget
scales with input size so memory stays bounded. Files mode works like Line
Endings (dry run, confirmation, backups, encoding preservation, same limits).

## ZIP Studio (`files.zip`)

All ZIP reading/writing goes through the hardened `SafeZip`.

**Create** - add workspace files (stored under their name), workspace folders
(stored under `<folder name>/...`, symbolic links skipped) or device files.
The entry list shows archive paths, sizes, origin and the total; entries whose
paths collide (case-insensitively) or are not portable are **BLOCKED** until
removed. Then either

* *Create in workspace* - written atomically into the chosen workspace folder
  (default: root); an existing archive is never replaced (`name (2).zip`), or
* *Create & export...* - built in the app's staging folder and handed to the
  save/share dialog (up to 256 MiB, because those APIs take the bytes in
  memory); the staging copy is deleted afterwards.

Progress is per entry; Cancel leaves no partial archive.

**Extract** - open a `.zip` or `.j3mod` (workspace or device). `SafeZip.inspect`
lists every entry (path, size, packed size, ratio, modified) before anything
is written. **BLOCKED** issues (fatal) disable extraction; warnings are shown.
Destination: a new folder named after the archive in the workspace root (made
unique if it exists), or any workspace folder. When files already exist:
*Skip (keep mine)* (default), *Stop with an error*, or *Overwrite* - which
needs a danger confirmation and first backs up every file it will replace to
`<workspace meta>/backups/<yyyyMMdd-HHmmss>-unzip/`. Progress by bytes with
Cancel (files written before cancelling are kept and reported).

Extraction limits (`ZipLimits.standard`):

| Limit | Value |
| --- | --- |
| Entries | 20 000 |
| One file, unpacked | 512 MB |
| All files, unpacked | 2 GB |
| Path length | 400 characters; no absolute paths, drive letters, `..`, reserved names |
| Entry types | no symbolic links, devices or encrypted entries; Stored and Deflate only |
| Ratio warning | above 200:1 for entries over 1 MB (hard size limits stop real bombs) |

Every entry is inflated with a byte counter and CRC-32 check, so an archive
lying about its sizes stops at the declared size.

## Log Viewer (`files.logs`)

Opens a log from the workspace or device by **streaming** it: at most
**200 000 lines** and **64 MiB** are loaded; a visible *TRUNCATED* notice says
which limit applied (search and export cover the loaded part only). CRLF, LF
and CR are handled; UTF-8 (with/without BOM) and UTF-16 with BOM are decoded;
invalid UTF-8 falls back to Latin-1 with a notice. Cuts never split a
character.

**Severity detection** (earliest marker in the line wins):

| Level | Recognised as |
| --- | --- |
| FATAL | `FATAL`, `CRITICAL`, `CRIT`, `EMERG`, `ALERT`, `PANIC`; logcat `F`/`A`; glog `F`; JSON level >= 60 |
| ERROR | `ERROR`, `ERR`, `SEVERE`; `E/Tag:`; glog `E0925 ...`; JSON 50 |
| WARN | `WARN`, `WARNING`; `W/Tag:`; `W ` prefix; JSON 40 |
| INFO | `INFO`, `NOTICE`; logcat `I`; `I 12:00 ...`; JSON 30 |
| DEBUG | `DEBUG`, `DBG`, `FINE`; logcat `D`; JSON 20 |
| TRACE | `TRACE`, `VERBOSE`, `FINER`, `FINEST`; logcat `V`; JSON 10 |

Forms understood: `[ERROR]`, `<error>`, `(warn)`, `|TRACE|`, ` ERROR ` (upper
case words), `Error:` at line start, `level=error` / `lvl=` / `severity=`
(logfmt), JSON `"level"`, `"severity"`, `"levelname"`, `"@l"` (words or
bunyan/pino numbers), Android logcat brief (`E/Tag( 123): ...`) and threadtime
(`09-01 12:00:00.123  1234  5678 W Tag: ...`), glog. Lower-case words in
prose ("no error here") are not levels. **Continuation lines** (stack frames,
indented details, wrapped messages - anything without a level that does not
start with a timestamp) inherit the previous line's severity; a new
timestamped line without a level is OTHER.

**Filter chips** show every level with icon, label and count. **Search** is
plain text or a regular expression, case-sensitive or not, with a match count,
next/previous (wrapping) and "only matching lines". Regular expressions run in
bounded worker isolates over 20 000-line chunks with a 4 s total budget, so a
catastrophic pattern is stopped with an explanation instead of freezing the
app; invalid patterns are reported inline.

The list is virtualised with fixed-height rows (line numbers, a one-letter
level tag, highlighted matches); *Wrap* switches to wrapped rows. Lines over
2 000 characters are shortened on screen (the full line is kept for copy and
export). Jumps are exact in both modes.

**Selection**: click selects a line, shift-click a range, ctrl/cmd-click
toggles; *Checkboxes* mode (default on phones, or long-press) toggles by tap
with 44 px rows. *Select matches*, *Select shown*, *Clear*. Keyboard: Ctrl+C
copy, Ctrl+A select shown, Esc clear, F3 / Shift+F3 next/previous match.

**Export** (selected or all shown lines, via `saveOutput`) starts with a
header:

```
# J3NSONTOP log export
# source: logs/game.log
# exported: 2026-09-25 18:41:07
# scope: selected lines, 12 line(s)
# severity filter: FATAL, ERROR, WARN
# search: /time(out)?/ (regex, ignore case), only matching lines
# line ranges (original numbering): 5-9, 20, 31-36
#
<raw lines>
```

## Terminal: `hash`

```
hash <text...> [--algo sha256|sha512|sha1|md5] [--check <digest>]
hash --file <workspace-relative path> [--algo ...] [--check <digest>]
```

* Text is hashed as UTF-8; quote it to keep spacing (`hash "a  b"`).
* `--file` resolves the path inside the active workspace with `SafePath`
  (absolute paths, `..` and symbolic-link escapes are refused) and streams it.
* Output: `<digest>  <path or ->`, then `algorithm: ... | size: ...`, plus a
  warning line for MD5/SHA-1.
* `--check` prints `MATCH` (exit 0) or `MISMATCH` (exit 1); comparison ignores
  case, whitespace and an `algo:` prefix. `-a` is short for `--algo`.

## Globs (batch filters)

Comma-, semicolon- or newline-separated patterns, case-insensitive:
`*` (within a name), `?`, `**` (any folders), `[abc]`, `[!abc]`,
`{png,jpg}`. A pattern without `/` matches file or folder names at any depth
(`*.log`, `node_modules`); with `/` it matches the path relative to the chosen
folder (`game/config/*.ini`, `data/**`). Excluded folders are not entered.
Empty include = all files.
