import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/common.dart';

export '../dev_clock.dart';

/// Copies [text] to the clipboard and confirms with a toast.
Future<void> copyToClipboard(WidgetRef ref, String text, {String? what}) async {
  await ref.read(fileAccessProvider).copyText(text);
  ref
      .read(activityProvider.notifier)
      .notify(NoticeKind.success, what == null ? 'Copied ${text.length} characters' : 'Copied $what');
}

/// Reads the system clipboard as text (null when empty or unavailable).
Future<String?> readClipboardText() async {
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  } catch (_) {
    return null;
  }
}

/// A file picked for a tool and decoded as text.
class LoadedTextFile {
  const LoadedTextFile(this.name, this.text, this.encodingLabel, {this.lossy = false});
  final String name;
  final String text;
  final String encodingLabel;

  /// True when bytes were not valid in the detected encoding (Latin-1
  /// fallback), so the text is not an exact copy of the file.
  final bool lossy;
}

/// Picks a file (workspace or device) and reads at most [maxBytes].
/// Returns null when cancelled; reports problems as toasts.
Future<Uint8List?> pickFileBytes(
  BuildContext context,
  WidgetRef ref, {
  required int maxBytes,
  String title = 'Open file',
  void Function(String name)? onName,
}) async {
  final picked = await pickInputFile(context, ref, title: title);
  if (picked == null) return null;
  final activity = ref.read(activityProvider.notifier);
  try {
    final f = File(picked.path);
    final size = await f.length();
    if (size > maxBytes) {
      activity.notify(
        NoticeKind.error,
        '${picked.displayName} is ${Fmt.bytes(size)}; the limit for this tool is ${Fmt.bytes(maxBytes)}.',
      );
      return null;
    }
    onName?.call(picked.displayName);
    return await f.readAsBytes();
  } on FileSystemException catch (e) {
    activity.notify(NoticeKind.error, 'Could not read ${picked.displayName}: ${e.message}');
    return null;
  }
}

/// Picks a text file and decodes it (BOM-aware, Latin-1 fallback).
Future<LoadedTextFile?> pickTextFile(BuildContext context, WidgetRef ref, {int maxBytes = 16 * 1024 * 1024}) async {
  String name = 'file';
  final bytes = await pickFileBytes(context, ref, maxBytes: maxBytes, title: 'Open text file', onName: (n) => name = n);
  if (bytes == null) return null;
  if (TextCodec.looksBinary(bytes)) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, '$name looks like a binary file, not text.');
    return null;
  }
  final d = TextCodec.decode(bytes);
  return LoadedTextFile(name, d.text, d.encodingLabel, lossy: d.hadMalformedBytes);
}

/// Error banner for malformed input: message, position and hint, with a
/// "Go to position" action that moves the caret in [controller].
class InputErrorBanner extends StatelessWidget {
  const InputErrorBanner({
    super.key,
    required this.error,
    this.title = 'Invalid input',
    this.controller,
    this.focusNode,
  });

  final InputError error;
  final String title;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final lc = error.lineColumn;
    final canJump = controller != null && lc != null && error.source == controller!.text;
    return StatusBanner(
      kind: StatusKind.error,
      title: title,
      message: error.toString(),
      details: [?error.hint],
      actions: [
        if (canJump)
          TextButton.icon(
            onPressed: () {
              controller!.jumpTo(lc.$1, lc.$2);
              focusNode?.requestFocus();
            },
            icon: const Icon(Icons.my_location, size: 18),
            label: Text('Go to line ${lc.$1}, col ${lc.$2}'),
          ),
      ],
    );
  }
}

/// Label + monospace value + copy button. Stacks on narrow widths.
class ValueRow extends ConsumerWidget {
  const ValueRow({
    super.key,
    required this.label,
    required this.value,
    this.copyable = true,
    this.badge,
    this.valueStyle,
    this.trailing,
  });

