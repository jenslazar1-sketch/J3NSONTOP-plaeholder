import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wall clock used by the timestamp, UUID and JWT tools and the `ts` and
/// `uuid` commands. Tests override it with a fixed time.
final devClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
