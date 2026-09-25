import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../../core/theme/j3_typography.dart';

// TODO(agent): replace with the full dashboard.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) => Center(child: Text(AppInfo.fullName, style: J3Type.headline));
}