  final String label;
  final String value;
  final bool copyable;
  final Widget? badge;
  final TextStyle? valueStyle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final valueText = SelectableText(value.isEmpty ? '(empty)' : value, style: valueStyle ?? J3Type.code);
    final actions = [
      ?trailing,
      if (copyable && value.isNotEmpty)
        IconButton(
          tooltip: 'Copy $label',
          onPressed: () => copyToClipboard(ref, value, what: label),
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 440;
        final labelWidget = Wrap(
          spacing: J3Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(label, style: J3Type.caption),
            ?badge,
          ],
        );
        if (narrow) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                labelWidget,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: valueText),
                    ...actions,
                  ],
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: J3Space.xxs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(width: 170, child: labelWidget),
              Expanded(child: valueText),
              ...actions,
            ],
          ),
        );
      },
    );
  }
}

/// Small metric tile (value above label) for stats grids.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.hint});
  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      constraints: const BoxConstraints(minWidth: 132),
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.medium,
        border: Border.all(color: J3Colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(value, style: J3Type.title.copyWith(fontFamily: J3Type.mono, fontSize: 17)),
          Text(label, style: J3Type.caption),
        ],
      ),
    );
    return hint == null ? tile : Tooltip(message: hint!, child: tile);
  }
}

/// Wrap of [StatTile]s.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.tiles});
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => Wrap(spacing: J3Space.sm, runSpacing: J3Space.sm, children: tiles);
}

/// Text result that may be very large: shows at most [previewChars] while
/// Copy and Save always use the full text.
class CappedTextResult extends ConsumerWidget {
  const CappedTextResult({
    super.key,
    required this.text,
    this.title = 'Result',
    this.kicker = 'OUTPUT',
    this.fileName = 'result.txt',
    this.toolId = 'core.result',
    this.previewChars = 200000,
    this.extraActions = const [],
    this.footer,
    this.maxHeight = 360,
  });

  final String text;
  final String title;
  final String kicker;
  final String fileName;
  final String toolId;
  final int previewChars;
  final List<Widget> extraActions;
  final Widget? footer;
  final double maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (text.length <= previewChars) {
      return ResultPanel(
        text: text,
        title: title,
        kicker: kicker,
        fileName: fileName,
        toolId: toolId,
        maxHeight: maxHeight,
        extraActions: extraActions,
        footer: footer,
      );
    }
    final preview = text.substring(0, previewChars);
    return NeonPanel(
      kicker: kicker,
      title: title,
      actions: [
        ...extraActions,
        IconButton(
          tooltip: 'Copy all (${Fmt.bytes(text.length)})',
          onPressed: () => copyToClipboard(ref, text),
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
        IconButton(
          tooltip: 'Save / export',
          onPressed: () => saveOutput(
            context,
            ref,
            suggestedName: fileName,
            bytes: Uint8List.fromList(utf8.encode(text)),
            mimeType: 'text/plain',
            toolId: toolId,
          ),
          icon: const Icon(Icons.save_alt_rounded, size: 18),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(J3Space.md),
            constraints: BoxConstraints(maxHeight: maxHeight),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: Scrollbar(
              child: SingleChildScrollView(child: SelectableText(preview, style: J3Type.code)),
            ),
          ),
          const SizedBox(height: J3Space.sm),
          Row(
            children: [
              const Icon(Icons.content_cut, size: 14, color: J3Colors.warning),
              const SizedBox(width: J3Space.xs),
              Expanded(
                child: Text(
                  'Preview shows the first ${Fmt.bytes(previewChars)} of ${Fmt.bytes(text.length)}. '
                  'Copy and Save use the full text.',
                  style: J3Type.caption,
                ),
              ),
            ],
          ),
          if (footer != null) ...[const SizedBox(height: J3Space.sm), footer!],
        ],
      ),
    );
  }
}

/// Read-only, virtualised view for large text (e.g. a 2 MiB response):
/// lines are split and very long lines chunked so only visible rows are
/// laid out.
class LargeTextView extends StatefulWidget {
  const LargeTextView({super.key, required this.text, this.height = 360, this.chunk = 400});
  final String text;
  final double height;
  final int chunk;

  @override
  State<LargeTextView> createState() => _LargeTextViewState();
}

class _LargeTextViewState extends State<LargeTextView> {
  late List<String> _rows = _split(widget.text);

  List<String> _split(String text) {
    final rows = <String>[];
    for (final line in TextCodec.splitLines(text)) {
      if (line.length <= widget.chunk) {
        rows.add(line);
      } else {
        for (var i = 0; i < line.length; i += widget.chunk) {
          rows.add(line.substring(i, i + widget.chunk > line.length ? line.length : i + widget.chunk));
        }
      }
    }
    return rows;
  }

