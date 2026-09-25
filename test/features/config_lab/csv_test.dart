import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/conversion_report.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/csv_codec.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';

void main() {
  group('parseCsv', () {
    test('quotes, escaped quotes, embedded delimiters and newlines', () {
      final t = parseCsv('id,name,notes\n1,"Sword, big","He said ""hi""\nsecond line"\n2,Shield,\n');
      expect(t.rows, [
        ['id', 'name', 'notes'],
        ['1', 'Sword, big', 'He said "hi"\nsecond line'],
        ['2', 'Shield', ''],
      ]);
      expect(t.rowLines, [1, 2, 4]);
      expect(t.diagnostics, isEmpty);
      expect(t.endsWithNewline, isTrue);
    });

    test('CRLF, BOM and missing final newline', () {
      final t = parseCsv('${String.fromCharCode(0xFEFF)}a,b\r\n1,2\r\n3,"x\r\ny"');
      expect(t.hadBom, isTrue);
      expect(t.lineEnding, '\r\n');
      expect(t.endsWithNewline, isFalse);
      expect(t.rows, [
        ['a', 'b'],
        ['1', '2'],
        ['3', 'x\r\ny'],
      ]);
    });

    test('blank lines are skipped and remembered', () {
      final t = parseCsv('a\n\nb\n\n');
      expect(t.rows, [
        ['a'],
        ['b'],
      ]);
      expect(t.blankLines, [2, 4]);
    });

    test('unterminated quote is an error with position', () {
      final t = parseCsv('a,b\n1,"open\n2,3\n');
      expect(t.hasErrors, isTrue);
      final e = t.diagnostics.single;
      expect((e.line, e.column), (2, 3));
      expect(t.rows.last.last, 'open\n2,3\n');
    });

    test('lenient warnings: text after closing quote, quote inside field', () {
      final t = parseCsv('"a"b,c"d\n');
      expect(t.rows.single, ['ab', 'c"d']);
      expect(t.diagnostics.map((d) => (d.line, d.column)), [(1, 4), (1, 7)]);
      expect(t.hasErrors, isFalse);
    });

    test('custom delimiter and quote', () {
      final t = parseCsv("a;'x;y';'it''s'\n", delimiter: ';', quote: "'");
      expect(t.rows.single, ['a', 'x;y', "it's"]);
    });

    test('trailing delimiter yields an empty last field', () {
      expect(parseCsv('a,b,\n').rows.single, ['a', 'b', '']);
    });
  });

  group('detectDelimiter', () {
    test('picks the consistent separator and respects quotes', () {
      expect(detectDelimiter('a,b,c\n1,2,3\n'), CsvDelimiter.comma);
      expect(detectDelimiter('a;b;c\n1;2,5;3\n'), CsvDelimiter.semicolon);
      expect(detectDelimiter('a\tb\n1\t2\n'), CsvDelimiter.tab);
      expect(detectDelimiter('a|b\n"x,y,z"|2\n'), CsvDelimiter.pipe);
      expect(detectDelimiter('single'), CsvDelimiter.comma);
    });
  });

  group('stats', () {
    test('ragged rows with lines and empty cells', () {
      final s = computeCsvStats(parseCsv('a,b,c\n1,,3\n4,5\n6,7,8,9\n'));
      expect(s.rows, 4);
      expect(s.columns, 4);
      expect(s.expectedColumns, 3);
      expect(s.raggedRows, [(2, 3, 2), (3, 4, 4)]);
      expect(s.emptyCells, 1);
      expect(s.totalCells, 12);
    });
  });

  group('CSV <-> TSV', () {
    test('lossless when nothing needs quoting; keeps CRLF and final newline', () {
      final t = parseCsv('a,b\r\n"x",y\r\n');
      final r = convertDelimited(t, fromDelimiter: ',', toDelimiter: '\t');
      expect(r.output, 'a\tb\r\nx\ty\r\n');
      expect(r.report.lossless, isTrue);
      expect(r.report.verified, isTrue);
    });

    test('fields containing the target delimiter or newlines are quoted and reported', () {
      final t = parseCsv('name,notes\n"tab\there","two\nlines"\n');
      final r = convertDelimited(t, fromDelimiter: ',', toDelimiter: '\t');
      expect(r.output, 'name\tnotes\n"tab\there"\t"two\nlines"\n');
      final quoted = r.report.ofKind(IssueKind.quotingAdded);
      expect(quoted, hasLength(2));
      expect(quoted.first.severity, IssueSeverity.loss);
      expect(quoted.first.path, 'row 2, column 1');
      expect(quoted.first.line, 2);
    });

    test('TSV -> CSV quoting is standard (note only)', () {
      final t = parseCsv('a\tb,c\n', delimiter: '\t');
      final r = convertDelimited(t, fromDelimiter: '\t', toDelimiter: ',');
      expect(r.output, 'a,"b,c"\n');
      expect(r.report.lossless, isTrue);
      expect(r.report.ofKind(IssueKind.quotingAdded).single.severity, IssueSeverity.note);
    });

    test('parse errors block conversion', () {
      final r = convertDelimited(parseCsv('"open'), fromDelimiter: ',', toDelimiter: '\t');
      expect(r.ok, isFalse);
    });
  });

  group('CSV -> JSON', () {
    const csv = 'id,name,price,active\n1,Potion,1.50,true\n2,"Sword",10,FALSE\n3,Key\n4,Gem,5,true,extra\n';

    test('objects with header, strings by default', () {
      final r = csvToJson(parseCsv(csv));
      expect(decodeJsonStrict(r.output!), [
        {'id': '1', 'name': 'Potion', 'price': '1.50', 'active': 'true'},
        {'id': '2', 'name': 'Sword', 'price': '10', 'active': 'FALSE'},
        {'id': '3', 'name': 'Key'},
        {'id': '4', 'name': 'Gem', 'price': '5', 'active': 'true', 'column_5': 'extra'},
      ]);
      expect(r.report.ofKind(IssueKind.missingCells).single.line, 4);
      expect(r.report.ofKind(IssueKind.extraCells).single.line, 5);
      expect(r.report.has(IssueKind.typesInferred), isFalse);
    });

    test('inference is opt-in and itemised', () {
      final r = csvToJson(parseCsv('a,b,c,d,e\n42,1.50,TRUE,null,007\n'), infer: true);
      expect(decodeJsonStrict(r.output!), [
        {'a': 42, 'b': 1.5, 'c': true, 'd': null, 'e': '007'},
      ]);
      final inferred = r.report.ofKind(IssueKind.typesInferred);
      expect(inferred.where((i) => i.severity == IssueSeverity.loss), hasLength(4));
      expect(inferred.any((i) => i.message.contains('leading zeros')), isTrue);
    });

    test('arrays shape is lossless', () {
      final r = csvToJson(parseCsv('a,b\n1\n'), shape: CsvJsonShape.arrays);
      expect(decodeJsonStrict(r.output!), [
        ['a', 'b'],
        ['1'],
      ]);
      expect(r.report.lossless, isTrue);
    });

    test('empty and duplicate headers are renamed and reported', () {
      final r = csvToJson(parseCsv('a,,a\n1,2,3\n'));
      expect(decodeJsonStrict(r.output!), [
        {'a': '1', 'column_2': '2', 'a_2': '3'},
      ]);
      expect(r.report.ofKind(IssueKind.headerRenamed), hasLength(2));
    });

    test('objects without a header are refused', () {
      expect(csvToJson(parseCsv('a\n'), header: false).ok, isFalse);
    });
  });

  group('JSON -> CSV', () {
    test('array of flat objects with union header', () {
      final r = jsonToCsv('[{"id": 1, "name": "Potion, small"}, {"id": 2, "extra": null}]');
      expect(r.ok, isTrue, reason: r.report.toText());
      expect(r.output, 'id,name,extra\n1,"Potion, small",\n2,,\n');
      expect(r.report.has(IssueKind.missingCells), isTrue);
      expect(r.report.has(IssueKind.nullsUnsupported), isTrue);
      expect(r.report.has(IssueKind.typesToText), isTrue);
      expect(r.report.verified, isTrue);
    });

    test('nested values are errors listing paths unless flattened', () {
      const json = '[{"id": 1, "stats": {"hp": 3, "tags": ["a", "b"]}}]';
      final strict = jsonToCsv(json);
      expect(strict.ok, isFalse);
      expect(strict.report.errors.single.path, r'$[0].stats');
      final flat = jsonToCsv(json, flatten: true);
      expect(flat.ok, isTrue, reason: flat.report.toText());
      expect(flat.output, 'id,stats.hp,stats.tags.0,stats.tags.1\n1,3,a,b\n');
      expect(flat.report.has(IssueKind.structureFlattened), isTrue);
    });

    test('arrays of arrays, TSV output, and invalid shapes', () {
      expect(jsonToCsv('[["a", 1], ["b\\tc", 2]]', delimiter: '\t').output, 'a\t1\n"b\tc"\t2\n');
      expect(jsonToCsv('{"a": 1}').ok, isFalse);
      expect(jsonToCsv('[1, 2]').ok, isFalse);
      expect(jsonToCsv('[[]]').ok, isFalse);
      expect(jsonToCsv('[{"a": [1]}, [1]]').ok, isFalse);
    });

    test('CSV -> JSON -> CSV round trip of strings', () {
      const csv = 'id,name\n1,"a,b"\n2,"say ""x"""\n';
      final json = csvToJson(parseCsv(csv));
      final back = jsonToCsv(json.output!);
      expect(back.output, csv);
    });
  });
}
