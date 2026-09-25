import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/terminal/domain/completion.dart';
import 'package:j3nsontop_multitool/features/terminal/domain/history_cursor.dart';
import 'package:j3nsontop_multitool/features/terminal/domain/suggest.dart';

import '../../helpers/harness.dart';
import 'terminal_test_support.dart';

void main() {
  group('levenshtein / didYouMean', () {
    test('edit distance', () {
      expect(levenshtein('kitten', 'sitting'), 3);
      expect(levenshtein('', 'abc'), 3);
      expect(levenshtein('abc', ''), 3);
      expect(levenshtein('same', 'same'), 0);
      expect(levenshtein('hepl', 'help'), 2);
    });

    test('suggests close names, closest first, and prefixes', () {
      const names = ['help', 'hash', 'history', 'open', 'tools', 'theme'];
      expect(didYouMean('hepl', names), ['help']);
      expect(didYouMean('opne', names), ['open']);
      expect(didYouMean('tool', names), ['tools']);
      expect(didYouMean('hist', names), ['history', 'hash']);
      expect(didYouMean('zzzzzz', names), isEmpty);
      expect(didYouMean('', names), isEmpty);
      expect(didYouMean('HELP', names), isEmpty, reason: 'exact (case-insensitive) matches are not suggestions');
      expect(joinAlternatives(['a', 'b', 'c']), 'a, b or c');
    });
  });

  group('HistoryCursor', () {
    test('walks back and forth and restores the draft', () {
      final c = HistoryCursor();
      const h = ['a', 'b', 'c'];
      expect(c.next(h), isNull);
      expect(c.previous(h, 'draft'), 'c');
      expect(c.browsing, isTrue);
      expect(c.previous(h, 'c'), 'b');
      expect(c.previous(h, 'b'), 'a');
      expect(c.previous(h, 'a'), isNull);
      expect(c.next(h), 'b');
      expect(c.next(h), 'c');
      expect(c.next(h), 'draft');
      expect(c.browsing, isFalse);
      expect(c.next(h), isNull);
      expect(HistoryCursor().previous(const [], 'x'), isNull);
    });

    test('reset stops browsing', () {
      final c = HistoryCursor()..previous(const ['a'], 'x');
      c.reset();
      expect(c.browsing, isFalse);
      expect(c.previous(const ['a', 'b'], ''), 'b');
    });
  });

  group('quoting helpers', () {
    test('quoteArg round-trips through the tokenizer', () {
      expect(quoteArg('plain'), 'plain');
      expect(quoteArg('a b'), '"a b"');
      expect(quoteArg('a b', close: false), '"a b');
      for (final v in ['My Mod Project', r'say "hi" \o/', "it's"]) {
        expect(tokenizeCommandLine('x ${quoteArg(v)}'), ['x', v]);
      }
    });

    test('commonPrefix is case-insensitive', () {
      expect(commonPrefix(['clear', 'cls']), 'cl');
      expect(commonPrefix(['Alpha', 'alps']), 'Alp');
      expect(commonPrefix(['x']), 'x');
      expect(commonPrefix([]), '');
    });
  });

  group('TerminalCompleter', () {
    late TestEnv env;
    late TerminalDriver t;
    late TerminalCompleter completer;

    setUp(() async {
      env = await TestEnv.create();
      final registry = buildTerminalRegistry(extra: const [BoomCommand()]);
      t = TerminalDriver(env, registry: registry);
      completer = TerminalCompleter(
        t.container.read(toolRegistryProvider),
        CommandContext(read: t.container.read, navigate: (_) {}, token: CancellationToken.none),
      );
    });

    tearDown(() async {
      await t.dispose();
      await disposeEnv(env);
    });

    CompletionResult tab(String text, [int? caret]) => completer.complete(text, caret ?? text.length);

    test('command names: unique match gets a trailing space', () {
      final r = tab('he');
      expect(r.text, 'help ');
      expect(r.caret, 5);
      expect(r.candidates, isEmpty);
      expect(tab('hi').text, 'history ');
      expect(tab('ve').text, 'version ', reason: 'aliases complete too');
    });

    test('several matches: common prefix, candidates listed', () {
      final c = tab('c');
      expect(c.text, 'cl');
      expect(c.candidates, ['clear', 'cls']);
      final h = tab('h');
      expect(h.text, 'h');
      expect(h.candidates, ['hash', 'help', 'history']);
      expect(tab('').candidates, containsAll(['about', 'echo', 'help', 'open', 'ws']));
    });

    test('hidden commands and unknown commands give nothing', () {
      final r = tab('sk');
      expect(r.text, 'sk');
      expect(r.candidates, isEmpty);
      expect(r.partial, 'sk');
      expect(tab('nosuch arg').candidates, isEmpty);
      expect(tab('boom x').candidates, isEmpty, reason: 'a throwing completer is contained');
    });

    test('argument values from CommandArg.values and complete()', () {
      expect(tab('theme ac').text, 'theme accent ');
      expect(tab('theme accent c').text, 'theme accent crimson ');
      expect(tab('theme accent ').candidates, ['neon', 'crimson', 'infrared', 'ember']);
      expect(tab('theme motion r').text, 'theme motion reduced ');
      expect(tab('help op').text, 'help open ');
      expect(tab('tools d').text, 'tools dev ');
      expect(tab('history --').text, 'history --failed ');
      final hash = tab('hash abc s');
      expect(hash.text, 'hash abc sha');
      expect(hash.candidates, ['sha256', 'sha1']);
    });

    test('open completes sections and tool ids', () {
      expect(tab('open sett').text, 'open settings ');
      expect(tab('open dev.').text, 'open dev.base64 ');
      final dev = tab('open dev');
      expect(dev.text, 'open dev');
      expect(dev.candidates, ['dev', 'dev.base64']);
    });

    test('workspace names with spaces are quoted', () async {
      final ctl = t.container.read(workspacesProvider.notifier);
      await ctl.addAppOwned('My Game');
      await ctl.addAppOwned('My Mod Project');
      final first = tab('ws use My');
      expect(first.text, 'ws use "My ');
      expect(first.candidates, unorderedEquals(['My Mod Project', 'My Game']));
      final second = tab('${first.text}M');
      expect(second.text, 'ws use "My Mod Project" ');
      final accepted = completer.accept('ws use ', 7, 'My Game');
      expect(accepted.text, 'ws use "My Game" ');
      expect(tokenizeCommandLine(accepted.text), ['ws', 'use', 'My Game']);
    });

    test('completes the word at the caret, keeping the rest', () {
      final r = tab('hel world', 3);
      expect(r.text, 'help world');
      expect(r.caret, 5);
    });
  });
}
