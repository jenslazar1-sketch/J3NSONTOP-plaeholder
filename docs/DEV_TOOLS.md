# Developer Tools

Section `Developer Tools` (`/dev`). Twelve tools, all local except the HTTP
tool, which only contacts the URL you type (see [HTTP_TOOL.md](HTTP_TOOL.md)).
Inputs live in session drafts, so unfinished work survives switching tools.
Results have Copy and Save/Export actions. Status is always shown as an icon
plus text. Malformed input is reported with its line, column and offset, and
text fields offer **Go to line X, col Y**, which moves the cursor to the problem.

Code layout (`lib/features/dev_tools/`):

| Folder | Content |
| --- | --- |
| `domain/` | Pure logic shared by the tools and the terminal commands |
| `data/` | `http_history_store.dart` (persisted, redacted HTTP history) |
| `presentation/` | Pages, controllers (Riverpod notifiers) and small shared widgets |
| `commands/` | Terminal commands `diff`, `uuid`, `b64`, `url`, `ts` |
| `dev_tools_module.dart` | Tool and command registration |

## Tools

### Base64 (`dev.base64`)
* Encodes UTF-8 text with the standard (`+/`) or URL-safe (`-_`) alphabet. You can keep or strip the
  padding and wrap lines at 64 (PEM) or 76 (MIME) characters.
* Decoding accepts either alphabet and ignores whitespace and line breaks. Missing
  padding and a `data:<mime>;base64,` prefix are also accepted. It reports
  invalid characters, data after `=`, mixed alphabets, truncated final groups and
  incorrect padding, each with its exact position. When the unused bits of the
  last character are not zero, the input still decodes and a warning is shown.
* If the decoded bytes are not valid UTF-8, the tool gives the offset of the first
  invalid byte, shows a hex preview with the file type detected from its magic
  bytes, and offers **Save as binary**. It suggests an extension, for example
  `decoded.png`.
* **File -> Base64** accepts a file from the workspace or the device. Files up to
  **10 MiB** are encoded in a background isolate. Larger files are refused with
  a message that states their size. The result can be written as a `data:` URI.
* Previews show the first 200 000 characters. Copy and Save always use the full
  text.

### URL Encode/Decode (`dev.url`)
* Encoding modes:
  * **Component** keeps only `A-Z a-z 0-9 - . _ ~`.
  * **Full URI** also keeps `: / ? # [ ] @ ! $ & ' ( ) * + , ;` and existing `%XX` escapes, so nothing is
    encoded twice.
  * **Form** turns spaces into `+` and keeps `A-Z a-z 0-9 * - . _`.
* Decoding is strict. A `%` without two hex digits is an error, and so are
  percent-decoded bytes that are not valid UTF-8. Both errors give the position.
  The Form option decodes `+` as a space.
* **Inspect URL** shows the scheme, the user info (the password is masked until you reveal it), host
  and port (default ports are marked), and the path. It also lists the decoded
  path segments, a query table that keeps order and duplicates (parameters
  that fail to decode are flagged) and the decoded fragment. The inspector
  rejects spaces and malformed escapes that `Uri.parse` would silently accept.

### UUID (`dev.uuid`)
* Generates 1-1000 UUIDs at a time, either v4 or v7:
  * **v4** uses 122 random bits from a cryptographically secure generator.
  * **v7** stores the Unix time in milliseconds and uses the 12-bit `rand_a` field as a counter, so a batch
    is strictly increasing (RFC 9562 method 1).
* Output options are upper case, no hyphens and `{braces}`. They reformat the
  current batch; nothing is regenerated.
* **Inspect** accepts canonical, upper-case and hyphen-less UUIDs, plus braces and a `urn:uuid:` prefix.
  It shows the version with its name, the variant, Nil/Max, the hex bytes and the embedded
  creation time (v1, v6 and v7) in UTC and local time, with its age.

### Timestamp Converter (`dev.timestamp`)
* **Live clock** shows Unix seconds and milliseconds, ISO-8601 UTC and local time with the
  offset and zone name. It updates once per second on the second boundary and has
  no animation. The timer is paused while the page is off-screen (`TickerMode`)
  and can be paused by hand. It is cancelled when the page is disposed.
  **Use now** copies the current time into the converter.
* **Auto** detects the unit by magnitude:
  * `|v| < 1e11` is seconds (until year 5138).
  * `< 1e14` is milliseconds.
  * `< 1e17` is microseconds.
  * Anything larger is nanoseconds.
* The unit can be overridden, because ms timestamps before 1973 look like seconds. Fractions and
  `_` separators are accepted. Nanoseconds are kept exactly in the output. The
  internal clock has microsecond precision.
