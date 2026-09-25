import '../../../core/activity/activity_controller.dart';
import '../../../core/activity/operation.dart';
import '../../../core/commands/terminal_command.dart';
import '../../../core/utils/format.dart';

/// `history [n] [--failed]`: recent operations from the activity log.
class HistoryCommand extends TerminalCommand {
  const HistoryCommand();

  static const int defaultCount = 20;
  static const int maxCount = 300;

  @override
  String get name => 'history';

  @override
  String get summary => 'Show recent operations (what tools actually did)';

  @override
  String get usage => 'history [n] [--failed]';

  @override
  List<CommandArg> get args => const [
    CommandArg('n', 'How many operations to show (1-300, default 20)', optional: true),
    CommandArg('--failed', 'Only failed operations', optional: true, values: ['--failed']),
  ];

  @override
  List<String> get examples => const ['history', 'history 5', 'history --failed'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    var count = defaultCount;
    final raw = args.at(0);
    if (raw != null) {
      final n = int.tryParse(raw);
      if (n == null || n < 1 || n > maxCount) {
        return CommandResult.error('"$raw" is not a count between 1 and $maxCount.', usage: usage);
      }
      count = n;
    }
    final failedOnly = args.flag('failed', 'f');
    final all = ctx.read(activityProvider).operations;
    final matching = failedOnly ? all.where((o) => o.status == OperationStatus.failed).toList() : all;
    if (matching.isEmpty) {
      return CommandResult.ok([
        TermLine.dim(failedOnly ? 'No failed operations recorded.' : 'No operations recorded yet.'),
        TermLine.dim('Operations appear here when tools read, write or process files.'),
      ]);
    }
    final shown = matching.take(count).toList();
    final w = shown.fold<int>(0, (m, o) => o.status.label.length > m ? o.status.label.length : m);
    return CommandResult.ok([
      for (final o in shown) ..._describe(o, w),
      TermLine.dim(
        'showing ${shown.length} of ${matching.length}${failedOnly ? ' failed' : ''} '
        'operation${matching.length == 1 ? '' : 's'} (newest first). Details: `open activity`.',
      ),
    ]);
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) =>
      typedArgs.sublist(0, typedArgs.isEmpty ? 0 : typedArgs.length - 1).contains('--failed')
      ? const []
      : const ['--failed'];

  List<TermLine> _describe(OperationRecord o, int width) {
    final when = Fmt.dateTime(o.startedAt).substring(0, 16);
    final detail = switch (o.status) {
      OperationStatus.failed => o.error == null ? '' : ' — error: ${o.error}',
      OperationStatus.running =>
        o.progress == null ? ' — running' : ' — ${(o.progress! * 100).round()}% ${o.progressMessage ?? ''}',
      _ => o.summary == null ? '' : ' — ${o.summary}',
    };
    final text = '$when  ${o.status.label.padRight(width)}  ${o.title}$detail'.trimRight();
    final style = switch (o.status) {
      OperationStatus.succeeded => TermStyle.success,
      OperationStatus.warning => TermStyle.warning,
      OperationStatus.failed => TermStyle.error,
      OperationStatus.cancelled => TermStyle.dim,
      OperationStatus.running => TermStyle.accent,
    };
    return [TermLine(text, style)];
  }
}
