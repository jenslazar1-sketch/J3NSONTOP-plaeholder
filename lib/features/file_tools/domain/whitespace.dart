import '../../../core/utils/text_codec.dart';
import 'line_endings.dart';
import 'text_files.dart';

/// What to do with indentation.
enum IndentMode {
  keep('Keep'),
  tabsToSpaces('Tabs → spaces'),
  spacesToTabs('Leading spaces → tabs');

  const IndentMode(this.label);
  final String label;
}

/// Options of the whitespace cleanup. Rules run in a fixed order:
/// BOM, special spaces, indentation, trailing whitespace, blank lines,
/// final newline, line endings.
class WhitespaceOptions {
  const WhitespaceOptions({
    this.trimTrailing = true,
    this.indentMode = IndentMode.keep,
    this.tabWidth = 4,
    this.expandInnerTabs = false,
    this.collapseBlankLines = true,
    this.maxBlankLines = 1,
    this.ensureFinalNewline = true,
    this.stripBom = true,
    this.replaceSpecialSpaces = true,
    this.normalizeLineEndings = false,
    this.lineEnding = LineEnding.lf,
  });

  /// Remove spaces/tabs at the end of every line.
  final bool trimTrailing;
  final IndentMode indentMode;

  /// Tab stop width for [IndentMode] conversions (1..16).
  final int tabWidth;

  /// With [IndentMode.tabsToSpaces]: also expand tabs after the indentation
  /// (off by default so tab-separated data stays intact).
  final bool expandInnerTabs;
  final bool collapseBlankLines;

  /// Longest allowed run of blank lines (0 removes all blank lines).
  final int maxBlankLines;

  /// Remove trailing blank lines and end with exactly one line break.
  final bool ensureFinalNewline;
  final bool stripBom;

  /// NBSP (U+00A0), narrow NBSP (U+202F) and figure space (U+2007) become
  /// spaces; zero-width space (U+200B), word joiner (U+2060) and stray
  /// U+FEFF are removed. ZWJ/ZWNJ are kept (emoji and several scripts need
  /// them).
  final bool replaceSpecialSpaces;
  final bool normalizeLineEndings;

  /// Target when [normalizeLineEndings] is on (LF, CRLF or CR).
  final LineEnding lineEnding;

  WhitespaceOptions copyWith({
    bool? trimTrailing,
    IndentMode? indentMode,
    int? tabWidth,
    bool? expandInnerTabs,
    bool? collapseBlankLines,
    int? maxBlankLines,
    bool? ensureFinalNewline,
    bool? stripBom,
    bool? replaceSpecialSpaces,
    bool? normalizeLineEndings,
    LineEnding? lineEnding,
  }) => WhitespaceOptions(
    trimTrailing: trimTrailing ?? this.trimTrailing,
    indentMode: indentMode ?? this.indentMode,
    tabWidth: tabWidth ?? this.tabWidth,
    expandInnerTabs: expandInnerTabs ?? this.expandInnerTabs,
    collapseBlankLines: collapseBlankLines ?? this.collapseBlankLines,
    maxBlankLines: maxBlankLines ?? this.maxBlankLines,
    ensureFinalNewline: ensureFinalNewline ?? this.ensureFinalNewline,
    stripBom: stripBom ?? this.stripBom,
    replaceSpecialSpaces: replaceSpecialSpaces ?? this.replaceSpecialSpaces,
    normalizeLineEndings: normalizeLineEndings ?? this.normalizeLineEndings,
    lineEnding: lineEnding ?? this.lineEnding,
  );

  /// Everything off: a no-op cleanup (useful as a base in tests).
  static const WhitespaceOptions none = WhitespaceOptions(
    trimTrailing: false,
    collapseBlankLines: false,
    ensureFinalNewline: false,
    stripBom: false,
    replaceSpecialSpaces: false,
  );

  bool get anyRule =>
      trimTrailing ||
      indentMode != IndentMode.keep ||
      collapseBlankLines ||
      ensureFinalNewline ||
      stripBom ||
      replaceSpecialSpaces ||
      normalizeLineEndings;
}

/// What a cleanup changed.
class WhitespaceStats {
  int bomRemoved = 0;
  int specialSpacesReplaced = 0;
  int zeroWidthRemoved = 0;
  int tabsExpanded = 0;
  int indentsConverted = 0;
  int trailingTrimmed = 0;
  int blankLinesRemoved = 0;
  int trailingBlankLinesRemoved = 0;
  bool finalNewlineAdded = false;
  int lineEndingsChanged = 0;

  /// Lines whose content differs (lines removed entirely are not counted).
  int linesChanged = 0;

  /// Rules skipped for safety (e.g. special spaces in a non-UTF-8 file).
  final List<String> notes = [];

