import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../../../core/tasks/cancellation.dart';
import '../domain/hex_math.dart';

/// Read-only paged access to a file of any size. Pages are read with a
/// [RandomAccessFile] on demand and kept in a small LRU cache, so memory
/// stays bounded (pageSize x maxPages) no matter how large the file is.
class HexPager {
  HexPager._(this.path, this._raf, this.length, this.pageSize, this.maxPages);

  static Future<HexPager> open(String path, {int pageSize = 64 * 1024, int maxPages = 32}) async {
    final raf = await File(path).open();
    try {
      final len = await raf.length();
      return HexPager._(path, raf, len, pageSize, maxPages);
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  final String path;
  final RandomAccessFile _raf;
  final int length;
  final int pageSize;
  final int maxPages;
  final LinkedHashMap<int, Uint8List> _cache = LinkedHashMap();
  final Map<int, Future<Uint8List>> _inflight = {};
  Future<void> _lock = Future.value();
  bool _closed = false;

  HexLayout layout([int bytesPerRow = 16]) => HexLayout(fileSize: length, bytesPerRow: bytesPerRow, pageSize: pageSize);

  int get cachedPages => _cache.length;
  bool get isClosed => _closed;

  /// The page if already cached (marks it recently used), else null.
  Uint8List? cachedPage(int index) {
    final page = _cache.remove(index);
    if (page != null) _cache[index] = page;
    return page;
  }

  /// Loads page [index] (cached, de-duplicated, reads serialised because a
  /// RandomAccessFile allows one pending operation at a time).
  Future<Uint8List> page(int index) {
    final cached = cachedPage(index);
    if (cached != null) return Future.value(cached);
    final pending = _inflight[index];
    if (pending != null) return pending;
    final f = _serial(() async {
      if (_closed) throw const FileSystemException('Viewer was closed');
      final start = index * pageSize;
      if (start >= length) return Uint8List(0);
      await _raf.setPosition(start);
      final want = length - start < pageSize ? length - start : pageSize;
      final data = await _raf.read(want);
      _cache[index] = data;
      while (_cache.length > maxPages) {
        _cache.remove(_cache.keys.first);
      }
      return data;
    });
    _inflight[index] = f;
    return f.whenComplete(() => _inflight.remove(index));
  }

  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Bytes [start, start+count) (clamped to the file), across pages.
  Future<Uint8List> read(int start, int count) async {
    if (start >= length || count <= 0) return Uint8List(0);
    final end = start + count > length ? length : start + count;
    final out = Uint8List(end - start);
    var pos = start;
    while (pos < end) {
      final pageIndex = pos ~/ pageSize;
      final data = await page(pageIndex);
      final inPage = pos - pageIndex * pageSize;
      final take = (end - pos) < (data.length - inPage) ? end - pos : data.length - inPage;
      if (take <= 0) break;
      out.setRange(pos - start, pos - start + take, data, inPage);
      pos += take;
    }
    return out;
  }

  /// Synchronous read when every needed page is cached, else null.
  Uint8List? readCached(int start, int count) {
    if (start >= length || count <= 0) return Uint8List(0);
    final end = start + count > length ? length : start + count;
    final out = Uint8List(end - start);
    var pos = start;
    while (pos < end) {
      final pageIndex = pos ~/ pageSize;
      final data = cachedPage(pageIndex);
      if (data == null) return null;
      final inPage = pos - pageIndex * pageSize;
      final take = (end - pos) < (data.length - inPage) ? end - pos : data.length - inPage;
      out.setRange(pos - start, pos - start + take, data, inPage);
      pos += take;
    }
    return out;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cache.clear();
    await _serial(() => _raf.close());
  }
}

/// Chunked, cancellable pattern search over a file. Uses its own file
/// handle so it never evicts the viewer's cache, and yields to the event
/// loop between chunks so the UI stays responsive.
abstract final class HexSearch {
  static const int defaultChunk = 1 << 20;

  static Future<int?> findNext(
    String path,
    BytePattern pattern, {
    required int from,
    CancellationToken? token,
    int chunk = defaultChunk,
    void Function(double fraction)? onProgress,
  }) async {
    final raf = await File(path).open();
    try {
      final size = await raf.length();
      final windows = forwardWindows(
        from: from,
        fileSize: size,
        chunk: chunk < pattern.length ? pattern.length : chunk,
        patternLength: pattern.length,
      );
      for (final w in windows) {
        token?.throwIfCancelled();
        await raf.setPosition(w.start);
        final data = await raf.read(w.length);
        final i = pattern.indexIn(data);
        if (i >= 0) return w.start + i;
        onProgress?.call(size == 0 ? 1 : w.end / size);
        await Future<void>.delayed(Duration.zero);
      }
      return null;
    } finally {
      await raf.close();
    }
  }

  static Future<int?> findPrevious(
    String path,
    BytePattern pattern, {
    required int from,
    CancellationToken? token,
    int chunk = defaultChunk,
    void Function(double fraction)? onProgress,
  }) async {
    if (from < 0) return null;
    final raf = await File(path).open();
    try {
      final size = await raf.length();
      final windows = backwardWindows(
        from: from,
        fileSize: size,
        chunk: chunk < pattern.length ? pattern.length : chunk,
        patternLength: pattern.length,
      );
      for (final w in windows) {
        token?.throwIfCancelled();
        await raf.setPosition(w.start);
        final data = await raf.read(w.length);
        final limit = from - w.start;
        final i = pattern.lastIndexIn(data, limit);
        if (i >= 0) return w.start + i;
        onProgress?.call(size == 0 ? 1 : 1 - w.start / size);
        await Future<void>.delayed(Duration.zero);
      }
      return null;
    } finally {
      await raf.close();
    }
  }

  /// Counts matches (overlapping allowed) in one pass, stopping at [limit].
  static Future<int> count(
    String path,
    BytePattern pattern, {
    CancellationToken? token,
    int limit = 100000,
    int chunk = defaultChunk,
    void Function(double fraction)? onProgress,
  }) async {
    final raf = await File(path).open();
    try {
      final size = await raf.length();
      final m = pattern.length;
      final windows = forwardWindows(from: 0, fileSize: size, chunk: chunk < m ? m : chunk, patternLength: m);
      var n = 0;
      for (var wi = 0; wi < windows.length; wi++) {
        token?.throwIfCancelled();
        final w = windows[wi];
        await raf.setPosition(w.start);
        final data = await raf.read(w.length);
        // Matches starting in the overlap belong to the next window.
        final ownedEnd = wi == windows.length - 1 ? data.length : w.length - (m - 1);
        var i = pattern.indexIn(data);
        while (i >= 0 && i < ownedEnd) {
          if (++n >= limit) return n;
          i = pattern.indexIn(data, i + 1);
        }
        onProgress?.call(size == 0 ? 1 : w.end / size);
        await Future<void>.delayed(Duration.zero);
      }
      return n;
    } finally {
      await raf.close();
    }
  }
}
