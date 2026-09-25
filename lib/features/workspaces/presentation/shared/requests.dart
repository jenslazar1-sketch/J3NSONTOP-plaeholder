import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// Tool ids of this feature (stable; used in routes and history).
abstract final class WsTools {
  static const manager = 'workspaces.manager';
  static const browser = 'workspaces.browser';
  static const editor = 'workspaces.editor';
  static const hex = 'workspaces.hex';
  static const findFiles = 'workspaces.find_files';
  static const searchText = 'workspaces.search_text';
  static const batchRename = 'workspaces.batch_rename';
  static const replace = 'workspaces.replace';

  static String route(String id) => '/tool/$id';
}

/// A request to open [path] in the text editor or hex viewer. [seq]
/// increases with every request so the receiving page can tell new
/// requests from ones it already handled.
@immutable
class OpenFileRequest {
  const OpenFileRequest({required this.path, required this.seq, this.line, this.column, this.offset});

  final String path;
  final int seq;

  /// 1-based line/column for the editor.
  final int? line;
  final int? column;

  /// Byte offset for the hex viewer.
  final int? offset;
}

class OpenRequestController extends Notifier<OpenFileRequest?> {
  int _seq = 0;
  int _claimed = 0;

  @override
  OpenFileRequest? build() => null;

  void open(String path, {int? line, int? column, int? offset}) =>
      state = OpenFileRequest(path: path, seq: ++_seq, line: line, column: column, offset: offset);

  /// The pending request, handed out exactly once. Tracked here (not in a
  /// page) so a page rebuilt later never replays an old request.
  OpenFileRequest? claim() {
    final r = state;
    if (r == null || r.seq <= _claimed) return null;
    _claimed = r.seq;
    return r;
  }

  bool get hasPending => (state?.seq ?? 0) > _claimed;
}

/// Shared, non-autoDispose hand-over from other tools to the text editor.
final editorRequestProvider = NotifierProvider<OpenRequestController, OpenFileRequest?>(OpenRequestController.new);

/// Shared hand-over to the hex viewer.
final hexRequestProvider = NotifierProvider<OpenRequestController, OpenFileRequest?>(OpenRequestController.new);

/// Folder hand-over to the file browser (e.g. "show in browser").
final browserRequestProvider = NotifierProvider<OpenRequestController, OpenFileRequest?>(OpenRequestController.new);

/// Navigation used by this feature. Tests override it to record routes
/// without a router.
final wsNavigatorProvider = Provider<void Function(BuildContext context, String route)>(
  (ref) =>
      (context, route) => GoRouter.of(context).go(route),
);

extension WsNavigation on WidgetRef {
  void goTool(BuildContext context, String toolId) => read(wsNavigatorProvider)(context, WsTools.route(toolId));

  void goRoute(BuildContext context, String route) => read(wsNavigatorProvider)(context, route);

  void openInEditor(BuildContext context, String path, {int? line, int? column}) {
    read(editorRequestProvider.notifier).open(path, line: line, column: column);
    goTool(context, WsTools.editor);
  }

  void openInHex(BuildContext context, String path, {int? offset}) {
    read(hexRequestProvider.notifier).open(path, offset: offset);
    goTool(context, WsTools.hex);
  }

  void showInBrowser(BuildContext context, String path) {
    read(browserRequestProvider.notifier).open(path);
    goTool(context, WsTools.browser);
  }
}
