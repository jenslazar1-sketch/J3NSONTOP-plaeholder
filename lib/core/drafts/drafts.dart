import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Session-lifetime text controllers keyed by `'<toolId>/<field>'`.
///
/// Tools use these instead of widget-local controllers so unfinished input
/// survives navigating to another tool and back:
///
/// ```dart
/// final input = ref.watch(draftTextProvider('dev.base64/input'));
/// TextField(controller: input)
/// ```
final draftTextProvider = Provider.family<TextEditingController, String>((
  ref,
  key,
) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// Session-lifetime arbitrary values keyed by `'<toolId>/<field>'` for
/// options such as selected mode, algorithm or last result.
class DraftValue extends Notifier<Object?> {
  DraftValue(this.key);
  final String key;

  @override
  Object? build() => null;

  void set(Object? value) => state = value;
}

final draftValueProvider = NotifierProvider.family<DraftValue, Object?, String>(
  DraftValue.new,
);

extension DraftRead on WidgetRef {
  /// Reads a typed draft value with a fallback.
  T draft<T>(String key, T fallback) {
    final v = watch(draftValueProvider(key));
    return v is T ? v : fallback;
  }

  void setDraft(String key, Object? value) =>
      read(draftValueProvider(key).notifier).set(value);
}
