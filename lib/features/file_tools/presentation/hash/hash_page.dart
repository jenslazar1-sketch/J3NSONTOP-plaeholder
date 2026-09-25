import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/drafts/drafts.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/hashing.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/checksums.dart';
import '../shared.dart';
import 'hash_controller.dart';

const _algoOrder = [HashAlgorithm.sha256, HashAlgorithm.sha512, HashAlgorithm.sha1, HashAlgorithm.md5];

String _algoLabel(HashAlgorithm a) => a.isLegacy ? '${a.label} (legacy)' : a.label;

/// Hash & Checksum tool.
class HashPage extends ConsumerWidget {
  const HashPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.draft<HashMode>('$kHashToolId/mode', HashMode.text);
    final algo = ref.draft<HashAlgorithm>('$kHashToolId/algo', HashAlgorithm.sha256);

    final modePanel = NeonPanel(
      kicker: 'Mode',
      title: 'What to hash',
      icon: Icons.tune,
      child: ChoiceRow<HashMode>(
        label: 'Input',
        options: HashMode.values,
        selected: mode,
        labelOf: (m) => m.label,
        onSelected: (m) => ref.setDraft('$kHashToolId/mode', m),
      ),
    );

    final algoPanel = NeonPanel(
      kicker: 'Algorithm',
      title: algo.label,
      icon: Icons.fingerprint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChoiceRow<HashAlgorithm>(
            label: 'Digest algorithm',
            options: _algoOrder,
            selected: algo,
            labelOf: _algoLabel,
            onSelected: (a) => ref.setDraft('$kHashToolId/algo', a),
          ),
          if (algo.isLegacy) ...[
            const SizedBox(height: J3Space.sm),
            const StatusBadge(kind: StatusKind.warning, text: 'compatibility only — not collision resistant'),
            const SizedBox(height: J3Space.xs),
            Text(
              'Use ${algo.label} only to compare against published checksums. Prefer SHA-256 for anything new.',
              style: J3Type.caption,
            ),
          ],
        ],
      ),
    );

    return switch (mode) {
      HashMode.text => ToolScaffold(
        toolId: kHashToolId,
        inputs: [modePanel, algoPanel, const _TextInput()],
        results: [
          _TextDigest(algo: algo),
          const _ExpectedField(),
        ],
      ),
      HashMode.files => ToolScaffold(
        toolId: kHashToolId,
        inputs: [
          modePanel,
          algoPanel,
          _FilesInput(algo: algo),
        ],
        results: [const _ExpectedField(), const _FileResults()],
      ),
      HashMode.verify => ToolScaffold(
        toolId: kHashToolId,
        inputs: [modePanel, const _VerifyInput()],
        results: const [_VerifyResults()],
      ),
    };
  }
}

// ---------------------------------------------------------------------------
// Text mode

class _TextInput extends ConsumerWidget {
  const _TextInput();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NeonPanel(
      kicker: 'Input',
      title: 'Text',
      icon: Icons.notes,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeField(
            key: const Key('hash.text'),
            controller: ref.watch(draftTextProvider('$kHashToolId/text')),
            label: 'Text to hash',
            hint: 'Paste or type text...',
            minLines: 4,
            maxLines: 12,
          ),
          const SizedBox(height: J3Space.xs),
          const InfoLine('Hashed as UTF-8 bytes exactly as typed, including spaces and line breaks.'),
        ],
      ),
    );
  }
}

class _TextDigest extends ConsumerWidget {
  const _TextDigest({required this.algo});
  final HashAlgorithm algo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(draftTextProvider('$kHashToolId/text'));
    final expected = ref.watch(draftTextProvider('$kHashToolId/expected'));
    return ListenableBuilder(
      listenable: Listenable.merge([text, expected]),
      builder: (context, _) {
        final bytes = utf8.encode(text.text);
        final digest = Hashing.bytes(bytes, algo);
        final verdict = compareDigest(digest, expected.text);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _DigestCard(
              title: algo.label,
              digest: digest,
              subtitle: '${Fmt.count(bytes.length, 'byte')} of UTF-8${text.text.isEmpty ? ' (empty input)' : ''}',
              match: verdict,
            ),
            if (verdict != DigestVerdict.none) ...[
              const SizedBox(height: J3Space.lg),
              _VerdictBanner(verdict: verdict, subject: 'the text'),
            ],
          ],
        );
      },
    );
  }
}

