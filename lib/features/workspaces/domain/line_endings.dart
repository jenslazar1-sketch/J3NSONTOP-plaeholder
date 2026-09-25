import '../../../core/utils/text_codec.dart';

/// Counts of each line terminator in a text.
class LineEndingStats {
  const LineEndingStats({required this.lf, required this.crlf, required this.cr});

  factory LineEndingStats.of(String text) {
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
    return LineEndingStats(lf: lf, crlf: crlf, cr: cr);
  }

  final int lf;
  final int crlf;
  final int cr;

  int get total => lf + crlf + cr;

  LineEnding get kind {
    final kinds = [lf > 0, crlf > 0, cr > 0].where((b) => b).length;
    if (kinds == 0) return LineEnding.none;
    if (kinds > 1) return LineEnding.mixed;
    if (crlf > 0) return LineEnding.crlf;
    if (cr > 0) return LineEnding.cr;
    return LineEnding.lf;
  }

  /// The most common concrete ending (LF when there are none).
  LineEnding get dominant {
    if (crlf >= lf && crlf >= cr && crlf > 0) return LineEnding.crlf;
    if (cr > lf && cr > 0) return LineEnding.cr;
    return LineEnding.lf;
  }

  String describe() => switch (kind) {
    LineEnding.none => 'None (single line)',
    LineEnding.mixed => 'Mixed (LF $lf, CRLF $crlf, CR $cr)',
    _ => '${kind.label} ($total)',
  };
}

abstract final class LineEndings {
  /// Converts every CRLF/CR to LF (the editor works on LF text).
  static String normalize(String text) => text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// Converts LF text to [ending] (mixed/none keep LF).
  static String apply(String lfText, LineEnding ending) => switch (ending) {
    LineEnding.crlf => lfText.replaceAll('\n', '\r\n'),
    LineEnding.cr => lfText.replaceAll('\n', '\r'),
    _ => lfText,
  };
}
