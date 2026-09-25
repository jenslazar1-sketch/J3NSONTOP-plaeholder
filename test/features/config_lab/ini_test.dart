import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/conversion_report.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/ini_document.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';

const _settings =
    '; Neon Dungeon settings\r\n'
    'version = 3\r\n'
    '\r\n'
    '[Display]\r\n'
    '# resolution\r\n'
    'width=1920\r\n'
    'height = 1080\r\n'
    'title: "  Neon  "\r\n'
    'mode = fullscreen ; not a comment\r\n'
    '\r\n'
    '[Audio]\r\n'
    '  volume = 0.8\r\n'
    'muted = false\r\n';

void main() {
  group('parsing', () {
    test('line kinds, sections, keys, values, quotes', () {
      final doc = IniDocument.parse(_settings);
      expect(doc.hasErrors, isFalse);
      expect(doc.toText(), _settings);
      expect(doc.sectionNames, ['', 'Display', 'Audio']);
      final byKey = {for (final e in doc.entries) '${e.section}.${e.key}': e};
      expect(byKey['.version']!.value, '3');
      expect(byKey['Display.width']!.value, '1920');
      expect(byKey['Display.title']!.value, '  Neon  ');
      expect(byKey['Display.title']!.quote, '"');
      expect(byKey['Display.mode']!.value, 'fullscreen ; not a comment');
      expect(byKey['Audio.volume']!.value, '0.8');
      expect(doc.lines[0].kind, IniLineKind.comment);
      expect(doc.lines[4].kind, IniLineKind.comment);
      expect(doc.lines[2].kind, IniLineKind.blank);
      expect(doc.lines[3].kind, IniLineKind.section);
      expect(doc.lines.every((l) => l.eol == '\r\n'), isTrue);
    });

    test('invalid lines are errors with line numbers', () {
      final doc = IniDocument.parse('[ok]\njust text\n= novalue\n[broken\n[]\n[x] trailing\n');
      expect(doc.errors.map((e) => (e.line, e.message)), [
        (2, 'Not a section, comment or key=value line'),
        (3, 'Missing key before "="'),
        (4, 'Unterminated section header (missing "]")'),
        (5, 'Empty section name'),
        (6, 'Unexpected text after section header'),
      ]);
    });

    test('section header may carry a comment', () {
      final doc = IniDocument.parse('[Audio] ; sound\nx=1\n');
      expect(doc.hasErrors, isFalse);
      expect(doc.entries.single.section, 'Audio');
    });

    test('duplicates and case variants are warnings with line numbers', () {
      final doc = IniDocument.parse('[A]\nk=1\nk=2\nK=3\n[a]\n[A]\nk=4\n');
      final w = doc.warnings.map((d) => d.line).toList();
      expect(w, [3, 4, 5, 6, 7]);
      expect(doc.warnings.first.message, contains('first at line 2'));
      expect(doc.warnings[2].message, contains('differs only by case'));
      expect(doc.warnings[3].message, contains('also defined at line 1'));
    });

    test('BOM, CR-only endings and missing final newline are preserved', () {
      final text = '${String.fromCharCode(0xFEFF)}a=1\rb=2';
      final doc = IniDocument.parse(text);
      expect(doc.entries.map((e) => e.key), ['a', 'b']);
      expect(doc.toText(), text);
    });
  });

  group('lossless edits', () {
    test('setValue rewrites only that line, byte for byte elsewhere', () {
      final doc = IniDocument.parse(_settings);
      final width = doc.entries.firstWhere((e) => e.key == 'width');
      final edited = doc.setValue(width.index, '2560');
      final expected = _settings.replaceFirst('width=1920', 'width=2560');
      expect(edited.toText(), expected);
    });

    test('quoted values stay quoted; spacing preserved', () {
      final doc = IniDocument.parse(_settings);
      final title = doc.entries.firstWhere((e) => e.key == 'title');
      final edited = doc.setValue(title.index, 'Neon Dungeon');
      expect(edited.toText(), _settings.replaceFirst('title: "  Neon  "', 'title: "Neon Dungeon"'));
      final volume = doc.entries.firstWhere((e) => e.key == 'volume');
      expect(doc.setValue(volume.index, '1').toText(), _settings.replaceFirst('  volume = 0.8', '  volume = 1'));
    });

    test('values needing quotes get them; line breaks are rejected', () {
      final doc = IniDocument.parse('a = x\n');
      expect(doc.setValue(0, ' padded ').toText(), 'a = " padded "\n');
      expect(doc.setValue(0, '"quoted"').toText(), 'a = ""quoted""\n');
      expect(IniDocument.parse(doc.setValue(0, '"quoted"').toText()).entries.single.value, '"quoted"');
      expect(() => doc.setValue(0, 'a\nb'), throwsA(isA<IniEditError>()));
      expect(doc.setValue(0, '').toText(), 'a = \n');
    });

    test('addEntry inserts after the section\'s last entry using nearby style and EOL', () {
      final doc = IniDocument.parse(_settings);
      final added = doc.addEntry('Display', 'vsync', 'on');
      expect(
        added.toText(),
        _settings.replaceFirst(
          'mode = fullscreen ; not a comment\r\n',
          'mode = fullscreen ; not a comment\r\nvsync = on\r\n',
        ),
      );
      expect(() => added.addEntry('Display', 'vsync', 'off'), throwsA(isA<IniEditError>()));
      expect(() => doc.addEntry('Display', 'bad=key', 'x'), throwsA(isA<IniEditError>()));
    });

    test('addEntry to the global section and to a new section', () {
      final doc = IniDocument.parse('; c\n[S]\nx=1');
      // The comment directly above [S] belongs to it: the global key goes above.
      expect(doc.addEntry('', 'g', '1').toText(), 'g=1\n; c\n[S]\nx=1');
      final withHeader = IniDocument.parse('; file header\n\n; display\n[S]\n');
      expect(withHeader.addEntry('', 'g', '1').toText(), '; file header\n\ng = 1\n; display\n[S]\n');
      final withGlobal = IniDocument.parse('a=1\n\n[S]\n');
      expect(withGlobal.addEntry('', 'b', '2').toText(), 'a=1\nb=2\n\n[S]\n');
      expect(doc.addEntry('New', 'k', 'v').toText(), '; c\n[S]\nx=1\n\n[New]\nk=v');
    });

    test('adding after an unterminated last line gives it a line ending only', () {
      final doc = IniDocument.parse('[S]\r\nx=1');
      expect(doc.addEntry('S', 'y', '2').toText(), '[S]\r\nx=1\r\ny=2');
    });

    test('removeEntry removes exactly one line', () {
      final doc = IniDocument.parse(_settings);
      final height = doc.entries.firstWhere((e) => e.key == 'height');
      expect(doc.removeEntry(height.index).toText(), _settings.replaceFirst('height = 1080\r\n', ''));
      final last = IniDocument.parse('a=1\nb=2');
      expect(last.removeEntry(1).toText(), 'a=1');
    });

    test('addSection validates names', () {
      final doc = IniDocument.parse('a=1\n');
      expect(doc.addSection('Video').toText(), 'a=1\n\n[Video]\n');
      expect(() => doc.addSection('bad]'), throwsA(isA<IniEditError>()));
      expect(() => doc.addSection('Video').addSection('Video'), throwsA(isA<IniEditError>()));
    });
  });

  group('INI -> JSON', () {
    test('strings by default, comments and quotes reported', () {
      final r = iniToJson(IniDocument.parse(_settings));
      expect(r.ok, isTrue);
      expect(decodeJsonStrict(r.output!), {
        'version': '3',
        'Display': {'width': '1920', 'height': '1080', 'title': '  Neon  ', 'mode': 'fullscreen ; not a comment'},
        'Audio': {'volume': '0.8', 'muted': 'false'},
      });
      expect(r.report.ofKind(IssueKind.commentsDropped).map((i) => i.line), [1, 5]);
      expect(r.report.ofKind(IssueKind.quotesRemoved).single.severity, IssueSeverity.note);
      expect(r.report.has(IssueKind.typesInferred), isFalse);
    });

    test('opt-in inference is itemised as a representation change', () {
      final r = iniToJson(IniDocument.parse('[S]\na=42\nb=1.50\nc=TRUE\nd=007\ne="12"\nf=text\n'), inferTypes: true);
      expect(decodeJsonStrict(r.output!), {
        'S': {'a': 42, 'b': 1.5, 'c': true, 'd': '007', 'e': '12', 'f': 'text'},
      });
      final inferred = r.report.ofKind(IssueKind.typesInferred);
      expect(inferred.map((i) => i.line), [2, 3, 4]);
      expect(inferred[1].message, contains('formatting of "1.50" is not kept'));
      expect(r.report.lossless, isFalse);
    });

    test('duplicates merge with last-wins and are reported', () {
      final r = iniToJson(IniDocument.parse('[A]\nx=1\n[B]\ny=1\n[A]\nx=2\n'));
      expect(decodeJsonStrict(r.output!), {
        'A': {'x': '2'},
        'B': {'y': '1'},
      });
      expect(r.report.ofKind(IssueKind.duplicateKeys), hasLength(2));
    });

    test('invalid lines refuse conversion', () {
      final r = iniToJson(IniDocument.parse('oops\n'));
      expect(r.ok, isFalse);
      expect(r.report.errors.single.line, 1);
    });

    test('lossless when there are no comments or quotes', () {
      final r = iniToJson(IniDocument.parse('g=1\n[S]\nk=v\n'));
      expect(r.report.lossless, isTrue);
    });
  });

  group('JSON -> INI', () {
    test('object of sections, verified', () {
      final r = jsonToIni('{"g": "x", "Display": {"width": 1920, "full": true, "name": " pad "}, "Empty": {}}');
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.output, 'g = x\n\n[Display]\nwidth = 1920\nfull = true\nname = " pad "\n\n[Empty]\n');
      expect(r.report.verified, isTrue);
      expect(r.report.has(IssueKind.typesToText), isTrue);
      expect(r.report.has(IssueKind.quotingAdded), isTrue);
    });

    test('nested values, nulls, arrays and bad names are itemised errors', () {
      final r = jsonToIni('{"S": {"deep": {"x": 1}, "list": [1], "nil": null, "bad=key": 1}, "top": [1]}');
      expect(r.ok, isFalse);
      final paths = r.report.errors.map((e) => e.path).toList();
      expect(paths, containsAll([r'$.S.deep', r'$.S.list', r'$.S.nil', r'$.S["bad=key"]', r'$.top']));
    });

    test('global scalars after sections are reordered (reported)', () {
      final r = jsonToIni('{"S": {"a": "1"}, "late": "x"}');
      expect(r.ok, isTrue);
      expect(r.output, 'late = x\n\n[S]\na = 1\n');
      expect(r.report.has(IssueKind.keyOrderChanged), isTrue);
    });

    test('top-level must be an object', () {
      expect(jsonToIni('[1]').ok, isFalse);
    });

    test('INI -> JSON -> INI keeps the data', () {
      final json = iniToJson(IniDocument.parse('a=1\n[S]\nk=v w\n'));
      final back = jsonToIni(json.output!);
      expect(back.ok, isTrue);
      expect(back.output, 'a = 1\n\n[S]\nk = v w\n');
    });
  });
}
