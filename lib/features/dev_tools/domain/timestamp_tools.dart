import 'common.dart';

enum EpochUnit {
  seconds('s', 'Unix seconds', 9),
  milliseconds('ms', 'Unix milliseconds', 6),
  microseconds('us', 'Unix microseconds', 3),
  nanoseconds('ns', 'Unix nanoseconds', 0);

  const EpochUnit(this.short, this.label, this.nanoExponent);
  final String short;
  final String label;

  /// Nanoseconds per unit = 10^[nanoExponent].
  final int nanoExponent;

  BigInt get nanos => BigInt.from(10).pow(nanoExponent);

  static EpochUnit? parse(String s) => switch (s.toLowerCase()) {
    's' || 'sec' || 'seconds' => seconds,
    'ms' || 'millis' || 'milliseconds' => milliseconds,
    'us' || 'µs' || 'micros' || 'microseconds' => microseconds,
    'ns' || 'nanos' || 'nanoseconds' => nanoseconds,
    _ => null,
  };
}

/// How the converter reads its input.
enum TimestampInput {
  auto('Auto'),
  seconds('Unix s'),
  milliseconds('Unix ms'),
  microseconds('Unix µs'),
  nanoseconds('Unix ns'),
  iso('ISO-8601'),
  rfc2822('RFC 2822 / HTTP');

  const TimestampInput(this.label);
  final String label;

  EpochUnit? get unit => switch (this) {
    seconds => EpochUnit.seconds,
    milliseconds => EpochUnit.milliseconds,
    microseconds => EpochUnit.microseconds,
    nanoseconds => EpochUnit.nanoseconds,
    _ => null,
  };
}

/// An exact instant parsed from user input.
class ParsedInstant {
  const ParsedInstant({
    required this.utc,
    required this.interpretation,
    this.subMicroNanos = 0,
    this.offset,
    this.notes = const [],
  });

  /// The instant (microsecond precision), in UTC.
  final DateTime utc;

  /// 0-999 nanoseconds below [utc]'s microsecond precision.
  final int subMicroNanos;

  /// e.g. "Unix milliseconds (auto-detected by magnitude)".
  final String interpretation;

  /// UTC offset written in the input (ISO/RFC 2822), if any.
  final Duration? offset;
  final List<String> notes;

  BigInt get epochNanos => BigInt.from(utc.microsecondsSinceEpoch) * BigInt.from(1000) + BigInt.from(subMicroNanos);
}

