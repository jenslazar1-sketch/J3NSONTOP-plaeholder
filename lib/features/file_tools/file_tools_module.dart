import 'package:flutter/material.dart';

import '../../core/tools/tool_definition.dart';
import 'commands/hash_command.dart';
import 'presentation/duplicates/duplicates_page.dart';
import 'presentation/hash/hash_page.dart';
import 'presentation/line_endings/line_endings_page.dart';
import 'presentation/logs/log_viewer_page.dart';
import 'presentation/whitespace/whitespace_page.dart';
import 'presentation/zip/zip_page.dart';

/// File Tools: hashes and checksum lists, duplicate finder with reversible
/// quarantine, line-ending and whitespace cleanup, ZIP studio and a log
/// viewer, plus the terminal `hash` command. See docs/FILE_TOOLS.md.
final FeatureModule fileToolsModule = FeatureModule(
  id: 'file_tools',
  tools: [
    ToolDefinition(
      id: 'files.hash',
      name: 'Hash & Checksum',
      section: ToolSection.fileTools,
      description:
          'SHA-256/512, SHA-1 and MD5 of text or files, compare with an expected digest, verify and create '
          'SHA256SUMS lists.',
      icon: Icons.fingerprint,
      keywords: const [
        'hash',
        'checksum',
        'digest',
        'sha256',
        'sha-256',
        'sha512',
        'sha1',
        'md5',
        'sha256sums',
        'md5sums',
        'verify',
        'integrity',
        'compare',
        'fingerprint',
      ],
      builder: (_) => const HashPage(),
    ),
    ToolDefinition(
      id: 'files.duplicates',
      name: 'Duplicate Finder',
      section: ToolSection.fileTools,
      description: 'Find identical files by size and SHA-256, pick keepers and move copies to a reversible quarantine.',
      icon: Icons.file_copy_outlined,
      keywords: const [
        'duplicate',
        'duplicates',
        'dedupe',
        'dedup',
        'identical',
        'copies',
        'same files',
        'disk space',
        'cleanup',
        'quarantine',
        'wasted space',
        'restore',
      ],
      builder: (_) => const DuplicatesPage(),
    ),
    ToolDefinition(
      id: 'files.line_endings',
      name: 'Line Endings',
      section: ToolSection.fileTools,
      description: 'Count LF, CRLF and CR, spot mixed endings and convert text or files, keeping their encoding.',
      icon: Icons.keyboard_return,
      keywords: const [
        'line endings',
        'eol',
        'newline',
        'crlf',
        'lf',
        'cr',
        'dos2unix',
        'unix2dos',
        'carriage return',
        'mixed',
        'convert',
      ],
      builder: (_) => const LineEndingsPage(),
    ),
    ToolDefinition(
      id: 'files.whitespace',
      name: 'Whitespace Cleanup',
      section: ToolSection.fileTools,
      description:
          'Trim trailing spaces, fix tabs, blank lines, final newline, BOM and invisible spaces with a live diff.',
      icon: Icons.cleaning_services_outlined,
      keywords: const [
        'whitespace',
        'trailing',
        'trim',
        'tabs',
        'spaces',
        'indentation',
        'blank lines',
        'final newline',
        'bom',
        'nbsp',
        'zero width',
        'tidy',
        'format',
      ],
      builder: (_) => const WhitespacePage(),
    ),
    ToolDefinition(
      id: 'files.zip',
      name: 'ZIP Studio',
      section: ToolSection.fileTools,
      description: 'Create ZIP archives and inspect/extract them safely: every entry is checked before writing.',
      icon: Icons.folder_zip_outlined,
      keywords: const [
        'zip',
        'unzip',
        'archive',
        'compress',
        'extract',
        'decompress',
        'pack',
        'unpack',
        'j3mod',
        'zip bomb',
        'inspect',
      ],
      builder: (_) => const ZipPage(),
    ),
    ToolDefinition(
      id: 'files.logs',
      name: 'Log Viewer',
      section: ToolSection.fileTools,
      description: 'Open big logs, filter by severity, search plain or regex, select and export lines with context.',
      icon: Icons.receipt_long_outlined,
      keywords: const [
        'log',
        'logs',
        'logcat',
        'error',
        'warning',
        'severity',
        'tail',
        'crash',
        'stack trace',
        'grep',
        'regex',
        'filter',
      ],
      builder: (_) => const LogViewerPage(),
    ),
  ],
  commands: const [HashCommand()],
);
