import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/widgets/neon_button.dart';

/// A bundled font and its licence text asset.
class BundledFontLicense {
  const BundledFontLicense({
    required this.family,
    required this.package,
    required this.asset,
    required this.usage,
    required this.copyright,
  });

  final String family;

  /// Name shown on the licence page.
  final String package;
  final String asset;
  final String usage;
  final String copyright;
}

const List<BundledFontLicense> kBundledFontLicenses = [
  BundledFontLicense(
    family: 'Chakra Petch',
    package: 'Chakra Petch (font)',
    asset: 'assets/licenses/OFL-ChakraPetch.txt',
    usage: 'Interface font: labels, headings and body text.',
    copyright: 'Copyright 2018 The Chakra Petch Project Authors',
  ),
  BundledFontLicense(
    family: 'JetBrains Mono',
    package: 'JetBrains Mono (font)',
    asset: 'assets/licenses/OFL-JetBrainsMono.txt',
    usage: 'Monospace font: ASCII art, code, paths and logs.',
    copyright: 'Copyright 2020 The JetBrains Mono Project Authors',
  ),
];

bool _registered = false;

/// Licence entries of the bundled fonts, read from `assets/licenses/`.
Stream<LicenseEntry> appLicenseEntries() async* {
  for (final font in kBundledFontLicenses) {
    final text = await rootBundle.loadString(font.asset);
    yield LicenseEntryWithLineBreaks([font.package], text);
  }
}

/// Adds the SIL OFL 1.1 texts of the bundled fonts to Flutter's
/// [LicenseRegistry] so they appear on the "Open-source licences" page next
/// to the licences of the Dart/Flutter packages. Call once from `main()`
/// before `runApp`. Further calls do nothing.
void registerAppLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(appLicenseEntries);
}

/// Whether [registerAppLicenses] has run in this process.
bool get appLicensesRegistered => _registered;

/// Shows the full licence text of a bundled font.
Future<void> showFontLicenseDialog(BuildContext context, BundledFontLicense font) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      return AlertDialog(
        title: Text('${font.family} - SIL Open Font License 1.1'),
        content: SizedBox(
          width: 620,
          height: size.height * 0.6,
          child: FutureBuilder<String>(
            future: rootBundle.loadString(font.asset),
            builder: (context, snap) {
              if (snap.hasError) {
                return Text('Could not load ${font.asset}: ${snap.error}', style: J3Type.bodySecondary);
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: J3Space.md),
                  child: SelectableText(snap.data!, style: J3Type.codeSmall),
                ),
              );
            },
          ),
        ),
        actions: [
          IntrinsicWidth(
            child: NeonButton.secondary(label: 'Close', dense: true, onPressed: () => Navigator.of(ctx).pop()),
          ),
        ],
      );
    },
  );
}