  @override
  void didUpdateWidget(LargeTextView old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _rows = _split(widget.text);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.md, vertical: J3Space.sm),
      decoration: BoxDecoration(
        color: J3Colors.inputFill,
        borderRadius: J3Radius.small,
        border: Border.all(color: J3Colors.border),
      ),
      child: SelectionArea(
        child: Scrollbar(
          child: ListView.builder(
            itemCount: _rows.length,
            itemBuilder: (context, i) => Text(_rows[i].isEmpty ? ' ' : _rows[i], style: J3Type.code),
          ),
        ),
      ),
    );
  }
}

/// Hex dump of binary data with an optional file-type guess.
class HexPreview extends StatelessWidget {
  const HexPreview({super.key, required this.bytes, this.maxBytes = 512});
  final List<int> bytes;
  final int maxBytes;

  @override
  Widget build(BuildContext context) {
    final type = sniffFileType(bytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${Fmt.count(bytes.length, 'byte')}${type == null ? '' : '  |  looks like: ${type.label}'}',
          style: J3Type.caption,
        ),
        const SizedBox(height: J3Space.xs),
        Container(
          padding: const EdgeInsets.all(J3Space.sm),
          decoration: BoxDecoration(
            color: J3Colors.inputFill,
            borderRadius: J3Radius.small,
            border: Border.all(color: J3Colors.border),
          ),
          constraints: const BoxConstraints(maxHeight: 300),
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  hexDump(bytes, maxBytes: maxBytes),
                  style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Runs a callback after input settles; cancelled on [dispose].
class Debouncer {
  Debouncer(this.delay);
  final Duration delay;
  Timer? _timer;

  void call(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void cancel() => _timer?.cancel();

  void dispose() => _timer?.cancel();
}

/// Row of actions that wraps on narrow screens.
class ActionWrap extends StatelessWidget {
  const ActionWrap({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: J3Space.sm,
    runSpacing: J3Space.sm,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );
}

/// Small status line: icon + text (never colour alone).
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.kind, required this.text});
  final StatusKind kind;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(kind.icon, size: 16, color: kind.color),
        ),
        const SizedBox(width: J3Space.xs),
        Expanded(
          child: Text(text, style: J3Type.bodySecondary.copyWith(color: kind.color)),
        ),
      ],
    ),
  );
}

/// Clear + paste buttons for an input field.
class InputActions extends StatelessWidget {
  const InputActions({super.key, required this.controller, this.onChanged, this.what = 'input'});
  final TextEditingController controller;
  final VoidCallback? onChanged;
  final String what;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Paste into $what',
          onPressed: () async {
            final t = await readClipboardText();
            if (t == null) return;
            controller.text = t;
            onChanged?.call();
          },
          icon: const Icon(Icons.content_paste_rounded, size: 18),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, v, _) => IconButton(
            tooltip: 'Clear $what',
            onPressed: v.text.isEmpty
                ? null
                : () {
                    controller.clear();
                    onChanged?.call();
                  },
            icon: const Icon(Icons.backspace_outlined, size: 18),
          ),
        ),
      ],
    );
  }
}

/// [OptionSwitch] on its own transparent [Material]. Inside a [NeonPanel]
/// (a coloured DecoratedBox) the switch's ListTile would otherwise paint
/// its ink below the panel, which Flutter reports as an error.
class DevSwitch extends StatelessWidget {
  const DevSwitch({super.key, required this.label, required this.value, required this.onChanged, this.description});

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: OptionSwitch(label: label, description: description, value: value, onChanged: onChanged),
  );
}

/// Accent-coloured caption used for short explanations under controls.
class HelpText extends StatelessWidget {
  const HelpText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: J3Space.xs),
    child: Text(text, style: J3Type.caption),
  );
}

/// Mono kicker label, e.g. "// OPTIONS".
class MiniHeader extends StatelessWidget {
  const MiniHeader(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: J3Space.sm, bottom: J3Space.xs),
    child: Text('// ${text.toUpperCase()}', style: J3Type.kicker.copyWith(color: context.effects.accentText)),
  );
}
