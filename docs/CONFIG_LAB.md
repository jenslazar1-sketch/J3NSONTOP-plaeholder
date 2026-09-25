# Config Lab

The Config Lab (section `/config`) edits, validates, compares and converts
configuration files of your own projects and mod-friendly games. Everything
runs locally. Files opened from the active workspace are saved back in place
through `WorkspaceFileWriter.replaceWithBackup` (the previous content goes to
`<workspace meta>/backups/<timestamp>/<relative path>` and the backup path is
shown after saving); anything else is saved with "Save as" (never silently
overwriting). Inputs larger than 256 KiB are parsed and converted in a
background isolate; regex searches and schema validation run in a bounded
isolate with a time limit.

| Tool id | Name | What it does |
| --- | --- | --- |
| `config.json` | JSON Studio | strict validation with line:column, caret snippet and "Jump to error"; format (2 / 4 spaces / tab), minify, recursive key sort, "ensure ASCII"; lazy tree with type chips, scalar editing, rename/add/delete, JSONPath copy; field search (substring or regex); statistics; undo of the last transform |
| `config.yaml` | YAML Editor | validation with line:column; read-only tree (per document); YAML -> JSON; JSON -> YAML (verified) |
| `config.toml` | TOML Editor | validation with line:column; read-only tree (date/time chips); TOML -> JSON; JSON -> TOML (verified) |
| `config.ini` | INI Editor | documented parser (below); lossless table editing; INI -> JSON; JSON -> INI (verified) |
| `config.csv` | CSV / TSV Table | RFC 4180 parser with positions; virtualised preview (sticky header, horizontal scroll); delimiter auto-detection; stats; filter; CSV <-> TSV, CSV -> JSON, JSON -> CSV (verified) |
| `config.compare` | Config Compare | semantic diff (added / removed / changed / type changed) of JSON, YAML, TOML or INI (mixed formats allowed) plus unified or side-by-side line diff; exportable report |
| `config.presets` | Config Presets | JSON Merge Patch (RFC 7386) presets: create, edit, rename, delete, duplicate, import, export; preview semantic + text diff; apply and save with backup |
| `config.save_editor` | Save Data Editor | JSON save files described by a JSON schema (subset): generated form, live validation, raw JSON, save with backup |

Terminal: `json validate|format|minify [--indent 2|4|tab] '<json text>'` or
`--file <workspace-relative path>` (resolved inside the active workspace with
`SafePath.resolveInside`, read-only, up to 8 MiB). Wrap JSON text in single
quotes so the terminal keeps the double quotes. Errors print
`<source>:<line>:<column>: <message>` and a caret snippet; exit code 1.

## Lossless vs. changes representation

Every conversion returns an itemised **conversion report**:

* **ERROR** - the conversion is refused and nothing is produced.
* **CHANGE** - the output *changes representation*: converting it back does
  not reproduce the source (a comment is dropped, a type changes, keys are
  reordered, a value is inferred...). Every occurrence is listed with its
  line and/or JSONPath.
* **NOTE** - information only; data, types and order are kept.

The UI badge shows **LOSSLESS** when there are no errors and no changes, else
**CHANGES REPRESENTATION** (or **FAILED**). Formatting (indentation, quote
style, flow vs. block style, blank lines) is always regenerated in the target
format's canonical style and is not itemised. Conversions *to* YAML, TOML,
INI, CSV and TSV are verified: the output is parsed again and compared with
the source data (types and, where the format keeps it, key order); a mismatch
fails loudly and withholds the output (**ROUND TRIP VERIFIED** otherwise).

## Conversion matrix

