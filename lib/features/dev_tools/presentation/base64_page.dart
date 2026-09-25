import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../domain/base64_tools.dart';
import '../domain/common.dart';
import 'dev_widgets.dart';

enum B64Mode {
  encode('Encode text'),
  decode('Decode');

  const B64Mode(this.label);
  final String label;
}

/// A file loaded by "File -> Base64".
class B64File {
  const B64File(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class Base64Page extends ConsumerStatefulWidget {
  const Base64Page({super.key});
  static const id = 'dev.base64';

  @override
  ConsumerState<Base64Page> createState() => _Base64PageState();
}

class _Base64PageState extends ConsumerState<Base64Page> {
  static const _k = Base64Page.id;
  final _focus = FocusNode();
  bool _loadingFile = false;

  // File encoding result (up to ~14 MB of text), computed in an isolate
  // whenever the file or the options change.
  Object? _fileKey;
  Object? _pendingKey;
  String? _fileText;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _encodeFile() async {
    setState(() => _loadingFile = true);
    try {
      var name = 'file';
      final bytes = await pickFileBytes(
        context,
        ref,
        maxBytes: Base64Tools.maxFileBytes,
        title: 'File to encode (max 10 MiB)',
        onName: (n) => name = n,
      );
      if (bytes == null) return;
      ref.setDraft('$_k/file', B64File(name, bytes));
    } finally {
      if (mounted) setState(() => _loadingFile = false);
    }
  }

  void _ensureFileText(B64File f, bool urlSafe, bool padding, int wrap, bool dataUri) {
    final key = (f, urlSafe, padding, wrap, dataUri);
    if (_fileKey == key || _pendingKey == key) return;
    _pendingKey = key;
    final bytes = f.bytes;
    final mime = sniffFileType(bytes)?.mimeType ?? 'application/octet-stream';
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final text = await encodeFileInBackground(bytes, urlSafe, padding, dataUri ? 0 : wrap, dataUri ? mime : null);
      if (!mounted || _pendingKey != key) return;
      setState(() {
        _fileKey = key;
        _fileText = text;
      });
    });
  }

  Future<void> _saveBytes(Uint8List bytes) async {
    final type = sniffFileType(bytes);
    await saveOutput(
      context,
      ref,
      suggestedName: 'decoded.${type?.extension ?? 'bin'}',
      bytes: bytes,
      mimeType: type?.mimeType ?? 'application/octet-stream',
      toolId: _k,
    );
  }