* **ISO-8601** is parsed strictly, in extended or basic form. It accepts `T` or a
  space as the separator, fractions with `.` or `,` up to 9 digits, and
  `Z`/`UTC`/`GMT`/`+hh:mm`/`+hhmm` suffixes. An out-of-range month, day, hour,
  minute, second or offset is an error at that field. The leap second `:60` is
  rejected. A time without an offset is read as local time unless **Times
  without an offset are UTC** is on.
* **RFC 2822 / HTTP dates** are parsed in all three RFC 9110 forms (IMF-fixdate,
  RFC 850, asctime) and with numeric or North American zones. A weekday that
  does not match the date triggers a note.
* Output shows:
  * Unix s/ms/us/ns.
  * ISO UTC, ISO local and ISO in the offset as written.
  * RFC 2822 and the HTTP date.
  * Calendar-aware relative time.
  * Weekday, ISO week (`2026-W39-5`) and day of year, for both the local and the UTC calendar.
* Range: DateTime's +-8.64e15 ms (about 271 821 BC to 275 760 AD).

### Text Stats (`dev.text_stats`)
* Exact counts:
  * UTF-16 code units, code points and grapheme clusters (via `characters`).
  * Words, unique words, lines and blank lines. A trailing line break does not add a line.
  * Paragraphs and the longest line (in code points, with its line number).
  * UTF-8 and UTF-16 byte sizes.
  * Letters, digits, whitespace, other and non-ASCII characters.
  * Line-ending style and the ten most frequent words.
* Estimates are labelled as such: sentences, reading time (238 wpm) and
  speaking time (150 wpm). Words are runs of letters, digits and marks joined by
  `' ’ . _ -`. Han, Hiragana and Katakana characters count as one word each.
* Stats update live. Text under 20 000 characters is counted immediately.
  Longer text waits for typing to pause. Text above 200 000 characters is
  counted in a background isolate. **Open text file** loads files up to 16 MB and
  refuses binary files.

### JSON Escape/Unescape (`dev.json_escape`)
* Escape options: surrounding quotes, `\uXXXX` for every non-ASCII character
  (with surrogate pairs), and `\/`. Control characters always become short
  escapes or `\u00XX`. U+2028 and U+2029 are always escaped so the output is safe
  in JavaScript. Lone surrogates are escaped too.
* Unescape accepts a literal with or without quotes. Errors report the exact
  position for these cases:
  * unknown escapes such as `\x`;
  * a short or invalid `\u`;
  * a backslash at the end;
  * raw control characters;
  * an unescaped inner quote;
  * a missing closing quote.

  Lone surrogates decode with a warning.

### Regex Tester (`dev.regex`)
* Pattern, flags (`i` ignore case, `m` multi-line, `s` dot-all, `u` Unicode),
  test text and an optional **Replace preview**.
* Every run happens in a killable worker (`runBounded`) with a **1.5 s time
  limit** and a **10 000 match cap**. A pattern that backtracks catastrophically
  stops with *"Stopped: time limit reached (pattern may backtrack
  catastrophically)"*. A **Cancel** button is shown while a run is in progress.
  Live mode runs 300 ms after you stop typing. **Run** and Ctrl+Enter run
  immediately.
* Matches are highlighted with a neon background and are also wrapped in the
  text markers `«...»`, so colour is never the only signal. Empty matches show `¦`. Up to 2000
  matches and 100 000 characters are highlighted. The match list is virtualised
  and shows each match's index and `[start, end)`. Selecting a match shows its
  numbered and named groups, and groups that did not participate are labelled.
* Replacement syntax:

  | Syntax | Meaning |
  | --- | --- |
  | `$1` ... `$99` | numbered group (two digits when that group exists, like JavaScript) |
  | `${1}` | numbered group, unambiguous |
  | `${name}` | named group `(?<name>...)` |
  | `$&` or `$0` | whole match |
  | `$$` | a literal `$` |
  | any other `$` | copied literally |

  Unknown group numbers or names, and an unclosed `${`, are errors with their position in the
  template.
* Pattern errors show the engine's message (Dart does not report offsets).
* The example library has email-ish, IPv4, semantic version (named groups), ISO date and log level
  (multi-line). Picking one sets the pattern and flags and, if the test text is empty, fills in a
  sample.

### Text Diff (`dev.diff`)
* Two inputs, each typed or pasted, or opened from a file (up to 8 MB, text only).
  Options are ignore whitespace and ignore case.
* Views:
  * **Unified** and **Side by side**, both virtualised, with line numbers, `+`/`-` markers and
    colours.
  * Side by side pairs changed lines and highlights the changed words.
  * Context can be 3, 10 or all lines; unchanged runs collapse into a "... N unchanged lines ..." row.
* Stats badges (added/removed/same). **Copy** and **Save** produce a unified diff
  (`changes.diff`).
