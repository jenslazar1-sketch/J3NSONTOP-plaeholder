import '../../../core/utils/text_codec.dart';

/// A 1-based line/column position (plus the character offset) in a text.
class SourceLocation {
  const SourceLocation({required this.offset, required this.line, required this.column});

  /// Computes line/column for [offset] with [TextCodec.lineColumn].
  factory SourceLocation.fromOffset(String text, int offset) {
    final clamped = offset.clamp(0, text.length);
    final (line, column) = TextCodec.lineColumn(text, clamped);
    return SourceLocation(offset: clamped, line: line, column: column);
  }

  /// Computes the offset for a 1-based [line] and [column].
  factory SourceLocation.fromLineColumn(String text, int line, int column) {
    var offset = 0;
    var current = 1;
    while (current < line && offset < text.length) {
      final c = text.codeUnitAt(offset);
      offset++;
      if (c == 10) {
        current++;
      } else if (c == 13) {
        if (offset < text.length && text.codeUnitAt(offset) == 10) offset++;
        current++;
      }
    }
    offset = (offset + column - 1).clamp(0, text.length);
    return SourceLocation(offset: offset, line: line, column: column);
  }

  final int offset;
  final int line;
  final int column;

  String get label => 'line $line, column $column';

  @override
  String toString() => '$line:$column';
}

/// An error with an optional position in the source text.
class LocatedError {
  const LocatedError(this.message, {this.location, this.snippet});

  /// Builds the error and its caret snippet from [text].
  factory LocatedError.at(String text, String message, SourceLocation? location) => LocatedError(
    message,
    location: location,
    snippet: location == null ? null : caretSnippet(text, location.line, location.column),
  );

  final String message;
  final SourceLocation? location;

  /// Multi-line excerpt with line numbers and a `^` under the column.
  final String? snippet;

  String describe() => location == null ? message : '${location!.label}: $message';

  @override
  String toString() => describe();
}

/// Renders the line containing [line]:[column] (plus [before] lines of
/// context) with a caret under the column. Very long lines are windowed
/// around the column so the caret stays visible.
String caretSnippet(String text, int line, int column, {int before = 1, int window = 72}) {
  final lines = TextCodec.splitLines(text);
  if (lines.isEmpty) return '';
  final target = line.clamp(1, lines.length);
  final first = (target - before).clamp(1, target);
  final gutter = '$target'.length;
  final b = StringBuffer();
  for (var n = first; n <= target; n++) {
    var content = lines[n - 1].replaceAll('\t', ' ');
    var caretCol = column;
    if (n == target && content.length > window) {
      final start = (column - window ~/ 2).clamp(0, content.length);
      final end = (start + window).clamp(0, content.length);
      content = '…${content.substring(start, end)}…';
      caretCol = column - start + 1;
    } else if (content.length > window) {
      content = '${content.substring(0, window)}…';
    }
    b.writeln('${'$n'.padLeft(gutter)} | $content');
    if (n == target) {
      b.write('${' ' * gutter} | ${' ' * (caretCol - 1).clamp(0, window + 2)}^');
    }
  }
  return b.toString();
}