| From -> To | Verdict when nothing below applies | Changes in representation (each itemised) | Errors (refused) |
| --- | --- | --- | --- |
| YAML -> JSON | LOSSLESS | comments dropped; directives (`%YAML`, `%TAG`) dropped; aliases expanded into copies; non-string keys stringified (`1` -> `"1"`, `true` -> `"true"`, `~` -> `"null"`, complex keys -> their JSON text); keys colliding after stringification (later wins); `.inf` / `-.inf` / `.nan` written as strings; YAML 1.1 merge key `<<` not applied (kept as a key); several `---` documents combined into an array or all but the first dropped (user choice) | syntax errors; recursive aliases |
| JSON -> YAML | LOSSLESS | duplicate JSON keys (last wins); numbers that JSON itself cannot hold exactly | syntax errors; failed verification |
| TOML -> JSON | LOSSLESS | comments dropped; offset/local date-times, dates and times become ISO-8601 strings (`1979-05-27T07:32:00Z`, `07:30:00`); `inf` / `nan` become strings; integers beyond 64 bits become strings | syntax and semantic errors (redefinitions...) |
| JSON -> TOML | LOSSLESS | plain keys written before sub-tables (key order of that object changes); null properties dropped when "Drop null properties" is on; duplicate JSON keys | top level not an object; nulls (unless dropped); nulls inside arrays; failed verification |
| INI -> JSON | LOSSLESS (strings) | comments dropped; duplicate sections merged; duplicate keys (last wins); with "Infer numbers and booleans": every inferred value (`"1920"` -> `1920`, `"1.50"` -> `1.5` with its formatting loss, `"TRUE"` -> `true`) | invalid lines; a global key and a section with the same name |
| JSON -> INI | LOSSLESS (all values strings) | numbers/booleans become text; top-level scalars after a section move before the first section | top level not an object; nested objects/arrays below a section; arrays; nulls; multi-line strings; invalid key/section names; failed verification |
| CSV <-> TSV | LOSSLESS | cells quoted because they contain the target delimiter, a quote or a line break (a CHANGE for TSV output, because TSV readers without quote support misread them; a NOTE for CSV output); skipped blank lines; lenient-parse warnings | unterminated quoted field; failed verification |
| CSV -> JSON (array of objects) | LOSSLESS | empty/duplicate headers renamed (`column_2`, `name_2`); short rows (missing keys omitted); long rows (extra cells stored as `column_N`); with "Infer numbers, booleans and null": every inferred cell | unterminated quoted field; objects without a header row |
| CSV -> JSON (array of arrays) | LOSSLESS | skipped blank lines; inferred cells (opt-in) | unterminated quoted field |
| JSON -> CSV/TSV | LOSSLESS (all values strings) | null -> empty cell; numbers/booleans -> text; objects with missing keys (empty cells); objects whose key order differs from the header; with dotted flattening: nested values spread over `a.b` / `list.0` columns | not an array; mixed object/array/scalar items; nested values (unless flattened); empty arrays; flattened column collisions; failed verification |

Notes that never change data: number notation normalised (`0x1F` -> `31`,
`1_000` -> `1000`, `+1` -> `1`), explicit YAML tags applied (`!!str 01`),
quotes removed from INI values, strings quoted in YAML output because YAML
1.1 readers would misread them (`yes`, `no`, `on`, `off`, `y`, `n`, `null`,
`~`, numbers, dates, `<<`), multi-line strings written as literal blocks
(`|`, `|-`, `|+`), integers beyond 2^53 (exact here, may be rounded by
JavaScript tools), mixed-type TOML arrays (valid in TOML 1.0, rejected by 0.5
readers).

## JSON

Strict RFC 8259 parser (`domain/json_parser.dart`). It reports precise
messages with offsets: trailing commas (pointing at the comma), comments,
single quotes, unquoted keys, `True`/`None`/`NaN`/`Infinity`, leading zeros,
`+1`, `.5`, unescaped line breaks/tabs/control characters in strings, invalid
escapes, missing `:`/`,`, text after the value, non-breaking spaces, nesting
deeper than 512 levels and numbers overflowing to infinity. Duplicate keys
are warnings (the last value wins at the position of the first key, like
`JSON.parse`). Integers beyond 64 bits (stored as floating point), beyond
2^53, `-0` and floats with more than 17 significant digits are reported. A
leading BOM is skipped and flagged.