* Inputs up to 200 000 characters are compared as you type. Up to 600 lines run
  inline, and anything larger runs in `Isolate.run`. Each side is limited to
  8 MB and 200 000 lines.
* Myers stores one vector per explored edit step. The edit budget is therefore
  derived from the size of the changed middle block, which bounds memory to
  about 32 MB. If the budget is exceeded, the rest of that block is shown as one
  deletion plus one insertion. The page then shows **"Diff truncated by the edit
  budget"**.

### HTTP Request (`dev.http`)
See [HTTP_TOOL.md](HTTP_TOOL.md). Requires `Capability.networkRequests`.

### Case Converter (`dev.case`)
* Converts to camelCase, PascalCase, snake_case, kebab-case, CONSTANT_CASE,
  Title Case, Sentence case, lower, UPPER, dot.case and path/case. Each line is
  converted separately.
* Word splitting:
  * Any character that is not a letter or digit separates words.
  * A lower-to-upper change starts a new word (`fooBar`).
  * In an upper-case run followed by lower case, the last capital starts the next word (`HTTPServer` ->
    `HTTP`, `Server`).
  * Digits stay attached unless **Split numbers** is on.
  * Unicode letters are handled by case, and caseless scripts behave like lower case.
  * **Keep acronyms** keeps all-caps words in Pascal, camel and Title case.
* lower and UPPER change the whole text and keep all separators.

### Number Base Converter (`dev.number_base`)
* Input in Auto mode (`0x`/`0b`/`0o` prefixes, otherwise decimal), bin, oct, dec, hex or any base 2-36. A sign and
  `_` or space separators are allowed. BigInt allows up to 4096 digits. An
  invalid digit is reported at its character.
* Output: bin, oct, dec and hex, with optional digit grouping, plus any extra
  base. It also shows the bit length and the smallest standard width that holds
  the value.
* Two's complement for 8/16/32/64/128-bit widths:
  * fits-signed and fits-unsigned badges, with an overflow warning;
  * hex and bit patterns;
  * the pattern read as unsigned and as signed;
  * big- and little-endian bytes;
  * the IEEE 754 float for 32/64-bit, useful for game save values.

### JWT Decoder (`dev.jwt`)
* A banner states **"Decode only - the signature is NOT verified"**. Decoding
  happens on the device, and a leading `Bearer ` is ignored.
* Output:
  * header and payload as pretty JSON;
  * the registered claims with labels;
  * `iat`, `nbf` and `exp` in UTC and local time, with relative time;
  * an **EXPIRED**, **NOT YET VALID**, **WITHIN VALIDITY WINDOW** or **NO exp/nbf CLAIMS** badge;
  * the signature length.
* Warnings cover `alg: none`, a missing `alg`, an empty signature, time claims in
  milliseconds or of the wrong type, and encrypted JWE tokens (5 parts; only the
  header is shown). Base64URL and JSON errors give the part and its position.

## Terminal commands

Commands share their domain code with the tools. Inline texts may use the
two-character escapes `\n` and `\t`. Write them inside single quotes; the
terminal's double quotes consume one backslash.

| Command | Examples |
| --- | --- |
| `diff <a> <b>` or `diff --file-a <path> --file-b <path>` `[--ignore-case] [--ignore-space] [--context N]` | `diff 'a\nb' 'a\nc'`, `diff --file-a config/old.json --file-b config/new.json` |
| `uuid [count] [--v7] [--upper] [--no-hyphens] [--braces]` | `uuid 5 --v7` |
| `b64 enc\|dec <text> [--url] [--no-pad]` (alias `base64`) | `b64 dec aGVsbG8=` |
| `url enc\|dec <text> [--form] [--full]` | `url enc "a b&c"` |
| `ts [value] [--unit s\|ms\|us\|ns] [--utc]` (alias `timestamp`) | `ts`, `ts 1758829267123` |

`--file-a` and `--file-b` are paths relative to the active workspace. They are
resolved with `SafePath.resolveInside`, which rejects absolute paths, `..`
traversal and escapes through symbolic links. Paths autocomplete from the
workspace. `diff` output is styled: `+` lines success, `-` lines error, `@@` hunk
headers accent, `---`/`+++` dim. It stops after 2000 lines, and the tool shows the rest.
Invalid inline input prints the error with a `^` caret under the offending character.

## Limits at a glance

| Tool | Limit |
| --- | --- |
| Base64 file encode | 10 MiB |
| Regex | 1.5 s per run, 10 000 matches, 2000 highlighted |
| Diff | 8 MB / 200 000 lines per side; edit budget about 4M vector entries |
| Text stats file | 16 MB |
| Number base | 4096 digits |
| UUID | 1000 per batch |
| HTTP | display 2 MiB, read up to 64 MiB, 50 history entries |