abstract final class Timestamps {
  static const List<String> weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const List<String> months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
  ];

  /// DateTime supports +-8.64e15 ms around the epoch.
  static final BigInt _maxMicros = BigInt.parse('8640000000000000000');

  /// Auto-detection thresholds on |value|: below 1e11 -> seconds (until
  /// year 5138), below 1e14 -> milliseconds, below 1e17 -> microseconds,
  /// otherwise nanoseconds.
  static EpochUnit detectUnit(BigInt magnitude) {
    final m = magnitude.abs();
    if (m < BigInt.from(100000000000)) return EpochUnit.seconds;
    if (m < BigInt.from(100000000000000)) return EpochUnit.milliseconds;
    if (m < BigInt.from(100000000000000000)) return EpochUnit.microseconds;
    return EpochUnit.nanoseconds;
  }

  static final RegExp _numeric = RegExp(r'^\s*[+-]?[0-9][0-9_]*(\.[0-9]+)?\s*$');

  static bool looksNumeric(String s) => _numeric.hasMatch(s);

  /// A month name means RFC 2822 / HTTP date syntax.
  static final RegExp _monthName = RegExp(
    r'(^|[^a-z])(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*',
    caseSensitive: false,
  );

  /// Parses [input] according to [kind]. Inputs without an offset are local
  /// time unless [assumeUtc]. Throws [InputError] with a position.
  static ParsedInstant parse(String input, {TimestampInput kind = TimestampInput.auto, bool assumeUtc = false}) {
    if (input.trim().isEmpty) throw const InputError('Enter a timestamp or date');
    switch (kind) {
      case TimestampInput.auto:
        if (looksNumeric(input)) return parseEpoch(input);
        final t = input.trimLeft();
        final first = t.isEmpty ? 0 : t.codeUnitAt(0) | 0x20;
        final startsWithLetter = first >= 0x61 && first <= 0x7A;
        return startsWithLetter || _monthName.hasMatch(input)
            ? parseRfc2822(input)
            : parseIso(input, assumeUtc: assumeUtc);
      case TimestampInput.iso:
        return parseIso(input, assumeUtc: assumeUtc);
      case TimestampInput.rfc2822:
        return parseRfc2822(input);
      case TimestampInput.seconds:
      case TimestampInput.milliseconds:
      case TimestampInput.microseconds:
      case TimestampInput.nanoseconds:
        return parseEpoch(input, unit: kind.unit);
    }
  }

  /// Parses a Unix timestamp (optionally fractional, `_` separators allowed).
  static ParsedInstant parseEpoch(String input, {EpochUnit? unit}) {
    var i = 0;
    while (i < input.length && input.codeUnitAt(i) <= 0x20) {
      i++;
    }
    var negative = false;
    if (i < input.length && (input[i] == '-' || input[i] == '+')) {
      negative = input[i] == '-';
      i++;
    }
    final intDigits = StringBuffer();
    final fracDigits = StringBuffer();
    var inFraction = false;
    var end = input.length;
    while (end > i && input.codeUnitAt(end - 1) <= 0x20) {
      end--;
    }
    for (; i < end; i++) {
      final c = input.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        (inFraction ? fracDigits : intDigits).writeCharCode(c);
      } else if (c == 0x5F && !inFraction && intDigits.isNotEmpty) {
        continue;
      } else if (c == 0x2E && !inFraction) {
        inFraction = true;
      } else {
        throw InputError(
          'Unexpected ${describeCharAt(input, i)} in a Unix timestamp',
          offset: i,
          source: input,
          hint: 'Unix timestamps are numbers such as 1758829267 or 1758829267123. Pick ISO-8601 for dates.',
        );
      }
    }
    if (intDigits.isEmpty) throw InputError('Expected digits', offset: i, source: input);
    if (inFraction && fracDigits.isEmpty) {
      throw InputError('Expected digits after "."', offset: end, source: input);
    }
    final whole = BigInt.parse(intDigits.toString());
    final detected = unit == null;
    final u = unit ?? detectUnit(whole);
    var frac = fracDigits.toString();
    final notes = <String>[];
    if (frac.length > u.nanoExponent) {
      if (u.nanoExponent == 0) {
        notes.add('Fractional nanoseconds were dropped.');
      } else if (frac.substring(u.nanoExponent).replaceAll('0', '').isNotEmpty) {
        notes.add('Digits beyond nanosecond precision were dropped.');
      }
      frac = frac.substring(0, u.nanoExponent);
    }
    var ns = whole * u.nanos + (frac.isEmpty ? BigInt.zero : BigInt.parse(frac.padRight(u.nanoExponent, '0')));
    if (negative) ns = -ns;
    return _fromNanos(
      ns,
      interpretation: '${u.label}${detected ? ' (auto-detected by magnitude)' : ''}',
      notes: notes,
      source: input,
    );
  }

  static ParsedInstant _fromNanos(
    BigInt ns, {
    required String interpretation,
    List<String> notes = const [],
    String? source,
  }) {
    final thousand = BigInt.from(1000);
    var micros = ns ~/ thousand;
    var rem = ns - micros * thousand;
    if (rem < BigInt.zero) {
      micros -= BigInt.one;
      rem += thousand;
    }
    if (micros.abs() > _maxMicros) {
      throw InputError(
        'Outside the supported range (about 271,821 BC to 275,760 AD)',
        hint: 'Check the unit: this value is too large for $interpretation.',
        source: source,
      );
    }
    return ParsedInstant(
      utc: DateTime.fromMicrosecondsSinceEpoch(micros.toInt(), isUtc: true),
      subMicroNanos: rem.toInt(),
      interpretation: interpretation,
      notes: notes,
    );
  }

  static int daysInMonth(int y, int m) => DateTime.utc(y, m + 1, 0).day;

  /// Strict ISO-8601 / RFC 3339 parser: `2026-09-25`, `2026-09-25T19:41:07Z`,
  /// `2026-09-25 19:41:07.123456789+02:00`, basic `20260925T194107Z`, a
  /// comma decimal sign and `UTC`/`GMT` suffixes.
  static ParsedInstant parseIso(String input, {bool assumeUtc = false}) {
    final s = _Scanner(input);
    s.skipSpaces();
    var sign = 1;
    int year;
    if (s.peekIs('+') || s.peekIs('-')) {
      sign = s.take() == '-' ? -1 : 1;
      year = s.digitsBetween(4, 6, 'year');
    } else {
      year = s.digits(4, 'a 4-digit year');
    }
    year *= sign;
    final extended = s.accept('-');
    final monthAt = s.pos;
    final month = s.digits(2, 'a 2-digit month');
    if (month < 1 || month > 12) throw s.errorAt(monthAt, 'Month $month is out of range (01-12)');
    if (extended) s.expect('-', '"-" between month and day');
    final dayAt = s.pos;
    final day = s.digits(2, 'a 2-digit day');
    final dim = daysInMonth(year, month);
    if (day < 1 || day > dim) {
      throw s.errorAt(
        dayAt,
        'Day $day is out of range for ${months[month - 1]} $year (01-${dim.toString().padLeft(2, '0')})',
      );
    }
    var hour = 0, minute = 0, second = 0, nanos = 0;
    var hasTime = false;
    if (s.peekIs('T') || s.peekIs('t') || (s.peekIs(' ') && s.isDigitAt(s.pos + 1))) {
      s.take();
      hasTime = true;
      final hourAt = s.pos;
      hour = s.digits(2, 'a 2-digit hour');
      var hasSeconds = false;
      if (s.accept(':') || s.isDigitAt(s.pos)) {
        final minAt = s.pos;
        minute = s.digits(2, 'a 2-digit minute');
        if (minute > 59) throw s.errorAt(minAt, 'Minute $minute is out of range (00-59)');
        if (s.accept(':') || s.isDigitAt(s.pos)) {
          final secAt = s.pos;
          second = s.digits(2, 'a 2-digit second');
          hasSeconds = true;
          if (second == 60) {
            throw s.errorAt(secAt, 'Leap second :60 cannot be represented; use :59.999 or the next second');
          }
          if (second > 59) throw s.errorAt(secAt, 'Second $second is out of range (00-59)');
        }
      }
      if (hasSeconds && (s.peekIs('.') || s.peekIs(','))) {
        s.take();
        final fracAt = s.pos;
        final f = s.digitRun();
        if (f.isEmpty) throw s.errorAt(fracAt, 'Expected digits after the decimal sign');
        nanos = int.parse(f.length > 9 ? f.substring(0, 9) : f.padRight(9, '0'));
      }
      if (hour == 24 && (minute != 0 || second != 0 || nanos != 0)) {
        throw s.errorAt(hourAt, 'Hour 24 is only valid as 24:00:00 (end of day)');
      }
      if (hour > 24) throw s.errorAt(hourAt, 'Hour $hour is out of range (00-23)');
    }
    s.skipSpaces();
    Duration? offset;
    if (s.peekIs('Z') || s.peekIs('z')) {
      s.take();
      offset = Duration.zero;
    } else if (s.acceptWord('UTC') || s.acceptWord('GMT')) {
      offset = Duration.zero;
    } else if (s.peekIs('+') || s.peekIs('-')) {
      final offAt = s.pos;
      final neg = s.take() == '-';
      final oh = s.digits(2, 'a 2-digit offset hour');
      var om = 0;
      if (s.accept(':') || s.isDigitAt(s.pos)) om = s.digits(2, 'a 2-digit offset minute');
      if (oh > 23 || om > 59) throw s.errorAt(offAt, 'UTC offset out of range (max +-23:59)');
      offset = Duration(hours: oh, minutes: om) * (neg ? -1 : 1);
    }
    s.skipSpaces();
    if (!s.atEnd) throw s.errorAt(s.pos, 'Unexpected ${describeCharAt(input, s.pos)}');
    final notes = <String>[];
    DateTime utc;
    final micros = nanos ~/ 1000;
    if (offset != null) {
      utc = DateTime.utc(year, month, day, hour, minute, second, 0, micros).subtract(offset);
    } else if (assumeUtc) {
      utc = DateTime.utc(year, month, day, hour, minute, second, 0, micros);
      notes.add('No UTC offset in the input: interpreted as UTC.');
    } else {
      utc = DateTime(year, month, day, hour, minute, second, 0, micros).toUtc();
      notes.add('No UTC offset in the input: interpreted as local time.');
    }
    return ParsedInstant(
      utc: utc,
      subMicroNanos: nanos % 1000,
      interpretation: hasTime ? 'ISO-8601 date and time' : 'ISO-8601 date (midnight)',
      offset: offset,
      notes: notes,
    );
  }

  static const Map<String, int> _zones = {
    'UT': 0, 'UTC': 0, 'GMT': 0, 'Z': 0, //
    'EST': -5, 'EDT': -4, 'CST': -6, 'CDT': -5, 'MST': -7, 'MDT': -6, 'PST': -8, 'PDT': -7,
  };

  static int? _monthIndex(String t) {
    final l = t.toLowerCase();
    if (l.length < 3) return null;
    for (var i = 0; i < 12; i++) {
      if (l.startsWith(months[i].toLowerCase())) return i + 1;
    }
    return null;
  }

  static int? _weekdayIndex(String t) {
    final l = t.toLowerCase();
    if (l.length < 3) return null;
    for (var i = 0; i < 7; i++) {
      final w = weekdays[i].toLowerCase();
      if (l == w || l == w.substring(0, 3)) return i + 1;
    }
    return null;
  }

  /// Parses RFC 2822 / RFC 5322 dates (`Fri, 25 Sep 2026 19:41:07 +0200`),
  /// HTTP dates in all three RFC 9110 forms (IMF-fixdate, RFC 850 and
  /// asctime) and North American zone abbreviations.
  static ParsedInstant parseRfc2822(String input) {
    final tokens = <(String, int)>[];
    final re = RegExp(r'[^\s,]+');
    for (final m in re.allMatches(input)) {
      if (m.group(0)!.startsWith('(')) break; // trailing comment, e.g. "(PDT)"
      tokens.add((m.group(0)!, m.start));
    }
    if (tokens.isEmpty) throw const InputError('Enter a date');
    var idx = 0;
    int? weekday;
    final wd = _weekdayIndex(tokens[0].$1);
    if (wd != null) {
      weekday = wd;
      idx++;
    }
    InputError err(String msg, int? at) => InputError(msg, offset: at, source: input);
    (String, int) next(String what) {
      if (idx >= tokens.length) throw err('Missing $what', input.length);
      return tokens[idx++];
    }

    int number((String, int) tok, String what, {int? min, int? max}) {
      final v = int.tryParse(tok.$1);
      if (v == null) throw err('Expected $what, found "${tok.$1}"', tok.$2);
      if ((min != null && v < min) || (max != null && v > max)) throw err('$what $v is out of range', tok.$2);
      return v;
    }

    int year((String, int) tok) {
      final v = number(tok, 'year');
      if (tok.$1.length == 2) return v < 50 ? 2000 + v : 1900 + v;
      if (tok.$1.length == 3) return 1900 + v;
      return v;
    }

    int day, month, y;
    (String, int) timeTok;
    var asctime = false;
    final first = next('day');
    if (first.$1.contains('-')) {
      // RFC 850: 06-Nov-94
      final parts = first.$1.split('-');
      if (parts.length != 3) throw err('Expected DD-Mon-YY, found "${first.$1}"', first.$2);
      day = number((parts[0], first.$2), 'day', min: 1, max: 31);
      final mi = _monthIndex(parts[1]);
      if (mi == null) throw err('Unknown month "${parts[1]}"', first.$2 + parts[0].length + 1);
      month = mi;
      y = year((parts[2], first.$2 + parts[0].length + parts[1].length + 2));
      timeTok = next('time');
    } else if (_monthIndex(first.$1) != null) {
      // asctime: Nov  6 08:49:37 1994
      asctime = true;
      month = _monthIndex(first.$1)!;
      day = number(next('day'), 'day', min: 1, max: 31);
      timeTok = next('time');
      y = year(next('year'));
    } else {
      day = number(first, 'day', min: 1, max: 31);
      final mt = next('month');
      final mi = _monthIndex(mt.$1);
      if (mi == null) throw err('Unknown month "${mt.$1}"', mt.$2);
      month = mi;
      y = year(next('year'));
      timeTok = next('time');
    }
    final dim = daysInMonth(y, month);
    if (day > dim) throw err('Day $day is out of range for ${months[month - 1]} $y', tokens.first.$2);
    final tp = timeTok.$1.split(':');
    if (tp.length < 2 || tp.length > 3) throw err('Expected HH:MM[:SS], found "${timeTok.$1}"', timeTok.$2);
    final hour = number((tp[0], timeTok.$2), 'hour', min: 0, max: 23);
    final minute = number((tp[1], timeTok.$2 + tp[0].length + 1), 'minute', min: 0, max: 59);
    final second = tp.length == 3
        ? number((tp[2], timeTok.$2 + tp[0].length + tp[1].length + 2), 'second', min: 0, max: 60)
        : 0;
    final notes = <String>[];
    var sec = second;
    if (sec == 60) {
      sec = 59;
      notes.add('Leap second :60 clamped to :59.');
    }
    Duration offset = Duration.zero;
    if (!asctime && idx < tokens.length) {
      final z = tokens[idx++];
      final zu = z.$1.toUpperCase();
      if (_zones.containsKey(zu)) {
        offset = Duration(hours: _zones[zu]!);
      } else if (RegExp(r'^[+-]\d{4}$').hasMatch(z.$1)) {
        final h = int.parse(z.$1.substring(1, 3)), m = int.parse(z.$1.substring(3));
        if (m > 59) throw err('Zone minutes out of range in "${z.$1}"', z.$2);
        offset = Duration(hours: h, minutes: m) * (z.$1.startsWith('-') ? -1 : 1);
      } else {
        throw err('Unknown time zone "${z.$1}" (use +hhmm, GMT or UT)', z.$2);
      }
    } else if (!asctime) {
      notes.add('No zone given: assumed GMT.');
    }
    if (idx < tokens.length) throw err('Unexpected "${tokens[idx].$1}"', tokens[idx].$2);
    final utc = DateTime.utc(y, month, day, hour, minute, sec).subtract(offset);
    final local = utc.add(offset);
    if (weekday != null && weekday != local.weekday) {
      notes.add('The weekday in the input does not match the date (it is a ${weekdays[local.weekday - 1]}).');
    }
    return ParsedInstant(
      utc: utc,
      interpretation: asctime ? 'HTTP date (asctime)' : 'RFC 2822 / HTTP date',
      offset: offset,
      notes: notes,
    );
  }

  // ---------------------------------------------------------------- output

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _year(int y) =>
      y >= 0 && y <= 9999 ? y.toString().padLeft(4, '0') : '${y < 0 ? '-' : '+'}${y.abs().toString().padLeft(6, '0')}';

  static String _fraction(DateTime t, int subMicroNanos) {
    final us = t.millisecond * 1000 + t.microsecond;
    if (subMicroNanos != 0) return '.${(us * 1000 + subMicroNanos).toString().padLeft(9, '0')}';
    if (t.microsecond != 0) return '.${us.toString().padLeft(6, '0')}';
    return '.${t.millisecond.toString().padLeft(3, '0')}';
  }

  static String offsetLabel(Duration offset, {bool colon = true}) {
    final neg = offset.isNegative;
    final m = offset.inMinutes.abs();
    return '${neg ? '-' : '+'}${_two(m ~/ 60)}${colon ? ':' : ''}${_two(m % 60)}';
  }

  /// `2026-09-25T19:41:07.123Z`
  static String isoUtc(DateTime utc, {int subMicroNanos = 0}) {
    final t = utc.toUtc();
    return '${_year(t.year)}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
        '${_fraction(t, subMicroNanos)}Z';
  }

  /// Wall-clock time at [offset] with the offset appended.
  static String isoWithOffset(DateTime utc, Duration offset, {int subMicroNanos = 0}) {
    final t = utc.toUtc().add(offset);
    return '${_year(t.year)}-${_two(t.month)}-${_two(t.day)}T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}'
        '${_fraction(t, subMicroNanos)}${offsetLabel(offset)}';
  }

  /// `Fri, 25 Sep 2026 21:41:07 +0200`
  static String rfc2822(DateTime utc, {Duration offset = Duration.zero}) {
    final t = utc.toUtc().add(offset);
    return '${weekdays[t.weekday - 1].substring(0, 3)}, ${_two(t.day)} ${months[t.month - 1]} ${_year(t.year)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} ${offsetLabel(offset, colon: false)}';
  }

  /// RFC 9110 IMF-fixdate: `Fri, 25 Sep 2026 19:41:07 GMT`
  static String httpDate(DateTime utc) {
    final t = utc.toUtc();
    return '${weekdays[t.weekday - 1].substring(0, 3)}, ${_two(t.day)} ${months[t.month - 1]} ${_year(t.year)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)} GMT';
  }

  /// Decimal value of [nanos] in [unit] with trailing zeros trimmed.
  static String epochIn(BigInt nanos, EpochUnit unit) {
    final div = unit.nanos;
    final neg = nanos.isNegative;
    final abs = nanos.abs();
    final whole = abs ~/ div;
    final rem = abs - whole * div;
    var s = whole.toString();
    if (rem > BigInt.zero) {
      s += '.${rem.toString().padLeft(unit.nanoExponent, '0').replaceFirst(RegExp(r'0+$'), '')}';
    }
    return neg ? '-$s' : s;
  }

  static String _unit(int n, String unit) => '$n $unit${n == 1 ? '' : 's'}';

  /// "in 3 days, 4 hours", "2 minutes, 5 seconds ago", "now".
  static String relative(DateTime t, DateTime now) {
    final future = t.isAfter(now);
    final a = (future ? now : t).toUtc(), b = (future ? t : now).toUtc();
    if (b.difference(a).inSeconds == 0) return 'now';
    // Calendar-aware years and months, then exact days/hours/minutes/seconds.
    DateTime addMonths(DateTime d, int m) {
      final y = d.year + (d.month - 1 + m) ~/ 12;
      final mo = (d.month - 1 + m) % 12 + 1;
      final day = d.day > daysInMonth(y, mo) ? daysInMonth(y, mo) : d.day;
      return DateTime.utc(y, mo, day, d.hour, d.minute, d.second, d.millisecond, d.microsecond);
    }

    var months = (b.year - a.year) * 12 + (b.month - a.month);
    if (months > 0 && addMonths(a, months).isAfter(b)) months--;
    final rest = b.difference(addMonths(a, months));
    final values = [
      ('year', months ~/ 12),
      ('month', months % 12),
      ('day', rest.inDays),
      ('hour', rest.inHours % 24),
      ('minute', rest.inMinutes % 60),
      ('second', rest.inSeconds % 60),
    ];
    final parts = [
      for (final (name, n) in values)
        if (n > 0) _unit(n, name),
    ].take(2).join(', ');
    return future ? 'in $parts' : '$parts ago';
  }

  static int _p(int y) => (y + (y / 4).floor() - (y / 100).floor() + (y / 400).floor()) % 7;

  static int weeksInYear(int y) => _p(y) == 4 || _p(y - 1) == 3 ? 53 : 52;

  /// ISO-8601 week-numbering (year, week) for a calendar date.
  static (int, int) isoWeek(int y, int m, int d) {
    final date = DateTime.utc(y, m, d);
    final ordinal = date.difference(DateTime.utc(y, 1, 1)).inDays + 1;
    final week = (ordinal - date.weekday + 10) ~/ 7;
    if (week < 1) return (y - 1, weeksInYear(y - 1));
    if (week > weeksInYear(y)) return (y + 1, 1);
    return (y, week);
  }

  static int dayOfYear(int y, int m, int d) => DateTime.utc(y, m, d).difference(DateTime.utc(y, 1, 1)).inDays + 1;

  /// Calendar description of the wall-clock date at [offset].
  static String calendarLine(DateTime utc, Duration offset) {
    final t = utc.toUtc().add(offset);
    final (wy, w) = isoWeek(t.year, t.month, t.day);
    return '${weekdays[t.weekday - 1]}, ISO week $wy-W${_two(w)}-${t.weekday}, '
        'day ${dayOfYear(t.year, t.month, t.day)} of ${t.year}';
  }

  /// All representations of [p] as label/value rows (shared by the tool
  /// and the `ts` terminal command). [localOffset] defaults to the device
  /// offset at that instant.
  static List<(String, String)> describe(ParsedInstant p, DateTime now, {Duration? localOffset, String? zoneName}) {
    final ns = p.epochNanos;
    final local = localOffset ?? p.utc.toLocal().timeZoneOffset;
    final zone = zoneName ?? p.utc.toLocal().timeZoneName;
    return [
      ('Unix seconds', epochIn(ns, EpochUnit.seconds)),
      ('Unix milliseconds', epochIn(ns, EpochUnit.milliseconds)),
      ('Unix microseconds', epochIn(ns, EpochUnit.microseconds)),
      ('Unix nanoseconds', ns.toString()),
      ('ISO-8601 UTC', isoUtc(p.utc, subMicroNanos: p.subMicroNanos)),
      ('ISO-8601 local', '${isoWithOffset(p.utc, local, subMicroNanos: p.subMicroNanos)} ($zone)'),
      if (p.offset != null && p.offset != Duration.zero && p.offset != local)
        ('ISO-8601 as written', isoWithOffset(p.utc, p.offset!, subMicroNanos: p.subMicroNanos)),
      ('RFC 2822', rfc2822(p.utc, offset: local)),
      ('HTTP date', httpDate(p.utc)),
      ('Relative', relative(p.utc, now)),
      ('Local calendar', calendarLine(p.utc, local)),
      ('UTC calendar', calendarLine(p.utc, Duration.zero)),
    ];
  }
}