Tree edits are applied to the parsed value and the whole document is
re-serialised with the selected indent (the previous text can be restored
with Undo). JSONPath uses dot notation for identifier keys and bracket
notation otherwise: `$.player.stats["max hp"][2]`.

## YAML

Parsed with `package:yaml` (YAML 1.2 core schema): `yes`/`no`/`on`/`off` are
strings, `0o17` and `0x1F` are integers, `~`/`null`/empty are null. Duplicate
keys are errors. Error spans are converted to 1-based line/column.

The loss scanner walks the text outside scalar content (scalar spans come
from the parsed nodes) to find comments (`#` preceded by whitespace or at a
line start), anchors (`&a`), aliases (`*a`), tags (`!x`, `!!str`) and
directives (`%...` at a line start); repeated node identities give the
JSONPath of every expanded alias.

The JSON -> YAML emitter writes block style with 2-space indentation, lists
under keys indented by 2, `- key: value` for objects in lists, `- - x` for
nested lists, `{}`/`[]` for empty containers and explicit `? key` for keys
over 1000 characters. Plain scalars are used only when unambiguous; other
strings use double quotes with escapes (`\n`, `\t`, `\uXXXX`, `\L`, `\P`).
Multi-line strings become literal blocks unless a line starts with
whitespace, a line is whitespace-only, or the text contains CR or control
characters (then double quotes).

## TOML

Parsed and encoded with `package:toml` (TOML 1.1). Parse errors carry line and
column; redefinition / not-a-table errors are located on a best-effort basis
(the second definition of the name). Comments are detected by a small lexer
that skips basic, literal and multi-line strings.

## INI (parser rules)

Implemented in `domain/ini_document.dart`:

1. Lines end with LF, CRLF or CR; each line keeps its own ending and the last
   line may have none. A UTF-8 BOM at the very start is ignored for parsing
   and preserved.
2. Leading/trailing whitespace of a line is ignored for classification.
3. A line whose first non-blank character is `;` or `#` is a **comment**.
   Empty or whitespace-only lines are **blank**.
4. `[name]` starts a **section**; the name is trimmed; a `;`/`#` comment may
   follow the closing bracket. An empty name, a missing `]` or other text after
   `]` is an **invalid line** (error with line number).
5. Other lines are **entries**: the first `=` or `:` separates key and value.
   Key and value are trimmed. An empty key is an invalid line; a line without
   `=`/`:` is an invalid line.
6. Entries before the first section belong to the **global section** (JSON:
   top-level keys).
7. A value that starts and ends with the same quote character (`"` or `'`) is
   **quoted**: the outer quotes are removed, the inner text is kept verbatim.
   There are no escape sequences; inner quotes need no escaping because only
   the first and last character mark quotes. A value with an unmatched leading
   or trailing quote is kept verbatim with a warning.
8. **Inline comments are not recognised**: `volume = 80 ; percent` has the
   value `80 ; percent` (the same default as Python's `configparser`).
9. Indented lines are not continuations.
10. Names are **case-sensitive**. Duplicate section headers are warnings (the
    sections are merged in conversions); duplicate keys in the same section
    are warnings (the last value wins in conversions); names that differ only
    by case are flagged because many INI readers treat them as equal.

**Lossless editing.** The document is a list of lines. Editing a value
replaces only the value token of that line (the separator, surrounding
spacing, quote style and line ending stay); every other byte of the file is
unchanged. A quoted value stays quoted; an unquoted value gets `"` quotes only
when it would otherwise read back differently (leading/trailing whitespace or
a leading/trailing quote); values with line breaks are rejected. Added keys
go after the last key of their section, copying the separator style of the
nearest entry and the file's dominant line ending (global keys go above the
comment block attached to the first section header). Adding after an
unterminated last line only gives that line a line ending. New sections are
appended after a blank line. Deleting a key removes exactly its line.

## CSV / TSV (parser rules)

`domain/csv_codec.dart`, RFC 4180 with exact positions:

