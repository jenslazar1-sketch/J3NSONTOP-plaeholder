import '../../../core/utils/text_codec.dart';
import 'text_files.dart';

/// Counts of each line terminator in a text.
class LineEndingCounts {
  const LineEndingCounts({required this.lf, required this.crlf, required this.cr});

  static const LineEndingCounts zero = LineEndingCounts(lf: 0, crlf: 0, cr: 0);

  final int lf;
  final int crlf;
  final int cr;

  int get total => lf + crlf + cr;

  /// More than one kind of terminator is present.
  bool get mixed => [lf, crlf, cr].where((n) => n > 0).length > 1;

  LineEnding get kind {
    if (total == 0) return LineEnding.none;
    if (mixed) return LineEnding.mixed;
    if (crlf > 0) return LineEnding.crlf;
    if (cr > 0) return LineEnding.cr;
    return LineEnding.lf;
  }

  /// The most frequent terminator (LF when there are none or on ties with LF).
  LineEnding get dominant {
    if (crlf > lf && crlf >= cr) return LineEnding.crlf;
    if (cr > lf && cr > crlf) return LineEnding.cr;
    return LineEnding.lf;
  }

  String describe() => total == 0 ? 'no line breaks' : 'LF $lf · CRLF $crlf · CR $cr${mixed ? ' (mixed)' : ''}';

  @override
  bool operator ==(Object other) => other is LineEndingCounts && other.lf == lf && other.crlf == crlf && other.cr == cr;

  @override
  int get hashCode => Object.hash(lf, crlf, cr);

  @override
  String toString() => describe();
}

/// Counts LF, CRLF and lone CR terminators.
LineEndingCounts countLineEndings(String text) {
  var lf = 0, crlf = 0, cr = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 13) {
      if (i + 1 < text.length && text.codeUnitAt(i + 1) == 10) {
        crlf++;
        i++;
      } else {
        cr++;
      }
    } else if (c == 10) {
      lf++;
    }
  }
  return LineEndingCounts(lf: lf, crlf: crlf, cr: cr);
}

/// Line-ending targets offered for conversion.
const List<LineEnding> lineEndingTargets = [LineEnding.lf, LineEnding.crlf, LineEnding.cr];

/// Replaces every terminator (LF, CRLF, CR) with [target]'s sequence.
String convertLineEndings(String text, LineEnding target) {
  assert(lineEndingTargets.contains(target), 'target must be LF, CRLF or CR');
  final seq = target.sequence;
  final out = StringBuffer();
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 13 || c == 10) {
      out.write(text.substring(start, i));
      out.write(seq);
      if (c == 13 && i + 1 < text.length && text.codeUnitAt(i + 1) == 10) i++;
      start = i + 1;
    }
  }
  out.write(text.substring(start));
  return out.toString();
}

/// Shows terminators as visible markers for previews: `«CRLF»`, `«LF»`,
/// `«CR»` (plain Latin-1 glyphs, available in every bundled font).
String visualizeLineEndings(String text, {int maxLines = 40}) {
  final out = StringBuffer();
  var lines = 0;
  var start = 0;
  for (var i = 0; i < text.length && lines < maxLines; i++) {
    final c = text.codeUnitAt(i);
    if (c == 13 || c == 10) {
      out.write(text.substring(start, i));
      if (c == 13 && i + 1 < text.length && text.codeUnitAt(i + 1) == 10) {
        out.write('«CRLF»');
        i++;
      } else {
        out.write(c == 13 ? '«CR»' : '«LF»');
      }
      out.write('\n');
      lines++;
      start = i + 1;
    }
  }
  if (lines < maxLines && start < text.length) out.write(text.substring(start));
  return out.toString();
}

/// Before/after counts of a line-ending conversion.
class LineEndingChange {
  const LineEndingChange(this.before, this.after);
  final LineEndingCounts before;
  final LineEndingCounts after;

  String describe() => before == after ? before.describe() : '${before.describe()} → ${after.describe()}';
}

/// File transform for [processTextFiles]: converts terminators and keeps
/// the file's encoding (UTF-8, UTF-8 BOM, UTF-16 LE/BE with BOM, Latin-1).
TextTransform<LineEndingChange> lineEndingTransform(LineEnding target) => (DecodedText d) {
  final before = countLineEndings(d.text);
  final converted = convertLineEndings(d.text, target);
  return TransformResult(converted, d.encoding, LineEndingChange(before, countLineEndings(converted)));
};
