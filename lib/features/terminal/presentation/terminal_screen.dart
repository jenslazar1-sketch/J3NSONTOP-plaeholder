import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/commands/terminal_command.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/storage/user_data.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/tools/tool_registry.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/completion.dart';
import '../domain/history_cursor.dart';
import 'terminal_session.dart';

/// The Terminal tool page.
class TerminalScreen extends StatelessWidget {
  const TerminalScreen({super.key});

  @override
  Widget build(BuildContext context) => const ToolScaffold(toolId: kTerminalToolId, body: TerminalView());
}

/// Commands offered as quick chips on touch devices / small screens.
const List<String> kTerminalQuickCommands = ['help', 'tools', 'open', 'history', 'ws', 'clear'];

/// Output, prompt and input of the internal command interface.
class TerminalView extends ConsumerStatefulWidget {
  const TerminalView({super.key});

  @override
  ConsumerState<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends ConsumerState<TerminalView> {
  final FocusNode _inputFocus = FocusNode(debugLabel: 'terminal input');
  final ScrollController _scroll = ScrollController();
  final HistoryCursor _history = HistoryCursor();
  late final TextEditingController _input = ref.read(draftTextProvider(kTerminalInputDraftKey));

  /// Completion candidates shown in the suggestion row.
  List<String> _candidates = const [];

  /// Set when Tab found nothing (the word that had no completions).
  String? _noMatch;

  /// Follow new output unless the user scrolled up.
  bool _stick = true;
  bool _scrollScheduled = false;
  bool _showJump = false;
  bool _inputFocused = false;
  bool? _wasActive;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _inputFocus.addListener(_onFocusChange);
    ref.listenManual<Object?>(
      draftValueProvider(kTerminalPendingCommandKey),
      (_, next) => _schedulePending(next),
      fireImmediately: true,
    );
    _scrollToBottom();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The shell keeps tool pages alive offstage with tickers disabled; focus
    // the prompt whenever the terminal becomes the visible tool (desktop).
    final active = TickerMode.valuesOf(context).enabled;
    if (active && _wasActive != true && ref.read(capabilitiesProvider).supports(Capability.keyboardShortcuts)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && TickerMode.valuesOf(context).enabled) _inputFocus.requestFocus();
      });
    }
    _wasActive = active;
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _inputFocus.removeListener(_onFocusChange);
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  TerminalSession get _session => ref.read(terminalSessionProvider.notifier);

  // ---------------------------------------------------------------- running

  void _schedulePending(Object? value) {
    if (value is! String || value.trim().isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = draftValueProvider(kTerminalPendingCommandKey);
      if (ref.read(key) != value) return; // already consumed
      ref.read(key.notifier).set(null);
      if (_session.isRunning) {
        _session.writeLines([TermLine.warn('Not run (a command is still running): $value')]);
        return;
      }
      _run(value);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _run(String line) {
    _stick = true;
    if (_showJump) setState(() => _showJump = false);
    unawaited(_session.submit(line, navigate: _navigate));
  }

  void _submit() {
    if (_session.isRunning) return; // keep the draft; the spinner row explains how to cancel
    final line = _input.text;
    _input.clear();
    _history.reset();
    _clearSuggestions();
    _run(line);
    _inputFocus.requestFocus();
  }

  void _navigate(String route) {
    if (!mounted) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) {
      _session.writeLines([TermLine.warn('Navigation is not available in this view.')]);
      return;
    }
    router.go(route);
  }

  void _clearScreen() {
    _session.clear();
    _stick = true;
    if (_showJump) setState(() => _showJump = false);
  }

  /// Ctrl+C: cancel the running command, or abandon the current line.
  /// Returns false when the input has a selection (so Ctrl+C copies it).
  bool _interrupt() {
    if (_session.isRunning) {
      _session.cancel();
      return true;
    }
    final sel = _input.selection;
    if (sel.isValid && !sel.isCollapsed) return false;
    _session.interrupt(_input.text);
    _input.clear();
    _history.reset();
    _clearSuggestions();
    return true;
  }

  /// Esc: close suggestions first, then clear the input.
  bool _escape() {
    if (_candidates.isNotEmpty || _noMatch != null) {
      _clearSuggestions();
      return true;
    }
    if (_input.text.isNotEmpty) {
      _input.clear();
      _history.reset();
      return true;
    }
    return false;
  }

  // ------------------------------------------------------ history/complete

  void _setInput(String text) {
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _clearSuggestions();
  }

  void _historyPrevious() {
    final v = _history.previous(ref.read(userDataProvider).commandHistory, _input.text);
    if (v != null) _setInput(v);
    _inputFocus.requestFocus();
  }

  void _historyNext() {
    final v = _history.next(ref.read(userDataProvider).commandHistory);
    if (v != null) _setInput(v);
    _inputFocus.requestFocus();
  }

  TerminalCompleter _completer() => TerminalCompleter(
    ref.read(toolRegistryProvider),
    CommandContext(read: ref.read, navigate: (_) {}, token: CancellationToken.none),
  );

  int get _caret {
    final sel = _input.selection;
    return sel.isValid ? sel.extentOffset : _input.text.length;
  }

  void _complete() {
    final before = _input.value;
    final r = _completer().complete(before.text, _caret);
    _input.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.caret),
    );
    _history.reset();
    final nothing = r.candidates.isEmpty && r.text == before.text;
    setState(() {
      _candidates = r.candidates;
      _noMatch = nothing ? r.partial : null;
    });
    _inputFocus.requestFocus();
  }

  void _accept(String candidate) {
    final r = _completer().accept(_input.text, _caret, candidate);
    _input.value = TextEditingValue(
      text: r.text,
      selection: TextSelection.collapsed(offset: r.caret),
    );
    _clearSuggestions();
    _inputFocus.requestFocus();
  }

  void _insertCommand(String name) {
    _setInput('$name ');
    _history.reset();
    _inputFocus.requestFocus();
  }

  void _clearSuggestions() {
    if (_candidates.isEmpty && _noMatch == null) return;
    setState(() {
      _candidates = const [];
      _noMatch = null;
    });
  }

  void _onEdited(String _) {
    _history.reset();
    _clearSuggestions();
  }

  // ------------------------------------------------------------------- keys

  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final down = event is KeyDownEvent;
    final key = event.logicalKey;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && !kb.isAltPressed && !kb.isShiftPressed) {
      if (key == LogicalKeyboardKey.keyL) {
        if (down) _clearScreen();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyC && down) {
        return _interrupt() ? KeyEventResult.handled : KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    }
    if (ctrl || kb.isAltPressed || kb.isShiftPressed) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (down) _submit();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _historyPrevious();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _historyNext();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      if (down) _complete();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && down) {
      return _escape() ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  /// Keys pressed while something else in the terminal has focus (output
  /// selection, toolbar buttons): Ctrl+L / Ctrl+C still work, and typing a
  /// character jumps back to the prompt.
  KeyEventResult _onBodyKey(FocusNode node, KeyEvent event) {
    if (_inputFocus.hasFocus || event is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyL) {
      _clearScreen();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyC && _session.isRunning) {
      _session.cancel();
      return KeyEventResult.handled;
    }
    if (ctrl || kb.isAltPressed) return KeyEventResult.ignored;
    final ch = event.character;
    if (ch != null && ch.length == 1 && ch.trim().isNotEmpty && ch.codeUnitAt(0) >= 0x20 && ch.codeUnitAt(0) != 0x7f) {
      _setInput('${_input.text}$ch');
      _history.reset();
      _inputFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ----------------------------------------------------------------- scroll

  void _onFocusChange() {
    if (_inputFocus.hasFocus != _inputFocused) setState(() => _inputFocused = _inputFocus.hasFocus);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom = _scroll.position.extentAfter < 24;
    _stick = atBottom;
    if (_showJump == atBottom) setState(() => _showJump = !atBottom);
  }

  /// Jumps to the newest output after layout. Repeats a few frames because
  /// lazily built rows only reveal their real height once laid out.
  void _scrollToBottom([int attempts = 4]) {
    if (_scrollScheduled && attempts == 4) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if ((p.maxScrollExtent - p.pixels).abs() > 0.5) {
        _scroll.jumpTo(p.maxScrollExtent);
        if (attempts > 1) _scrollToBottom(attempts - 1);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // ---------------------------------------------------------------- actions

  Future<void> _copyAll() async {
    final s = ref.read(terminalSessionProvider);
    await ref.read(fileAccessProvider).copyText(s.plainText);
    ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied ${s.lineCount} lines of terminal output');
  }

  Future<void> _export() async {
    final text = ref.read(terminalSessionProvider).plainText;
    await saveOutput(
      context,
      ref,
      suggestedName: 'terminal-${Fmt.stamp(DateTime.now())}.txt',
      bytes: Uint8List.fromList(utf8.encode('$text\n')),
      mimeType: 'text/plain',
      toolId: kTerminalToolId,
    );
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(terminalSessionProvider);
    ref.listen(terminalSessionProvider, (_, _) {
      if (_stick) _scrollToBottom();
    });
    final registry = ref.watch(toolRegistryProvider);
    final workspace = ref.watch(activeWorkspaceProvider);
    final keyboard = ref.watch(capabilitiesProvider).supports(Capability.keyboardShortcuts);
    final prompt = TerminalSession.promptFor(workspace?.name);
    final scaler = MediaQuery.textScalerOf(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final showKeys = !keyboard || screenWidth < J3Breakpoints.compact;
    final showSuggestions = _candidates.isNotEmpty || _noMatch != null;
    final rowHeight = math.max(52.0, scaler.scale(12) * 1.4 + 26);

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onBodyKey,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 520;
          final extras = <Widget>[
            if (showSuggestions) ...[const SizedBox(height: J3Space.sm), _suggestionRow(rowHeight)],
            if (showKeys) ...[const SizedBox(height: J3Space.sm), _keysRow(registry, rowHeight)],
          ];
          final toolbarHeight = math.max(48.0, scaler.scale(12) * 1.4 + 16);
          final inputHeight = math.max(48.0, scaler.scale(13.5) * 1.45 + 30);
          final fixed =
              toolbarHeight +
              inputHeight +
              4 +
              (showSuggestions ? rowHeight + J3Space.sm : 0) +
              (showKeys ? rowHeight + J3Space.sm : 0);
          const minOutput = 120.0;
          Widget window({double? outputHeight}) =>
              _window(session: session, prompt: prompt, narrow: narrow, keyboard: keyboard, outputHeight: outputHeight);
          if (constraints.maxHeight.isFinite && constraints.maxHeight < fixed + minOutput) {
            // Very short viewport (small phone, large text, soft keyboard):
            // scroll the whole terminal and give the output a fixed height.
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [window(outputHeight: 200), ...extras],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: window()),
              ...extras,
            ],
          );
        },
      ),
    );
  }

  Widget _window({
    required TerminalState session,
    required String prompt,
    required bool narrow,
    required bool keyboard,
    double? outputHeight,
  }) {
    final fx = context.effects;
    final output = _output(session, keyboard);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: J3Colors.background,
        borderRadius: J3Radius.medium,
        border: Border.all(
          color: _inputFocused ? fx.accentColor.withValues(alpha: 0.85) : fx.accentColor.withValues(alpha: 0.35),
          width: _inputFocused ? 1.5 : 1,
        ),
        boxShadow: _inputFocused && fx.glow
            ? [
                BoxShadow(
                  color: fx.accentColor.withValues(alpha: 0.10 + 0.10 * fx.intensity),
                  blurRadius: fx.glowBlur(18),
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: J3Radius.medium,
        child: Column(
          mainAxisSize: outputHeight == null ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(session, prompt),
            const Divider(height: 1),
            if (outputHeight == null) Expanded(child: output) else SizedBox(height: outputHeight, child: output),
            const Divider(height: 1),
            _inputRow(prompt, narrow: narrow, running: session.isRunning, keyboard: keyboard),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(TerminalState s, String prompt) {
    final fx = context.effects;
    return Container(
      color: J3Colors.surface,
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.only(left: J3Space.md, right: J3Space.xs),
      child: Row(
        children: [
          Icon(Icons.terminal, size: 16, color: fx.accentText),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text(
              '$prompt  |  ${Fmt.count(s.lineCount, 'line')}',
              style: J3Type.codeSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (s.isRunning)
            const Flexible(
              child: Padding(
                padding: EdgeInsets.only(left: J3Space.xs),
                child: StatusBadge(kind: StatusKind.running, text: 'RUNNING', dense: true),
              ),
            ),
          IconButton(
            tooltip: 'Copy all output',
            onPressed: s.rows.isEmpty ? null : _copyAll,
            icon: const Icon(Icons.copy_all_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'Export output (.txt)',
            onPressed: s.rows.isEmpty ? null : _export,
            icon: const Icon(Icons.save_alt_rounded, size: 20),
          ),
          IconButton(
            tooltip: 'Clear screen (Ctrl+L)',
            onPressed: _clearScreen,
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _output(TerminalState s, bool keyboard) {
    final dropped = s.droppedLines > 0 ? 1 : 0;
    final count = dropped + s.rows.length + (s.isRunning ? 1 : 0);
    return Stack(
      children: [
        Positioned.fill(
          child: SelectionArea(
            child: NotificationListener<ScrollMetricsNotification>(
              // The viewport shrinks when the suggestion row or the soft
              // keyboard appears, and grows with output: stay pinned.
              onNotification: (n) {
                if (_stick && n.metrics.extentAfter > 0.5) _scrollToBottom();
                return false;
              },
              child: Scrollbar(
                controller: _scroll,
                child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(J3Space.md, J3Space.sm, J3Space.md, J3Space.md),
                  itemCount: count,
                  itemBuilder: (context, index) {
                    var i = index;
                    if (dropped == 1) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: J3Space.xs),
                          child: Text(
                            '... ${s.droppedLines} earlier lines dropped '
                            '(scrollback keeps the last ${TerminalSession.scrollbackLimit} lines)',
                            style: J3Type.code.copyWith(color: J3Colors.textMuted),
                          ),
                        );
                      }
                      i -= 1;
                    }
                    if (i < s.rows.length) return TerminalRowView(row: s.rows[i]);
                    return _runningRow(s.running ?? '', keyboard);
                  },
                ),
              ),
            ),
          ),
        ),
        if (_showJump)
          Positioned(
            right: J3Space.sm,
            bottom: J3Space.sm,
            child: _TermKey(
              icon: Icons.vertical_align_bottom,
              tooltip: 'Scroll to latest output',
              filled: true,
              onTap: () {
                _stick = true;
                setState(() => _showJump = false);
                _scrollToBottom();
              },
            ),
          ),
      ],
    );
  }

  Widget _runningRow(String line, bool keyboard) {
    final fx = context.effects;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 14,
            child: fx.reduceMotion
                ? Icon(Icons.hourglass_top, size: 14, color: fx.accentText)
                : CircularProgressIndicator(strokeWidth: 2, color: fx.accentColor),
          ),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Text(
              'running: $line  (${keyboard ? 'Ctrl+C or ' : ''}Cancel to stop)',
              style: J3Type.code.copyWith(color: fx.accentText),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            onPressed: () => _session.cancel(),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _inputRow(String prompt, {required bool narrow, required bool running, required bool keyboard}) {
    final fx = context.effects;
    final promptStyle = J3Type.code.copyWith(color: fx.accentText, fontWeight: FontWeight.w700);
    return Container(
      color: J3Colors.inputFill,
      padding: const EdgeInsets.only(left: J3Space.md, right: J3Space.xs),
      constraints: const BoxConstraints(minHeight: 48),
      child: Row(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Text(narrow ? r'$' : prompt, style: promptStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: J3Space.sm),
          Expanded(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onInputKey,
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                style: J3Type.code.copyWith(color: J3Colors.text),
                cursorColor: fx.accentColor,
                autocorrect: false,
                enableSuggestions: false,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                maxLines: 1,
                onChanged: _onEdited,
                onSubmitted: (_) => _submit(),
                // Keep the focus on the prompt after running a command.
                onEditingComplete: () {},
                decoration: InputDecoration(
                  hintText: running
                      ? 'running... ${keyboard ? 'Ctrl+C' : 'Cancel'} to stop'
                      : 'type a command (try help)',
                  hintStyle: J3Type.code.copyWith(color: J3Colors.textMuted),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Run command (Enter)',
            onPressed: running ? null : _submit,
            icon: Icon(Icons.keyboard_return, color: running ? J3Colors.textDisabled : fx.accentText),
          ),
        ],
      ),
    );
  }

  Widget _suggestionRow(double height) {
    if (_noMatch != null) {
      final word = _noMatch!;
      return Container(
        height: height,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: J3Space.sm),
        child: Text(
          word.isEmpty ? 'No completions here.' : 'No completions for "$word".',
          style: J3Type.codeSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    const shownMax = 60;
    final shown = _candidates.take(shownMax).toList();
    return TextFieldTapRegion(
      child: SizedBox(
        height: height,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: J3Space.sm),
                child: Text('${_candidates.length} matches:', style: J3Type.codeSmall),
              ),
            ),
            for (final c in shown)
              Padding(
                padding: const EdgeInsets.only(right: J3Space.sm),
                child: _TermKey(label: c, tooltip: 'Use "$c"', onTap: () => _accept(c)),
              ),
            if (_candidates.length > shownMax)
              Center(child: Text('+${_candidates.length - shownMax} more, keep typing', style: J3Type.codeSmall)),
          ],
        ),
      ),
    );
  }

  Widget _keysRow(ToolRegistry registry, double height) {
    return TextFieldTapRegion(
      child: SizedBox(
        height: height,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TermKey(
                label: 'Tab',
                icon: Icons.keyboard_tab,
                tooltip: 'Complete the current word (Tab)',
                onTap: _complete,
              ),
              const SizedBox(width: J3Space.sm),
              _TermKey(
                icon: Icons.keyboard_arrow_up,
                tooltip: 'Previous command (Up)',
                semanticLabel: 'Previous command',
                onTap: _historyPrevious,
              ),
              const SizedBox(width: J3Space.sm),
              _TermKey(
                icon: Icons.keyboard_arrow_down,
                tooltip: 'Next command (Down)',
                semanticLabel: 'Next command',
                onTap: _historyNext,
              ),
              for (final c in kTerminalQuickCommands)
                if (registry.command(c) != null) ...[
                  const SizedBox(width: J3Space.sm),
                  _TermKey(label: c, tooltip: 'Insert "$c"', onTap: () => _insertCommand(c)),
                ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders one output row.
class TerminalRowView extends StatelessWidget {
  const TerminalRowView({super.key, required this.row});
  final TerminalRow row;

  static Color colorFor(TermStyle style, EffectsConfig fx) => switch (style) {
    TermStyle.normal => J3Colors.text,
    TermStyle.dim => J3Colors.textMuted,
    TermStyle.accent => fx.accentText,
    TermStyle.success => J3Colors.success,
    TermStyle.warning => J3Colors.warning,
    TermStyle.error => J3Colors.error,
    TermStyle.ascii => fx.accentColor,
    TermStyle.command => J3Colors.text,
  };

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    switch (row.kind) {
      case TerminalRowKind.ascii:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AsciiArt(
              lines: row.art,
              style: J3Type.ascii.copyWith(fontSize: 12, color: fx.accentColor),
              semanticLabel: 'ASCII art',
            ),
          ),
        );
      case TerminalRowKind.echo:
        return Padding(
          padding: const EdgeInsets.only(top: J3Space.xs),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: row.prompt,
                  style: J3Type.code.copyWith(color: fx.accentText, fontWeight: FontWeight.w700),
                ),
                const TextSpan(text: ' '),
                TextSpan(
                  text: row.text,
                  style: J3Type.code.copyWith(color: J3Colors.text, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        );
      case TerminalRowKind.line:
        final weight = switch (row.style) {
          TermStyle.accent || TermStyle.command || TermStyle.error => FontWeight.w500,
          _ => FontWeight.w400,
        };
        return Text(
          row.text.isEmpty ? ' ' : row.text,
          style: J3Type.code.copyWith(color: colorFor(row.style, fx), fontWeight: weight),
        );
    }
  }
}

/// A terminal "key": focusable, 44 px minimum, tooltip, visible focus ring.
class _TermKey extends StatefulWidget {
  const _TermKey({
    this.label,
    this.icon,
    required this.tooltip,
    required this.onTap,
    this.semanticLabel,
    this.filled = false,
  }) : assert(label != null || icon != null);

  final String? label;
  final IconData? icon;
  final String tooltip;
  final String? semanticLabel;
  final VoidCallback onTap;
  final bool filled;

  @override
  State<_TermKey> createState() => _TermKeyState();
}

class _TermKeyState extends State<_TermKey> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final border = _focus ? fx.accentColor : (_hover ? fx.accentColor.withValues(alpha: 0.7) : J3Colors.borderStrong);
    return Tooltip(
      message: widget.tooltip,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          label: widget.semanticLabel ?? widget.label ?? widget.tooltip,
          excludeSemantics: true,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Container(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: J3Space.md),
              decoration: BoxDecoration(
                color: widget.filled || _hover ? J3Colors.surfaceHigh : J3Colors.surfaceRaised,
                borderRadius: J3Radius.medium,
                border: Border.all(color: border, width: _focus ? 2 : 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null) Icon(widget.icon, size: 18, color: fx.accentText),
                  if (widget.icon != null && widget.label != null) const SizedBox(width: J3Space.xs),
                  if (widget.label != null)
                    Text(widget.label!, style: J3Type.code.copyWith(color: J3Colors.text), maxLines: 1),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