  void _swap(TextEditingController input, B64Mode mode, bool urlSafe, bool padding, int wrap) {
    if (mode == B64Mode.encode) {
      input.text = Base64Tools.encodeText(input.text, urlSafe: urlSafe, padding: padding, lineLength: wrap);
      ref.setDraft('$_k/mode', B64Mode.decode);
      return;
    }
    try {
      final t = Base64Tools.decode(input.text).text;
      if (t == null) {
        ref
            .read(activityProvider.notifier)
            .notify(NoticeKind.warning, 'Decoded bytes are binary; cannot swap to text.');
        return;
      }
      input.text = t;
      ref.setDraft('$_k/mode', B64Mode.encode);
    } on InputError catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final input = ref.watch(draftTextProvider('$_k/input'));
    final mode = ref.draft<B64Mode>('$_k/mode', B64Mode.encode);
    final urlSafe = ref.draft<bool>('$_k/urlSafe', false);
    final padding = ref.draft<bool>('$_k/padding', true);
    final wrap = ref.draft<int>('$_k/wrap', 0);
    final file = ref.draft<B64File?>('$_k/file', null);
    final dataUri = ref.draft<bool>('$_k/dataUri', false);

    final inputs = [
      NeonPanel(
        kicker: 'INPUT',
        title: mode == B64Mode.encode ? 'Text to encode (UTF-8)' : 'Base64 to decode',
        icon: Icons.keyboard_alt_outlined,
        actions: [InputActions(controller: input)],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChoiceRow<B64Mode>(
              label: 'Mode',
              options: B64Mode.values,
              selected: mode,
              labelOf: (m) => m.label,
              onSelected: (m) => ref.setDraft('$_k/mode', m),
            ),
            const SizedBox(height: J3Space.md),
            CodeField(
              key: const Key('dev.base64.input'),
              controller: input,
              focusNode: _focus,
              label: mode == B64Mode.encode ? 'Text' : 'Base64 (whitespace and line breaks are ignored)',
              hint: mode == B64Mode.encode ? 'Hello, modder!' : 'SGVsbG8sIG1vZGRlciE=',
              minLines: 4,
              maxLines: 12,
            ),
            const MiniHeader('Options'),
            ChoiceRow<bool>(
              label: 'Alphabet (encoding)',
              options: const [false, true],
              selected: urlSafe,
              labelOf: (u) => u ? Base64Alphabet.urlSafe.label : Base64Alphabet.standard.label,
              onSelected: (u) => ref.setDraft('$_k/urlSafe', u),
            ),
            OptionSwitch(
              label: 'Keep padding (=)',
              description: 'Off strips trailing "=" (common for Base64URL in tokens and URLs).',
              value: padding,
              onChanged: (v) => ref.setDraft('$_k/padding', v),
            ),
            ChoiceRow<int>(
              label: 'Line wrap (encoding)',
              options: const [0, 64, 76],
              selected: wrap,
              labelOf: (w) => switch (w) {
                0 => 'None',
                64 => '64 (PEM)',
                _ => '76 (MIME)',
              },
              onSelected: (w) => ref.setDraft('$_k/wrap', w),
            ),
            const HelpText(
              'Decoding auto-detects the alphabet and accepts missing padding, whitespace, line breaks and data: URIs.',
            ),
            const SizedBox(height: J3Space.md),
            ActionWrap(
              children: [
                NeonButton.secondary(
                  label: 'File -> Base64',
                  icon: Icons.upload_file_outlined,
                  busy: _loadingFile,
                  tooltip: 'Encode a file (up to ${Fmt.bytes(Base64Tools.maxFileBytes)})',
                  onPressed: _encodeFile,
                ),
                ListenableBuilder(
                  listenable: input,
                  builder: (context, _) => NeonButton.ghost(
                    label: 'Swap',
                    icon: Icons.swap_vert,
                    tooltip: 'Use the output as input and flip the mode',
                    onPressed: input.text.isEmpty ? null : () => _swap(input, mode, urlSafe, padding, wrap),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ];

    final results = [
      ListenableBuilder(listenable: input, builder: (context, _) => _results(input, mode, urlSafe, padding, wrap)),
      if (file != null) _fileResult(file, urlSafe, padding, wrap, dataUri),
    ];

    return ToolScaffold(toolId: _k, inputs: inputs, results: results);
  }

  Widget _results(TextEditingController input, B64Mode mode, bool urlSafe, bool padding, int wrap) {
    final text = input.text;
    if (text.isEmpty) {
      return const EmptyState(
        title: 'Nothing to convert yet',
        message: 'Type or paste text on the left. Results update as you type.',
        glyph: '[ b64 ]',
      );
    }
    if (mode == B64Mode.encode) {
      final out = Base64Tools.encodeText(text, urlSafe: urlSafe, padding: padding, lineLength: wrap);
      return CappedTextResult(
        text: out,
        title: 'Base64 (${urlSafe ? 'URL-safe' : 'standard'})',
        fileName: 'encoded.b64.txt',
        toolId: _k,
        footer: Text('${Fmt.bytes(utf8Length(text))} of UTF-8 -> ${out.length} characters', style: J3Type.caption),
      );
    }
    final Base64Decoded d;
    try {
      d = Base64Tools.decode(text);
    } on InputError catch (e) {
      return InputErrorBanner(error: e, title: 'Not valid Base64', controller: input, focusNode: _focus);
    }
    final info = [
      Fmt.count(d.bytes.length, 'byte'),
      '${d.alphabet.label} alphabet',
      if (!d.hadPadding) 'no padding',
      if (d.ignoredWhitespace > 0) '${d.ignoredWhitespace} whitespace ignored',
      if (d.dataUriMime != null) 'data URI: ${d.dataUriMime}',
    ].join('  |  ');
    final decodedText = d.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final w in d.warnings) ...[
          StatusBanner(kind: StatusKind.warning, title: 'Warning', message: w),
          const SizedBox(height: J3Space.md),
        ],
        if (decodedText != null)
          CappedTextResult(
            text: decodedText,
            title: 'Decoded text (UTF-8)',
            fileName: 'decoded.txt',
            toolId: _k,
            extraActions: [
              IconButton(
                tooltip: 'Save raw bytes',
                onPressed: () => _saveBytes(d.bytes),
                icon: const Icon(Icons.file_download_outlined, size: 18),
              ),
            ],
            footer: Text(info, style: J3Type.caption),
          )
        else ...[
          StatusBanner(
            kind: StatusKind.warning,
            title: 'Decoded bytes are not valid UTF-8',
            message:
                'This is binary data (first invalid byte at offset ${d.invalidUtf8Offset}). It is shown as hex; '
                'save it as a file to use it.',
            actions: [
              NeonButton(
                label: 'Save as binary',
                icon: Icons.save_alt_rounded,
                dense: true,
                onPressed: () => _saveBytes(d.bytes),
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          NeonPanel(
            kicker: 'BINARY',
            title: 'Hex preview',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                HexPreview(bytes: d.bytes),
                const SizedBox(height: J3Space.xs),
                Text(info, style: J3Type.caption),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _fileResult(B64File f, bool urlSafe, bool padding, int wrap, bool dataUri) {
    _ensureFileText(f, urlSafe, padding, wrap, dataUri);
    final text = _fileText;
    final ready = _fileKey == (f, urlSafe, padding, wrap, dataUri) && text != null;
    final type = sniffFileType(f.bytes);
    final close = IconButton(
      tooltip: 'Close file result',
      onPressed: () => ref.setDraft('$_k/file', null),
      icon: const Icon(Icons.close, size: 18),
    );
    if (!ready) {
      return NeonPanel(
        kicker: 'FILE -> BASE64',
        title: f.name,
        actions: [close],
        child: LoadingState(label: 'Encoding ${Fmt.bytes(f.bytes.length)} in the background...'),
      );
    }
    return CappedTextResult(
      text: text,
      kicker: 'FILE -> BASE64',
      title: f.name,
      fileName: '${f.name}.b64.txt',
      toolId: _k,
      extraActions: [close],
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${Fmt.bytes(f.bytes.length)}${type == null ? '' : ' ${type.label}'} -> '
            '${Fmt.bytes(text.length)} of Base64',
            style: J3Type.caption,
          ),
          OptionSwitch(
            label: 'As data: URI',
            description: 'Prefix with data:${type?.mimeType ?? 'application/octet-stream'};base64, (no wrapping)',
            value: dataUri,
            onChanged: (v) => ref.setDraft('$_k/dataUri', v),
          ),
        ],
      ),
    );
  }
}

/// Encodes file bytes in a background isolate. Top-level on purpose: the
/// isolate closure may only capture these parameters (never a State).
/// With [dataUriMime] the result is a `data:` URI.
Future<String> encodeFileInBackground(Uint8List bytes, bool urlSafe, bool padding, int wrap, String? dataUriMime) =>
    Isolate.run(() {
      final body = Base64Tools.encodeBytes(bytes, urlSafe: urlSafe, padding: padding, lineLength: wrap);
      return dataUriMime == null ? body : 'data:$dataUriMime;base64,$body';
    }, debugName: 'j3-base64');
