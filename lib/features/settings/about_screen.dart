import 'package:flutter/material.dart';

import '../../app/app_info.dart';

// TODO(agent): replace with the full About screen.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => const Center(child: Text(AppInfo.fullName));
}