class _Scanner {
  _Scanner(this.src);
  final String src;
  int pos = 0;

  bool get atEnd => pos >= src.length;

  bool peekIs(String c) => pos < src.length && src[pos] == c;

  bool isDigitAt(int i) => i < src.length && src.codeUnitAt(i) >= 0x30 && src.codeUnitAt(i) <= 0x39;

  String take() => src[pos++];

  bool accept(String c) {
    if (peekIs(c)) {
      pos++;
      return true;
    }
    return false;
  }

  bool acceptWord(String w) {
    if (src.length - pos >= w.length && src.substring(pos, pos + w.length).toUpperCase() == w) {
      pos += w.length;
      return true;
    }
    return false;
  }

  void skipSpaces() {
    while (pos < src.length && src.codeUnitAt(pos) <= 0x20) {
      pos++;
    }
  }

  InputError errorAt(int at, String message) => InputError(
    message,
    offset: at,
    source: src,
    hint: 'Examples: 2026-09-25, 2026-09-25T19:41:07Z, 2026-09-25 21:41:07.5+02:00',
  );

  void expect(String c, String what) {
    if (!accept(c)) throw errorAt(pos, 'Expected $what, found ${describeCharAt(src, pos)}');
  }

  int digits(int count, String what) {
    final start = pos;
    for (var i = 0; i < count; i++) {
      if (!isDigitAt(pos)) throw errorAt(pos, 'Expected $what, found ${describeCharAt(src, pos)}');
      pos++;
    }
    return int.parse(src.substring(start, pos));
  }

  int digitsBetween(int min, int max, String what) {
    final start = pos;
    while (pos - start < max && isDigitAt(pos)) {
      pos++;
    }
    if (pos - start < min) throw errorAt(pos, 'Expected a $min-$max digit $what');
    return int.parse(src.substring(start, pos));
  }

  String digitRun() {
    final start = pos;
    while (isDigitAt(pos)) {
      pos++;
    }
    return src.substring(start, pos);
  }
}