* A leading BOM is skipped. Records end at LF, CRLF or CR outside quotes; a
  final line ending does not create an extra record. Completely empty lines
  are skipped (and reported in conversions); a line holding only spaces is a
  record with one field.
* A field that starts with the quote character (`"` or `'`, configurable) is
  quoted: a doubled quote is a literal quote; delimiters and line breaks
  inside are kept verbatim.
* Lenient cases produce warnings with line:column: text after a closing quote
  is appended; a quote inside an unquoted field is kept literally. A quoted
  field still open at the end of the input is an error.
* Delimiter auto-detection tries comma, semicolon, tab and pipe on the first
  30 lines (quotes respected) and picks the one giving the most consistent
  field count.
* Output quotes only fields that need it (delimiter, quote, CR/LF, or the
  single empty field of a one-column record) and keeps the source line ending
  and final newline for CSV <-> TSV.
* Statistics: records, columns, ragged rows (record number, line, field
  count), empty cells, line endings, BOM, skipped blank lines.

## Compare

Both sides are parsed to JSON-like values (YAML keys as strings, TOML
date-times as ISO strings, INI values as strings; the format is chosen or
auto-detected: extension first, then JSON, TOML, INI, YAML). The semantic diff
ignores object key order; arrays are aligned with a Myers diff over their
items' canonical JSON so an insertion reports one addition, and adjacent
removed/added items are paired as changes (compared recursively). `1` vs
`1.0` is equal; `"1"` vs `1` is a type change. The line diff uses the shared
`LineDiff` (optionally ignoring whitespace).

## Presets (JSON Merge Patch)

Presets are RFC 7386 merge patches: objects merge key by key, `null` removes a
key, any other value (including arrays) replaces the target value. User
presets are stored in feature data under `config_lab.presets` as
`{"v": 1, "items": [{"id", "name", "description"?, "target"?, "patch",
"createdAt"?, "updatedAt"?}]}`; other versions are reported, never guessed.
Import accepts that payload, a list of presets, or a single preset object
(new ids are assigned). Two built-in presets, **Potato mode** and **Ultra**,
are labelled examples written for the sample game's
`game/config/graphics.json`; they cannot be edited or deleted (duplicate them
instead). Applying a preset re-serialises the document with its detected
indentation (2 spaces, 4 spaces, tab or minified) and trailing newline; the
preview lists every semantic change and the line diff before anything is
saved.

## Save Data Editor

Supported: JSON save files described by a JSON schema (subset). Binary or
undocumented formats are not supported and are never guessed (binary files
are refused when opened).

Schema subset (docs/SAMPLES.md): `type` (object, array, string, integer,
number, boolean, null - a single string), `title`, `description`,
`properties`, `required`, `additionalProperties` (boolean only), `items`
(single schema), `minimum`, `maximum` (inclusive), `minLength`, `maxLength`
(Unicode code points), `pattern` (ECMAScript-style regex, unanchored), `enum`,
`default`. `$schema`, `$id` and `$comment` are accepted as metadata; any other
keyword is listed as ignored. `integer` accepts `7.0`. Violations use JSON
Pointer paths (`/player/level`, `/inventory/2/id`); missing required
properties are reported at the missing property's pointer.

For workspace files, a sibling `<name>.schema.json` or `save.schema.json` is
loaded automatically; otherwise choose a schema. The form: objects are
collapsible panels (missing optional properties can be added, extra properties
are shown and removable, and flagged when `additionalProperties` is false),
arrays support add / remove / move up / move down using the `items` schema
(`default`, else the first enum value, else a type default with required
properties), enums are dropdowns, numbers have steppers clamped to the bounds,
booleans are switches, strings show length/pattern hints. Every edit rewrites
the raw JSON in the file's own indentation style and re-validates in a
bounded isolate (2 s limit, so a pathological `pattern` cannot freeze the
app). Issues link to the exact location in the raw JSON. Saving with schema
issues or invalid JSON asks for confirmation.
