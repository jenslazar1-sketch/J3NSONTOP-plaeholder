/// Large inputs (> 256 KiB) take the isolate paths. These tests make sure
/// those paths work end to end (closures are sendable, results come back).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/features/config_lab/config_lab_module.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_tools.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/compare/compare_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/csv/csv_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/json_studio/json_studio_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/presets/presets_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/save_editor/save_editor_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/yaml/yaml_controller.dart';

import '../../helpers/harness.dart';

String _bigJson() {
  final items = [for (var i = 0; i < 6000; i++) '{"id": $i, "name": "item-$i", "tags": ["a", "b"], "ok": true}'];
  return '{"items": [${items.join(', ')}]}';
}

void main() {
  late TestEnv env;
  late ProviderContainer c;
  setUp(() async {
    env = await TestEnv.create();
    c = env.container(modules: [configLabModule]);
  });
  tearDown(() async {
    c.dispose();
    await env.dispose();
  });

  test('JSON Studio: large text is marked stale, then validated and formatted off the UI thread', () async {
    final text = _bigJson();
    expect(text.length, greaterThan(kSyncParseLimit));
    final input = c.read(draftTextProvider(kJsonInputKey))..text = text;
    final ctrl = c.read(jsonStudioProvider.notifier);
    ctrl.textChanged(text);
    expect(c.read(jsonStudioProvider).stale, isTrue);
    final a = await ctrl.validate();
    expect(a.valid, isTrue);
    expect(c.read(jsonStudioProvider).usable, isTrue);
    expect(await ctrl.minify(), isTrue);
    expect(input.text, startsWith('{"items":[{"id":0,'));
  });

  test('YAML -> JSON conversion of a large document', () async {
    final yaml = StringBuffer();
    for (var i = 0; i < 12000; i++) {
      yaml.writeln('key$i: value number $i');
    }
    c.read(draftTextProvider(kYamlInputKey)).text = yaml.toString();
    final r = await c.read(yamlLabProvider.notifier).convertToJson();
    expect(r.ok, isTrue);
    expect((decodeJsonStrict(r.output!)! as Map).length, 12000);
  });

  test('CSV conversion and analysis of a large table', () async {
    final csv = StringBuffer('id,name,price\n');
    for (var i = 0; i < 20000; i++) {
      csv.writeln('$i,item $i,${i * 3}');
    }
    c.read(draftTextProvider(kCsvInputKey)).text = csv.toString();
    final a = await c.read(csvLabProvider.notifier).analyze();
    expect(a.stats.rows, 20001);
    final r = await c.read(csvLabProvider.notifier).convert();
    expect(r.ok, isTrue);
    expect((decodeJsonStrict(r.output!)! as List).length, 20000);
  });

  test('Compare of large documents', () async {
    final a = _bigJson();
    c.read(draftTextProvider(kCompareAKey)).text = a;
    c.read(draftTextProvider(kCompareBKey)).text = a.replaceFirst('"item-5"', '"renamed"');
    final r = await c.read(compareProvider.notifier).compare();
    expect(r.semantic!.changes.single.pathLabel, r'$.items[5].name');
  });

  test('Preset preview of a large document', () async {
    c.read(draftTextProvider(kPresetsTargetKey)).text = _bigJson();
    final preview = await c.read(presetsProvider.notifier).preview();
    expect(preview, isNotNull);
    expect(preview!.semantic.added, greaterThan(0));
  });

  test('Save editor parses large raw JSON off the UI thread', () async {
    c.read(draftTextProvider(kSaveRawKey)).text = _bigJson();
    await c.read(saveEditorProvider.notifier).rawChanged();
    final s = c.read(saveEditorProvider);
    expect(s.hasData, isTrue);
    expect(s.positions['/items/5/name'], isNotNull);
  });
}
