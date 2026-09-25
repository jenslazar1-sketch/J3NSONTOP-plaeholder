import 'package:flutter/material.dart';

import '../../core/tools/tool_definition.dart';
import 'presentation/browser/browser_page.dart';
import 'presentation/editor/editor_page.dart';
import 'presentation/find/find_files_page.dart';
import 'presentation/hex/hex_page.dart';
import 'presentation/manager/manager_view.dart';
import 'presentation/rename/batch_rename_page.dart';
import 'presentation/replace/replace_page.dart';
import 'presentation/search/search_text_page.dart';
import 'presentation/shared/requests.dart';

/// Workspaces + file handling: workspace records, browser, editors,
/// search, batch rename and replace.
final FeatureModule workspacesModule = FeatureModule(
  id: 'workspaces',
  landings: [SectionLanding(ToolSection.workspaces, (_) => const WorkspacesLandingPage())],
  tools: [
    ToolDefinition(
      id: WsTools.manager,
      name: 'Workspace Manager',
      section: ToolSection.workspaces,
      description: 'Create, link, import (files, folder, ZIP), switch, export and remove workspaces.',
      icon: Icons.folder_special_outlined,
      keywords: const [
        'workspace',
        'project',
        'import',
        'link',
        'folder',
        'zip',
        'export',
        'switch',
        'active',
        'sample',
        'remove',
      ],
      builder: (_) => const WorkspaceManagerPage(),
    ),
    ToolDefinition(
      id: WsTools.browser,
      name: 'File Browser',
      section: ToolSection.workspaces,
      description: 'Browse workspace files: details, SHA-256, rename, new folder, export and a restorable trash.',
      icon: Icons.folder_open_outlined,
      keywords: const [
        'files',
        'explorer',
        'browse',
        'folder',
        'rename',
        'delete',
        'trash',
        'restore',
        'hash',
        'sha256',
        'details',
      ],
      builder: (_) => const FileBrowserPage(),
    ),
    ToolDefinition(
      id: WsTools.editor,
      name: 'Text Editor',
      section: ToolSection.workspaces,
      description: 'Edit text and config files keeping encoding and line endings; find, go to line, backups on save.',
      icon: Icons.edit_note,
      keywords: const [
        'text',
        'edit',
        'editor',
        'notepad',
        'config',
        'ini',
        'json',
        'encoding',
        'utf-8',
        'crlf',
        'line endings',
      ],
      builder: (_) => const TextEditorPage(),
    ),
    ToolDefinition(
      id: WsTools.hex,
      name: 'Hex Viewer',
      section: ToolSection.workspaces,
      description: 'Inspect any file byte by byte with paged reads, jump to offset and hex/text pattern search.',
      icon: Icons.memory,
      keywords: const ['hex', 'binary', 'bytes', 'offset', 'dump', 'inspect', 'search bytes', 'viewer'],
      builder: (_) => const HexViewerPage(),
    ),
    ToolDefinition(
      id: WsTools.findFiles,
      name: 'Find Files',
      section: ToolSection.workspaces,
      description: 'Find files by name with substring, glob (**/*.json) or regex patterns.',
      icon: Icons.manage_search,
      keywords: const ['find', 'search', 'filename', 'glob', 'wildcard', 'regex', 'locate'],
      builder: (_) => const FindFilesPage(),
    ),
    ToolDefinition(
      id: WsTools.searchText,
      name: 'Search in Files',
      section: ToolSection.workspaces,
      description: 'Search file contents (plain or regex, whole word, glob filter) with results grouped by file.',
      icon: Icons.find_in_page_outlined,
      keywords: const ['grep', 'search', 'text', 'content', 'regex', 'find in files', 'occurrences'],
      builder: (_) => const SearchTextPage(),
    ),
    ToolDefinition(
      id: WsTools.batchRename,
      name: 'Batch Rename',
      section: ToolSection.workspaces,
      description: 'Rename many files with find/replace, numbering and case rules; live preview, collisions and undo.',
      icon: Icons.drive_file_rename_outline,
      keywords: const ['rename', 'batch', 'bulk', 'numbering', 'files', 'case', 'extension', 'undo'],
      builder: (_) => const BatchRenamePage(),
    ),
    ToolDefinition(
      id: WsTools.replace,
      name: 'Replace in Files',
      section: ToolSection.workspaces,
      description: 'Find and replace across files with a diff preview, per-file selection and automatic backups.',
      icon: Icons.find_replace,
      keywords: const ['replace', 'find', 'sed', 'substitute', 'regex', 'bulk edit', 'diff'],
      builder: (_) => const ReplacePage(),
    ),
  ],
);
