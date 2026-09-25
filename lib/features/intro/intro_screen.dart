import 'package:flutter/material.dart';

import '../../app/app_info.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/ascii_art.dart';
import 'skull_art.dart';

// TODO(agent): replace with the full animated laughing-skull intro.
class IntroScreen extends StatelessWidget {
  const IntroScreen({super.key, required this.onFinished, this.replay = false});

  final VoidCallback onFinished;
  final bool replay;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AsciiArt(lines: [...kSkullCranium, ...kSkullJaw]),
            Text(AppInfo.fullName, style: J3Type.title),
            TextButton(onPressed: onFinished, child: const Text('Skip')),
          ],
        ),
      ),
    );
  }
}