  bool get anyChange =>
      bomRemoved +
              specialSpacesReplaced +
              zeroWidthRemoved +
              tabsExpanded +
              indentsConverted +
              trailingTrimmed +
              blankLinesRemoved +
              trailingBlankLinesRemoved +
              lineEndingsChanged >
          0 ||
      finalNewlineAdded;

  List<String> describe() => [
    if (bomRemoved > 0) 'Removed the UTF-8 byte order mark',
    if (specialSpacesReplaced > 0) 'Replaced $specialSpacesReplaced non-breaking/figure space(s)',
    if (zeroWidthRemoved > 0) 'Removed $zeroWidthRemoved zero-width character(s)',
    if (tabsExpanded > 0) 'Expanded $tabsExpanded tab(s) to spaces',
    if (indentsConverted > 0) 'Converted indentation on $indentsConverted line(s)',
    if (trailingTrimmed > 0) 'Trimmed trailing whitespace on $trailingTrimmed line(s)',
    if (blankLinesRemoved > 0) 'Removed $blankLinesRemoved extra blank line(s)',
    if (trailingBlankLinesRemoved > 0) 'Removed $trailingBlankLinesRemoved trailing blank line(s)',
    if (finalNewlineAdded) 'Added the final line break',
    if (lineEndingsChanged > 0) 'Changed $lineEndingsChanged line ending(s)',
    ...notes,
  ];
}

class WhitespaceResult {
  const WhitespaceResult(this.text, this.stats);
  final String text;
  final WhitespaceStats stats;
  bool get changed => stats.anyChange;
}

class _Line {
  _Line(this.content, this.eol) : original = content;
  String content;
  String eol;
  final String original;
}

List<_Line> _parse(String text) {
  final out = <_Line>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 13 || c == 10) {
      final crlf = c == 13 && i + 1 < text.length && text.codeUnitAt(i + 1) == 10;
      out.add(_Line(text.substring(start, i), crlf ? '\r\n' : (c == 13 ? '\r' : '\n')));
      if (crlf) i++;
      start = i + 1;
    }
  }
  if (start < text.length) out.add(_Line(text.substring(start), ''));
  return out;
}

final RegExp _blank = RegExp(r'^[ \t\f\v]*$');
final RegExp _trailing = RegExp(r'[ \t\f\v]+$');
final RegExp _specialSpace = RegExp('[   ]');
final RegExp _zeroWidth = RegExp('[​⁠﻿]');

bool _isBlank(String s) => _blank.hasMatch(s);

/// Visual width of leading whitespace with tab stops of [tabWidth], and
/// the number of characters it spans.
(int width, int length) _leadingWidth(String s, int tabWidth) {
  var col = 0;
  var i = 0;
  for (; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 32) {
      col++;
    } else if (c == 9) {
      col = (col ~/ tabWidth + 1) * tabWidth;
    } else {
      break;
    }
  }
  return (col, i);
}

String _expandAllTabs(String s, int tabWidth, void Function() onTab) {
  if (!s.contains('\t')) return s;
  final out = StringBuffer();
  var col = 0;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '\t') {
      final next = (col ~/ tabWidth + 1) * tabWidth;
      out.write(' ' * (next - col));
      col = next;
      onTab();
    } else {
      out.write(ch);
      col++;
    }
  }
  return out.toString();
}

