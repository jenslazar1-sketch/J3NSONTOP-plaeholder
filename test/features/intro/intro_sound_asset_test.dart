import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/intro/intro_sound.dart';
import 'package:j3nsontop_multitool/features/intro/intro_timeline.dart';

void main() {
  test('intro sound asset: 22.05 kHz mono 16-bit PCM WAV, <= 5 s, <= 250 KB', () {
    final file = File('assets/$kIntroSoundAsset');
    expect(file.existsSync(), isTrue, reason: 'generate it with tool/sound/generate_intro_sound.py');
    final bytes = file.readAsBytesSync();
    expect(bytes.length, lessThanOrEqualTo(250 * 1024));
    final data = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    expect(tag(0), 'RIFF');
    expect(tag(8), 'WAVE');

    int? channels;
    int? rate;
    int? bits;
    int? format;
    int? dataSize;
    var at = 12;
    while (at + 8 <= bytes.length) {
      final id = tag(at);
      final size = data.getUint32(at + 4, Endian.little);
      if (id == 'fmt ') {
        format = data.getUint16(at + 8, Endian.little);
        channels = data.getUint16(at + 10, Endian.little);
        rate = data.getUint32(at + 12, Endian.little);
        bits = data.getUint16(at + 22, Endian.little);
      } else if (id == 'data') {
        dataSize = size;
      }
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
    expect(format, 1, reason: 'PCM');
    expect(channels, 1);
    expect(rate, 22050);
    expect(bits, 16);
    final seconds = dataSize! / (rate! * 2);
    expect(seconds, lessThanOrEqualTo(5.0));
    // Long enough to cover the laugh and the glitch of the decorative timeline.
    expect(seconds, greaterThan(IntroTimeline()[IntroPhase.glitch].end));
  });
}
