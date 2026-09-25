/// Human-readable formatting helpers shared by all tools.
abstract final class Fmt {
  static String bytes(int bytes, {int decimals = 1}) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var i = 0;
    while (value >= 1024 && i < units.length - 1) {
      value /= 1024;
      i++;
    }
    return '${value.toStringAsFixed(decimals)} ${units[i]}';
  }

  static String duration(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
    if (d.inSeconds < 60) {
      return '${(d.inMilliseconds / 1000).toStringAsFixed(2)} s';
    }
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// `2026-09-25 18:41:07` in local time.
  static String dateTime(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${_two(l.month)}-${_two(l.day)} '
        '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
  }

  static String time(DateTime t) {
    final l = t.toLocal();
    return '${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
  }

  /// Filesystem-safe timestamp: `20260925-184107`.
  static String stamp(DateTime t) {
    final l = t.toLocal();
    return '${l.year}${_two(l.month)}${_two(l.day)}-'
        '${_two(l.hour)}${_two(l.minute)}${_two(l.second)}';
  }

  static String relative(DateTime t, {DateTime? now}) {
    final diff = (now ?? DateTime.now()).difference(t);
    if (diff.inSeconds < 45) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    if (diff.inDays < 7) return '${diff.inDays} d ago';
    return dateTime(t).substring(0, 10);
  }

  static String count(int n, String singular, [String? plural]) =>
      '$n ${n == 1 ? singular : (plural ?? '${singular}s')}';
}
