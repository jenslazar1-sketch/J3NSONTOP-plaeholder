import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/user_data.dart';
import '../domain/http_history.dart';

/// Key in `features.json` holding `{"v":1,"items":[...]}` (newest first).
const String httpHistoryKey = 'dev_tools.http_history';

/// The persisted, already-redacted request history (max 50).
final httpHistoryProvider = Provider<List<HttpHistoryEntry>>(
  (ref) => HttpHistoryEntry.decodeList(ref.watch(featureDataProvider)[httpHistoryKey]),
);

/// Writes the history. Entries are redacted by [HttpHistoryEntry.record]
/// before they get here, and re-redacted when decoded.
class HttpHistoryStore {
  HttpHistoryStore(this._ref);
  final Ref _ref;

  List<HttpHistoryEntry> get items => HttpHistoryEntry.decodeList(_ref.read(featureDataProvider)[httpHistoryKey]);

  Future<void> add(HttpHistoryEntry entry) => _ref
      .read(featureDataProvider.notifier)
      .write(httpHistoryKey, HttpHistoryEntry.encodeList([entry, ...items.where((e) => e.id != entry.id)]));

  Future<void> remove(String id) => _ref
      .read(featureDataProvider.notifier)
      .write(httpHistoryKey, HttpHistoryEntry.encodeList(items.where((e) => e.id != id).toList()));

  Future<void> clear() => _ref.read(featureDataProvider.notifier).write(httpHistoryKey, null);
}

final httpHistoryStoreProvider = Provider<HttpHistoryStore>(HttpHistoryStore.new);
