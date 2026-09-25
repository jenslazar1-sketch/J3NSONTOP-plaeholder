import 'dart:isolate';

// Grapheme clusters come from package:characters, which Flutter's widgets
// library re-exports (it is not a direct dependency of this app).
import 'package:flutter/widgets.dart' show StringCharacters;

import '../../../core/utils/text_codec.dart';

/// Counts for the Text Stats tool. Every number is exact except the
/// clearly labelled estimates (sentences, reading and speaking time).
class TextStats {
  const TextStats({
    required this.utf16Units,
    required this.codePoints,
    required this.graphemes,
    required this.words,
    required this.uniqueWords,
    required this.lines,
    required this.blankLines,
    required this.longestLine,
    required this.longestLineNumber,
    required this.utf8Bytes,
    required this.sentences,
    required this.paragraphs,
    required this.letters,
    required this.digits,
    required this.whitespace,
    required this.other,
    required this.nonAscii,
    required this.lineEnding,
    required this.topWords,
  });

  /// `String.length`: UTF-16 code units (what most APIs call characters).
  final int utf16Units;

  /// Unicode scalar values (runes).
  final int codePoints;

  /// User-perceived characters (extended grapheme clusters).
  final int graphemes;
  final int words;
  final int uniqueWords;
  final int lines;
  final int blankLines;

  /// Length of the longest line in code points, and its 1-based number.
  final int longestLine;
  final int longestLineNumber;
  final int utf8Bytes;
  final int sentences;
  final int paragraphs;
  final int letters;
  final int digits;
  final int whitespace;
  final int other;
  final int nonAscii;
  final LineEnding lineEnding;
  final List<(String, int)> topWords;

  int get utf16Bytes => utf16Units * 2;

  /// Silent reading at 238 words per minute (Brysbaert, 2019).
  Duration get readingTime => Duration(milliseconds: (words / 238 * 60000).round());

  /// Speaking at 150 words per minute.
  Duration get speakingTime => Duration(milliseconds: (words / 150 * 60000).round());

  static String formatMinutes(Duration d) {
    if (d.inSeconds < 1) return d == Duration.zero ? '0 s' : '< 1 s';
    if (d.inMinutes < 1) return '${d.inSeconds} s';
    final s = d.inSeconds % 60;
    if (d.inHours < 1) return '${d.inMinutes} min${s == 0 ? '' : ' $s s'}';
    return '${d.inHours} h ${d.inMinutes % 60} min';
  }
}

abstract final class TextStatsCalculator {
  /// Above this size the tool computes in a background isolate.
  static const int isolateThreshold = 200000;

  static final RegExp _word = RegExp(
    r"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]|[\p{L}\p{N}\p{M}]+(?:['’._-][\p{L}\p{N}\p{M}]+)*",
    unicode: true,
  );
  static final RegExp _sentenceEnd = RegExp(r'[.!?…。！？]+(?=\s|$)', unicode: true);
  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _digit = RegExp(r'\p{N}', unicode: true);

  /// [compute] in a background isolate (static so the closure only
  /// captures [text]).
  static Future<TextStats> computeInBackground(String text) =>
      Isolate.run(() => compute(text), debugName: 'j3-textstats');

  static TextStats compute(String text) {
    var codePoints = 0, utf8Bytes = 0, letters = 0, digits = 0, whitespace = 0, other = 0, nonAscii = 0;
    for (final r in text.runes) {
      codePoints++;
      utf8Bytes += r < 0x80
          ? 1
          : r < 0x800
          ? 2
          : r < 0x10000
          ? 3
          : 4;
      if (r >= 0x80) nonAscii++;
      if (r == 0x20 || r == 0x09 || r == 0x0A || r == 0x0D || r == 0x0B || r == 0x0C || r == 0xA0 || r == 0x3000) {
        whitespace++;
      } else if (r < 0x80) {
        if ((r | 0x20) >= 0x61 && (r | 0x20) <= 0x7A) {
          letters++;
        } else if (r >= 0x30 && r <= 0x39) {
          digits++;
        } else {
          other++;
        }
      } else {
        final ch = String.fromCharCode(r);
        if (_letter.hasMatch(ch)) {
          letters++;
        } else if (_digit.hasMatch(ch)) {
          digits++;
        } else {
          other++;
        }
      }
    }

    // Lines: a trailing line break does not start a new (empty) line.
    var lineList = text.isEmpty ? const <String>[] : TextCodec.splitLines(text);
    if (lineList.length > 1 && lineList.last.isEmpty) lineList = lineList.sublist(0, lineList.length - 1);
    var blank = 0, longest = 0, longestAt = 0, paragraphs = 0;
    var inParagraph = false;
    for (var i = 0; i < lineList.length; i++) {
      final l = lineList[i];
      final isBlank = l.trim().isEmpty;
      if (isBlank) {
        blank++;
        inParagraph = false;
      } else if (!inParagraph) {
        paragraphs++;
        inParagraph = true;
      }
      final len = l.runes.length;
      if (len > longest) {
        longest = len;
        longestAt = i + 1;
      }
    }

    final counts = <String, int>{};
    var words = 0;
    for (final m in _word.allMatches(text)) {
      words++;
      final w = m.group(0)!.toLowerCase();
      counts[w] = (counts[w] ?? 0) + 1;
    }
    final top = counts.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });

    return TextStats(
      utf16Units: text.length,
      codePoints: codePoints,
      graphemes: text.characters.length,
      words: words,
      uniqueWords: counts.length,
      lines: lineList.length,
      blankLines: blank,
      longestLine: longest,
      longestLineNumber: longestAt,
      utf8Bytes: utf8Bytes,
      sentences: words == 0 ? 0 : _sentenceCount(text),
      paragraphs: paragraphs,
      letters: letters,
      digits: digits,
      whitespace: whitespace,
      other: other,
      nonAscii: nonAscii,
      lineEnding: TextCodec.detectLineEnding(text),
      topWords: [for (final e in top.take(10)) (e.key, e.value)],
    );
  }

  static int _sentenceCount(String text) {
    final n = _sentenceEnd.allMatches(text).length;
    // Text without final punctuation still ends a sentence.
    final trimmed = text.trimRight();
    final endsWithTerminator = _sentenceEnd.hasMatch(trimmed.isEmpty ? '' : trimmed.substring(trimmed.length - 1));
    return n + (endsWithTerminator ? 0 : 1);
  }
}
