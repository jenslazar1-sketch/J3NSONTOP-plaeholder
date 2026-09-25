import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/storage/user_data.dart';
import '../domain/color_model.dart';
import '../domain/palette.dart';

/// The saved Color Lab palette, persisted in `features.json` under
/// [PaletteDocument.storageKey] as a versioned payload.
class PaletteController extends Notifier<PaletteDocument> {
  static const _uuid = Uuid();

  @override
  PaletteDocument build() => PaletteDocument.fromJson(ref.watch(featureDataProvider)[PaletteDocument.storageKey]);

  void _save(PaletteDocument next) {
    state = next;
    // featureDataProvider updates its state synchronously; the file write
    // completes in the background and failures are reported as a toast.
    unawaited(
      ref.read(featureDataProvider.notifier).write(PaletteDocument.storageKey, next.toJson()).catchError((Object e) {
        ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Palette could not be saved: $e');
      }),
    );
  }

  /// Adds [color]; returns the new swatch id.
  String add(Rgba color, {String? name}) {
    final id = _uuid.v4();
    final label = (name == null || name.trim().isEmpty) ? ColorFormat.hex(color) : name.trim();
    _save(state.add(Swatch(id: id, name: label, color: color)));
    return id;
  }

  void remove(String id) => _save(state.remove(id));

  void rename(String id, String name) => _save(state.rename(id, name));

  void move(int from, int to) => _save(state.move(from, to));

  void clear() => _save(const PaletteDocument());
}

final paletteProvider = NotifierProvider<PaletteController, PaletteDocument>(PaletteController.new);