class _DigestCard extends ConsumerWidget {
  const _DigestCard({required this.title, required this.digest, required this.subtitle, required this.match});
  final String title;
  final String digest;
  final String subtitle;
  final DigestVerdict match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return NeonPanel(
      kicker: 'Digest',
      title: title,
      icon: Icons.tag,
      emphasis: match == DigestVerdict.match
          ? PanelEmphasis.success
          : (match == DigestVerdict.mismatch ? PanelEmphasis.danger : PanelEmphasis.normal),
      actions: [
        IconButton(
          tooltip: 'Copy digest',
          onPressed: () async {
            await ref.read(fileAccessProvider).copyText(digest);
            ref.read(activityProvider.notifier).notify(NoticeKind.success, 'Copied $title digest');
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(J3Space.md),
            decoration: BoxDecoration(
              color: J3Colors.inputFill,
              borderRadius: J3Radius.small,
              border: Border.all(color: J3Colors.border),
            ),
            child: SelectableText(digest, key: const Key('hash.digest'), style: J3Type.code),
          ),
          const SizedBox(height: J3Space.xs),
          Text(subtitle, style: J3Type.caption),
        ],
      ),
    );
  }
}

class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.verdict, required this.subject});
  final DigestVerdict verdict;
  final String subject;

  @override
  Widget build(BuildContext context) {
    final match = verdict == DigestVerdict.match;
    return StatusBanner(
      kind: match ? StatusKind.success : StatusKind.error,
      title: match ? 'MATCH' : 'MISMATCH',
      message: match
          ? 'The expected digest equals the digest of $subject.'
          : 'The expected digest differs from the digest of $subject. Check the algorithm and the input.',
    );
  }
}

class _ExpectedField extends ConsumerWidget {
  const _ExpectedField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(draftTextProvider('$kHashToolId/expected'));
    final algo = ref.draft<HashAlgorithm>('$kHashToolId/algo', HashAlgorithm.sha256);
    return NeonPanel(
      kicker: 'Compare',
      title: 'Expected digest',
      icon: Icons.compare_arrows,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: c,
        builder: (context, v, _) {
          final suggestion = suggestedAlgorithmFor(v.text, algo);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('hash.expected'),
                controller: c,
                style: J3Type.code,
                decoration: InputDecoration(
                  labelText: 'Paste the published checksum',
                  hintText: 'e.g. sha256:9f86d081... (case and spaces are ignored)',
                  suffixIcon: v.text.isEmpty
                      ? null
                      : IconButton(tooltip: 'Clear', onPressed: c.clear, icon: const Icon(Icons.close, size: 18)),
                ),
              ),
              if (suggestion != null) ...[
                const SizedBox(height: J3Space.sm),
                ButtonWrap(
                  spacing: J3Space.sm,
                  runSpacing: J3Space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    InfoLine('This digest has the length of ${suggestion.label}, not ${algo.label}.'),
                    NeonButton.ghost(
                      label: 'Use ${suggestion.label}',
                      dense: true,
                      onPressed: () => ref.setDraft('$kHashToolId/algo', suggestion),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Files mode

class _FilesInput extends ConsumerWidget {
  const _FilesInput({required this.algo});
  final HashAlgorithm algo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(hashFilesProvider);
    final ctl = ref.read(hashFilesProvider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);
    final noWs = ws == null ? 'Open a workspace to browse its files' : null;

    Future<void> addFolder() async {
      final folder = await pickWorkspaceFolder(context, ref, title: 'Hash every file in...');
      if (folder == null || ws == null) return;
      try {
        final (items, walk) = await filesInFolder(ws, folder);
        ctl.add(items);
        if (walk.truncated) {
          ctl.setNotice('Only the first ${items.length} files of that folder were added (limit 5000).');
        } else if (walk.skippedLinks.isNotEmpty) {
          ctl.setNotice('${walk.skippedLinks.length} symbolic link(s) were skipped.');
        }
      } catch (e) {
        ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Cannot list folder: ${describeError(e)}');
      }
    }

    return NeonPanel(
      kicker: 'Input',
      title: 'Files',
      icon: Icons.folder_copy_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton.secondary(
                label: 'Workspace file',
                icon: Icons.insert_drive_file_outlined,
                tooltip: noWs ?? 'Add one file from the workspace',
                onPressed: ws == null || st.running
                    ? null
                    : () async {
                        final f = await pickWorkspaceFile(context, ref, title: 'Add a file to hash');
                        if (f != null) ctl.add([f]);
                      },
              ),
              NeonButton.secondary(
                label: 'Workspace folder',
                icon: Icons.folder_open,
                tooltip: noWs ?? 'Add every file below a folder (recursive, links skipped)',
                onPressed: ws == null || st.running ? null : addFolder,
              ),
              NeonButton.secondary(
                label: 'From device',
                icon: Icons.upload_file_outlined,
                tooltip: 'Import copies of files with the system picker',
                onPressed: st.running ? null : () async => ctl.add(await pickDeviceFiles(ref, toolKey: kHashToolId)),
              ),
              if (st.files.isNotEmpty)
                NeonButton.ghost(label: 'Clear', icon: Icons.clear_all, onPressed: st.running ? null : ctl.clear),
            ],
          ),
          const SizedBox(height: J3Space.md),
          if (st.files.isEmpty)
            const EmptyState(
              glyph: '[ #_# ]',
              title: 'No files yet',
              message: 'Add files or a whole folder. Try the sample workspace folder "duplicates/".',
            )
          else
            FileItemList(items: st.files, onRemove: st.running ? null : ctl.remove),
          if (st.notice != null) ...[const SizedBox(height: J3Space.sm), InfoLine(st.notice!)],
          const SizedBox(height: J3Space.md),
          NeonButton(
            key: const Key('hash.run'),
            label: st.files.isEmpty ? 'Hash files' : 'Hash ${Fmt.count(st.files.length, 'file')}',
            icon: Icons.play_arrow_rounded,
            busy: st.running,
            onPressed: st.files.isEmpty ? null : () => ctl.hash(algo),
          ),
        ],
      ),
    );
  }
}

