enum CaseStyle {
  camel('camelCase'),
  pascal('PascalCase'),
  snake('snake_case'),
  kebab('kebab-case'),
  constant('CONSTANT_CASE'),
  title('Title Case'),
  sentence('Sentence case'),
  lower('lower case'),
  upper('UPPER CASE'),
  dot('dot.case'),
  path('path/case');

  const CaseStyle(this.label);
  final String label;
}

class CaseOptions {
  const CaseOptions({this.splitDigits = false, this.keepAcronyms = false});

  /// Treat letter/digit transitions as word boundaries ("utf8" -> "utf 8").
  final bool splitDigits;

  /// Keep all-caps words (HTTP, JSON) upper case in camel/Pascal/Title.
  final bool keepAcronyms;
}

abstract final class CaseTools {
  static bool _isUpper(String ch) => ch.toUpperCase() == ch && ch.toLowerCase() != ch;

  static bool _isLower(String ch) => ch.toLowerCase() == ch && ch.toUpperCase() != ch;

  static final RegExp _alnum = RegExp(r'[\p{L}\p{N}\p{M}]', unicode: true);
  static final RegExp _digit = RegExp(r'\p{N}', unicode: true);

  /// Splits an identifier or phrase into words.
  ///
  /// * any non letter/digit character separates words (`_ - . / space`);
  /// * lower-to-upper starts a word: `fooBar` -> foo, Bar;
  /// * an upper-case run followed by lower case keeps the last capital for
  ///   the next word: `HTTPServer` -> HTTP, Server;
  /// * digits stay attached (`utf8Decoder` -> utf8, Decoder) unless
  ///   [CaseOptions.splitDigits];
  /// * letters without case (CJK) behave like lower case.
  static List<String> words(String input, [CaseOptions options = const CaseOptions()]) {
    final chars = input.runes.map(String.fromCharCode).toList();
    final words = <String>[];
    final current = StringBuffer();
    // Class of the previous char: 0 = none, 1 = upper, 2 = lower/caseless, 3 = digit
    var prev = 0;
    void flush() {
      if (current.isNotEmpty) {
        words.add(current.toString());
        current.clear();
      }
      prev = 0;
    }

    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final code = ch.codeUnitAt(0);
      final ascii = code < 0x80;
      final isAlnum = ascii
          ? (code >= 0x30 && code <= 0x39) || ((code | 0x20) >= 0x61 && (code | 0x20) <= 0x7A)
          : _alnum.hasMatch(ch);
      if (!isAlnum) {
        flush();
        continue;
      }
      final isDigit = ascii ? code >= 0x30 && code <= 0x39 : _digit.hasMatch(ch);
      final cls = isDigit
          ? 3
          : _isUpper(ch)
          ? 1
          : 2;
      var boundary = false;
      if (prev != 0) {
        if (cls == 1 && (prev == 2 || prev == 3)) boundary = true;
        if (cls == 1 && prev == 1 && i + 1 < chars.length) {
          final next = chars[i + 1];
          if (_isLower(next)) boundary = true;
        }
        if (options.splitDigits && ((cls == 3) != (prev == 3))) boundary = true;
      }
      if (boundary) {
        words.add(current.toString());
        current.clear();
      }
      current.write(ch);
      prev = cls;
    }
    flush();
    return words;
  }

  static String _cap(String w) {
    if (w.isEmpty) return w;
    final runes = w.runes.toList();
    return String.fromCharCode(runes.first).toUpperCase() + String.fromCharCodes(runes.skip(1)).toLowerCase();
  }

  static bool _isAcronym(String w) => w.runes.length > 1 && w == w.toUpperCase() && w != w.toLowerCase();

  /// Converts one line of text.
  static String convertLine(String line, CaseStyle style, [CaseOptions options = const CaseOptions()]) {
    switch (style) {
      case CaseStyle.lower:
        return line.toLowerCase();
      case CaseStyle.upper:
        return line.toUpperCase();
      default:
    }
    final ws = words(line, options);
    if (ws.isEmpty) return '';
    String capOrAcronym(String w) => options.keepAcronyms && _isAcronym(w) ? w : _cap(w);
    return switch (style) {
      CaseStyle.camel => [ws.first.toLowerCase(), ...ws.skip(1).map(capOrAcronym)].join(),
      CaseStyle.pascal => ws.map(capOrAcronym).join(),
      CaseStyle.snake => ws.map((w) => w.toLowerCase()).join('_'),
      CaseStyle.kebab => ws.map((w) => w.toLowerCase()).join('-'),
      CaseStyle.constant => ws.map((w) => w.toUpperCase()).join('_'),
      CaseStyle.title => ws.map(capOrAcronym).join(' '),
      CaseStyle.sentence => [
        capOrAcronym(ws.first),
        ...ws.skip(1).map((w) => options.keepAcronyms && _isAcronym(w) ? w : w.toLowerCase()),
      ].join(' '),
      CaseStyle.dot => ws.map((w) => w.toLowerCase()).join('.'),
      CaseStyle.path => ws.map((w) => w.toLowerCase()).join('/'),
      CaseStyle.lower || CaseStyle.upper => line,
    };
  }

  /// Converts every line of [text] independently (lists of identifiers).
  static String convert(String text, CaseStyle style, [CaseOptions options = const CaseOptions()]) => text
      .split('\n')
      .map((l) => convertLine(l.endsWith('\r') ? l.substring(0, l.length - 1) : l, style, options))
      .join('\n');
}
