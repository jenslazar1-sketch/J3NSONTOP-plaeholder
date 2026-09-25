import 'package:flutter/widgets.dart';

/// Spacing, radius, size and duration tokens.
abstract final class J3Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  static const EdgeInsets pagePadding = EdgeInsets.all(lg);
  static const EdgeInsets pagePaddingWide = EdgeInsets.symmetric(horizontal: xl, vertical: lg);
}

abstract final class J3Radius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const BorderRadius small = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius medium = BorderRadius.all(Radius.circular(md));
  static const BorderRadius large = BorderRadius.all(Radius.circular(lg));
}

abstract final class J3Size {
  /// Minimum interactive size (Material/iOS HIG guidance).
  static const double minTouchTarget = 48;
  static const double railCollapsed = 76;
  static const double railExpanded = 232;
  static const double activityPanel = 320;
  static const double topBar = 60;
  static const double maxContentWidth = 1280;
}

/// Layout breakpoints (logical pixels, shortest usable width).
abstract final class J3Breakpoints {
  static const double compact = 600;
  static const double medium = 900;
  static const double expanded = 1200;
  static const double wide = 1500;
}

abstract final class J3Durations {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 160);
  static const Duration medium = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 420);
  static const Duration glitch = Duration(milliseconds: 180);
}