class _FileResults extends ConsumerWidget {
  const _FileResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(hashFilesProvider);
    final expected = ref.watch(draftTextProvider('$kHashToolId/expected'));
    final ctl = ref.read(hashFilesProvider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);

    final progress = OperationProgressPanel(
      operationId: st.opId,
      label: 'Hashing...',
      detail: st.running && st.files.isNotEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(J3Space.lg, 0, J3Space.lg, J3Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'File ${st.currentIndex + 1} of ${st.files.length}: '
                    '${st.files[st.currentIndex.clamp(0, st.files.length - 1)].label} · '
                    '${(st.currentFraction * 100).toStringAsFixed(0)}%',
                    style: J3Type.codeSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: J3Space.xs),
                  NeonProgressBar(value: st.currentFraction, height: 4),
                ],
              ),
            )
          : null,
    );

    final results = st.results;
    if (results == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          progress,
          if (st.error != null) ...[
            const SizedBox(height: J3Space.md),
            ErrorPanel(title: 'Hashing failed', error: st.error!),
          ],
          if (!st.running && st.error == null)
            const NeonPanel(
              emphasis: PanelEmphasis.subtle,
              child: EmptyState(
                glyph: '[ 0x_0x ]',
                title: 'No digests yet',
                message: 'Digests appear here with per-file status. Large files are streamed, never loaded whole.',
              ),
            ),
        ],
      );
    }

    final algo = st.resultAlgorithm ?? HashAlgorithm.sha256;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: expected,
      builder: (context, ev, _) {
        final exp = ev.text;
        final matches = exp.trim().isEmpty
            ? const <HashOutcome>[]
            : results.where((r) => r.ok && Hashing.digestsEqual(r.digest!, exp)).toList();
        final base = ctl.checksumBase;
        final canSaveNext =
            ws != null &&
            base != null &&
            SafePath.isWithin(ws.rootPath, base) &&
            st.digests.every((r) => SafePath.isWithin(ws.rootPath, r.target.path));
        final failed = results.where((r) => !r.ok).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (exp.trim().isNotEmpty) ...[
              matches.isNotEmpty
                  ? StatusBanner(
                      kind: StatusKind.success,
                      title: 'MATCH',
                      message:
                          'The expected digest equals the ${algo.label} of ${matches.map((m) => m.target.label).join(', ')}.',
                    )
                  : StatusBanner(
                      kind: StatusKind.error,
                      title: 'MISMATCH',
                      message: 'None of the ${results.length} ${algo.label} digests equals the expected value.',
                    ),
              const SizedBox(height: J3Space.lg),
            ],
            NeonPanel(
              kicker: 'Result',
              title: '${algo.label} · ${Fmt.count(results.length, 'file')}${failed > 0 ? ' · $failed unreadable' : ''}',
              icon: Icons.fact_check_outlined,
              actions: [
                IconButton(
                  tooltip: 'Copy as ${defaultChecksumFileName(algo)} lines',
                  onPressed: st.digests.isEmpty
                      ? null
                      : () async {
                          await ref.read(fileAccessProvider).copyText(ctl.buildChecksums());
                          ref
                              .read(activityProvider.notifier)
                              .notify(NoticeKind.success, 'Copied ${st.digests.length} checksum lines');
                        },
                  icon: const Icon(Icons.copy_all_rounded, size: 18),
                ),
              ],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (algo.isLegacy) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: StatusBadge(
                        kind: StatusKind.warning,
                        text: '${algo.label}: compatibility only — not collision resistant',
                      ),
                    ),
                    const SizedBox(height: J3Space.sm),
                  ],
                  BoundedList(
                    itemCount: results.length,
                    inlineUpTo: 30,
                    itemBuilder: (context, i) {
                      final r = results[i];
                      final isMatch = matches.contains(r);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                StatusBadge(
                                  dense: true,
                                  kind: r.ok ? StatusKind.success : StatusKind.error,
                                  text: r.ok ? (isMatch ? 'MATCH' : 'OK') : 'ERROR',
                                ),
                                const SizedBox(width: J3Space.sm),
                                Expanded(
                                  child: Text(
                                    r.target.label,
                                    style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(Fmt.bytes(r.target.size), style: J3Type.caption),
                              ],
                            ),
                            const SizedBox(height: 2),
                            SelectableText(r.digest ?? r.error ?? '', style: J3Type.codeSmall),
                          ],
                        ),
                      );
                    },
                  ),
                  if (st.digests.isNotEmpty) ...[
                    const Divider(height: J3Space.xl),
                    Text('Checksum file', style: J3Type.label),
                    const SizedBox(height: J3Space.xs),
                    InfoLine(
                      'Paths are relative to '
                      '${base == null ? '-' : (ws != null && SafePath.isWithin(ws.rootPath, base) ? '"${workspaceLabel(ws, base) == '.' ? ws.name : workspaceLabel(ws, base)}"' : 'the imported files folder')}'
                      ', sorted, in GNU coreutils format (verifiable with ${algo.name}sum -c).',
                    ),
                    const SizedBox(height: J3Space.sm),
                    ButtonWrap(
                      spacing: J3Space.sm,
                      runSpacing: J3Space.sm,
                      children: [
                        NeonButton.secondary(
                          key: const Key('hash.saveNext'),
                          label: 'Save next to files',
                          icon: Icons.save_outlined,
                          tooltip: canSaveNext
                              ? 'Write ${defaultChecksumFileName(algo)} into that folder (never overwrites)'
                              : 'Only possible when all files are in the active workspace',
                          onPressed: !canSaveNext
                              ? null
                              : () async {
                                  try {
                                    await ctl.saveChecksumsNextToFiles();
                                  } catch (e) {
                                    ref.read(activityProvider.notifier).notify(NoticeKind.error, describeError(e));
                                  }
                                },
                        ),
                        NeonButton.secondary(
                          label: 'Save / export...',
                          icon: Icons.save_alt_rounded,
                          onPressed: () => saveOutput(
                            context,
                            ref,
                            suggestedName: defaultChecksumFileName(algo),
                            bytes: Uint8List.fromList(utf8.encode(ctl.buildChecksums())),
                            mimeType: 'text/plain',
                            toolId: kHashToolId,
                            defaultWorkspaceSubdir: canSaveNext ? p.relative(base, from: ws.rootPath) : null,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Verify mode

class _VerifyInput extends ConsumerWidget {
  const _VerifyInput();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(verifyProvider);
    final ctl = ref.read(verifyProvider.notifier);
    final ws = ref.watch(activeWorkspaceProvider);
    final source = ref.draft<VerifySource>('$kHashToolId/verifySource', VerifySource.file);
    final forced = ref.draft<HashAlgorithm?>('$kHashToolId/verifyAlgo', null);
    final pasted = ref.watch(draftTextProvider('$kHashToolId/verifyText'));
    final base = st.baseDir ?? ws?.rootPath;

    String baseLabel() {
      if (base == null) return 'not chosen';
      if (ws != null && SafePath.isWithin(ws.rootPath, base)) {
        final rel = workspaceLabel(ws, base);
        return rel == '.' ? '${ws.name} (workspace root)' : rel;
      }
      return 'folder of the imported copy (app storage)';
    }

    return NeonPanel(
      kicker: 'Input',
      title: 'Checksum list',
      icon: Icons.checklist_rtl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChoiceRow<VerifySource>(
            label: 'Source',
            options: VerifySource.values,
            selected: source,
            labelOf: (s) => s.label,
            onSelected: (s) => ref.setDraft('$kHashToolId/verifySource', s),
          ),
          const SizedBox(height: J3Space.md),
          if (source == VerifySource.file) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    st.checksumFile?.label ?? 'No checksum file chosen',
                    style: J3Type.code.copyWith(color: st.checksumFile == null ? J3Colors.textMuted : J3Colors.text),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: J3Space.sm),
            NeonButton.secondary(
              label: st.checksumFile == null ? 'Choose checksum file' : 'Choose another',
              icon: Icons.file_open_outlined,
              onPressed: st.running
                  ? null
                  : () async {
                      final sel = await pickInputFile(context, ref, title: 'Checksum file (SHA256SUMS, *.md5...)');
                      if (sel == null) return;
                      final item = FileItem(
                        path: sel.path,
                        label: sel.displayName,
                        inWorkspace: sel.fromWorkspace,
                        size: 0,
                      );
                      ctl.setChecksumFile(item);
                      if (!sel.fromWorkspace && ws != null) ctl.setBaseDir(ws.rootPath);
                    },
            ),
            if (st.checksumFile != null && !st.checksumFile!.inWorkspace) ...[
              const SizedBox(height: J3Space.sm),
              const InfoLine(
                'Imported checksum files are copied alone, so the listed files are looked up in the folder below.',
              ),
            ],
          ] else
            CodeField(
              key: const Key('hash.verifyText'),
              controller: pasted,
              label: 'Checksum lines',
              hint: '<hex>  path/to/file\n<hex> *binary.bin\nSHA256 (file.txt) = <hex>',
              minLines: 4,
              maxLines: 10,
            ),
          const SizedBox(height: J3Space.md),
          Text('Paths are relative to', style: J3Type.caption),
          const SizedBox(height: J3Space.xs),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(baseLabel(), style: J3Type.code),
              NeonButton.ghost(
                label: 'Change folder',
                icon: Icons.folder_open,
                dense: true,
                tooltip: ws == null ? 'Open a workspace to choose a folder' : 'Choose the folder the paths start from',
                onPressed: ws == null || st.running
                    ? null
                    : () async {
                        final f = await pickWorkspaceFolder(context, ref, title: 'Verify relative to...');
                        if (f != null) ctl.setBaseDir(f);
                      },
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          ChoiceRow<HashAlgorithm?>(
            label: 'Algorithm',
            options: const [null, ..._algoOrder],
            selected: forced,
            labelOf: (a) => a == null ? 'Auto-detect' : _algoLabel(a),
            onSelected: (a) => ref.setDraft('$kHashToolId/verifyAlgo', a),
          ),
          const SizedBox(height: J3Space.xs),
          const InfoLine('Auto uses the BSD tag, then the file name (SHA256SUMS, *.md5...), then the digest length.'),
          const SizedBox(height: J3Space.md),
          NeonButton(
            key: const Key('hash.verify'),
            label: 'Verify',
            icon: Icons.verified_outlined,
            busy: st.running,
            onPressed: () => ctl.verify(source: source, pastedText: pasted.text, forcedAlgorithm: forced),
          ),
        ],
      ),
    );
  }
}

class _VerifyResults extends ConsumerWidget {
  const _VerifyResults();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(verifyProvider);
    final report = st.report;
    final fx = context.effects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OperationProgressPanel(operationId: st.opId, label: 'Verifying...'),
        if (st.error != null) ErrorPanel(title: 'Cannot verify', error: st.error!),
        if (st.notice != null) InfoLine(st.notice!),
        if (report == null && st.error == null && !st.running)
          const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ ?=? ]',
              title: 'Nothing verified yet',
              message:
                  'Supports GNU "<hex>  file" and "<hex> *file" lines and BSD "SHA256 (file) = <hex>" lines. '
                  'Paths that leave the folder are never read.',
            ),
          ),
        if (report != null) ...[
          report.allOk
              ? StatusBanner(
                  kind: StatusKind.success,
                  title: 'ALL OK',
                  message: 'Every listed file matches (${report.results.length}).',
                )
              : StatusBanner(
                  kind: StatusKind.error,
                  title: 'PROBLEMS FOUND',
                  message:
                      '${report.count(VerifyStatus.failed)} failed, ${report.count(VerifyStatus.missing)} missing, '
                      '${report.count(VerifyStatus.invalid)} invalid, ${report.parseIssues.length} unreadable line(s).',
                ),
          const SizedBox(height: J3Space.lg),
          NeonPanel(
            kicker: 'Report',
            title: '${report.results.length} entries',
            icon: Icons.rule,
            actions: [
              IconButton(
                tooltip: 'Save / export report',
                onPressed: () => saveOutput(
                  context,
                  ref,
                  suggestedName: 'verify-report.txt',
                  bytes: Uint8List.fromList(utf8.encode(report.toText())),
                  mimeType: 'text/plain',
                  toolId: kHashToolId,
                ),
                icon: const Icon(Icons.save_alt_rounded, size: 18),
              ),
            ],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: J3Space.sm,
                  runSpacing: J3Space.sm,
                  children: [
                    for (final s in VerifyStatus.values)
                      StatTile(
                        label: s.label,
                        value: '${report.count(s)}',
                        icon: _statusIcon(s),
                        color: _statusKind(s).color,
                      ),
                  ],
                ),
                if (report.results.any((r) => r.algorithm?.isLegacy ?? false)) ...[
                  const SizedBox(height: J3Space.sm),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: StatusBadge(
                      kind: StatusKind.warning,
                      text: 'MD5/SHA-1 entries: compatibility only — not collision resistant',
                    ),
                  ),
                ],
                const SizedBox(height: J3Space.md),
                BoundedList(
                  itemCount: report.results.length,
                  itemBuilder: (context, i) {
                    final r = report.results[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          StatusBadge(dense: true, kind: _statusKind(r.status), text: r.status.label),
                          const SizedBox(width: J3Space.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.entry.path,
                                  style: J3Type.codeSmall.copyWith(color: J3Colors.text),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (r.detail != null) Text(r.detail!, style: J3Type.caption),
                                if (r.status == VerifyStatus.failed && r.actual != null)
                                  Text(
                                    'expected ${r.entry.digest}\nactual   ${r.actual}',
                                    style: J3Type.codeSmall.copyWith(fontSize: 11),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                if (report.parseIssues.isNotEmpty) ...[
                  const Divider(height: J3Space.xl),
                  Text('Ignored lines', style: J3Type.label.copyWith(color: fx.accentText)),
                  for (final issue in report.parseIssues.take(50))
                    Text('line ${issue.lineNumber}: ${issue.message}', style: J3Type.codeSmall),
                  if (report.parseIssues.length > 50)
                    Text('... ${report.parseIssues.length - 50} more', style: J3Type.caption),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

StatusKind _statusKind(VerifyStatus s) => switch (s) {
  VerifyStatus.ok => StatusKind.success,
  VerifyStatus.failed => StatusKind.error,
  VerifyStatus.missing => StatusKind.warning,
  VerifyStatus.invalid => StatusKind.warning,
};

IconData _statusIcon(VerifyStatus s) => switch (s) {
  VerifyStatus.ok => Icons.check_circle_outline,
  VerifyStatus.failed => Icons.error_outline,
  VerifyStatus.missing => Icons.help_outline,
  VerifyStatus.invalid => Icons.block,
};