/// Applies [o] to [input]. [allowSpecialSpaces] is false for text decoded
/// with the Latin-1 fallback, where U+00A0 may really be part of a broken
/// multi-byte sequence and must not be touched.
WhitespaceResult cleanWhitespace(String input, WhitespaceOptions o, {bool allowSpecialSpaces = true}) {
  final stats = WhitespaceStats();
  final tw = o.tabWidth.clamp(1, 16);
  final lines = _parse(input);
  final dominant = countLineEndings(input).dominant;
  final eolTarget = o.normalizeLineEndings ? o.lineEnding.sequence : dominant.sequence;

  if (o.stripBom && lines.isNotEmpty && lines.first.content.startsWith('﻿')) {
    lines.first.content = lines.first.content.substring(1);
    stats.bomRemoved = 1;
  }
  if (o.replaceSpecialSpaces && !allowSpecialSpaces) {
    stats.notes.add('Special-space replacement skipped: the file is not valid UTF-8');
  }

  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    var c = line.content;

    if (o.replaceSpecialSpaces && allowSpecialSpaces) {
      // Keep a leading BOM when the BOM rule is off.
      final keepBom = li == 0 && !o.stripBom && c.startsWith('﻿');
      final head = keepBom ? '﻿' : '';
      var body = keepBom ? c.substring(1) : c;
      body = body.replaceAllMapped(_specialSpace, (_) {
        stats.specialSpacesReplaced++;
        return ' ';
      });
      body = body.replaceAllMapped(_zeroWidth, (_) {
        stats.zeroWidthRemoved++;
        return '';
      });
      c = head + body;
    }

    switch (o.indentMode) {
      case IndentMode.keep:
        break;
      case IndentMode.tabsToSpaces:
        if (o.expandInnerTabs) {
          c = _expandAllTabs(c, tw, () => stats.tabsExpanded++);
        } else {
          final (width, len) = _leadingWidth(c, tw);
          final lead = c.substring(0, len);
          if (lead.contains('\t')) {
            stats.tabsExpanded += '\t'.allMatches(lead).length;
            c = (' ' * width) + c.substring(len);
          }
        }
      case IndentMode.spacesToTabs:
        final (width, len) = _leadingWidth(c, tw);
        final replacement = ('\t' * (width ~/ tw)) + (' ' * (width % tw));
        if (replacement != c.substring(0, len)) {
          c = replacement + c.substring(len);
          stats.indentsConverted++;
        }
    }

    if (o.trimTrailing) {
      final trimmed = c.replaceFirst(_trailing, '');
      if (trimmed.length != c.length) {
        c = trimmed;
        stats.trailingTrimmed++;
      }
    }
    line.content = c;
  }

  var result = lines;
  if (o.collapseBlankLines) {
    final max = o.maxBlankLines < 0 ? 0 : o.maxBlankLines;
    final kept = <_Line>[];
    var run = 0;
    for (final l in lines) {
      if (_isBlank(l.content)) {
        run++;
        if (run > max) {
          stats.blankLinesRemoved++;
          continue;
        }
      } else {
        run = 0;
      }
      kept.add(l);
    }
    result = kept;
  }

  if (o.ensureFinalNewline) {
    while (result.isNotEmpty && _isBlank(result.last.content)) {
      result.removeLast();
      stats.trailingBlankLinesRemoved++;
    }
    if (result.isNotEmpty && result.last.eol.isEmpty) {
      result.last.eol = eolTarget;
      stats.finalNewlineAdded = true;
    }
  }

  if (o.normalizeLineEndings) {
    for (final l in result) {
      if (l.eol.isNotEmpty && l.eol != eolTarget) {
        l.eol = eolTarget;
        stats.lineEndingsChanged++;
      }
    }
  }

  final out = StringBuffer();
  for (final l in result) {
    if (l.content != l.original) stats.linesChanged++;
    out
      ..write(l.content)
      ..write(l.eol);
  }
  return WhitespaceResult(out.toString(), stats);
}

/// File-level variant: strips the BOM by switching UTF-8-with-BOM files to
/// plain UTF-8 (the decoder already removed the BOM bytes from the text).
(String, TextEncodingKind, WhitespaceStats) cleanDecodedFile(DecodedText decoded, WhitespaceOptions o) {
  final r = cleanWhitespace(decoded.text, o, allowSpecialSpaces: decoded.encoding != TextEncodingKind.latin1);
  var enc = decoded.encoding;
  if (o.stripBom && enc == TextEncodingKind.utf8Bom) {
    enc = TextEncodingKind.utf8;
    r.stats.bomRemoved = 1;
  }
  if (o.stripBom && (enc == TextEncodingKind.utf16le || enc == TextEncodingKind.utf16be)) {
    r.stats.notes.add('UTF-16 files keep their byte order mark (it defines the byte order)');
  }
  return (r.text, enc, r.stats);
}

/// Makes invisible characters visible for previews: tabs `→`, trailing
/// spaces `·`, no-break/figure spaces `°`, zero-width characters and stray
/// BOMs `¤`.
String showInvisibles(String line) {
  final trailing = RegExp(r' +$').firstMatch(line);
  final cut = trailing?.start ?? line.length;
  final out = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    switch (ch) {
      case '\t':
        out.write('→');
      case ' ' || ' ' || ' ':
        out.write('°');
      case '​' || '⁠' || '﻿':
        out.write('¤');
      case ' ':
        out.write(i >= cut ? '·' : ' ');
      default:
        out.write(ch);
    }
  }
  return out.toString();
}

/// Edit budget for preview diffs so memory stays bounded (the Myers trace
/// grows with edit distance x line count).
int previewDiffBudget(int oldLines, int newLines) => (4000000 ~/ (2 * (oldLines + newLines) + 2)).clamp(64, 20000);

/// File transform for [processTextFiles].
TextTransform<WhitespaceStats> whitespaceTransform(WhitespaceOptions o) => (DecodedText d) {
  final (text, enc, stats) = cleanDecodedFile(d, o);
  return TransformResult(text, enc, stats);
};
