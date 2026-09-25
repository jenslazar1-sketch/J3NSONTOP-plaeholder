import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;

/// One entry for [buildRawZip]. Every field can be set to hostile values to
/// test the archive validator.
class RawZipEntry {
  RawZipEntry(
    this.name,
    List<int> data, {
    this.deflate = false,
    this.unixMode,
    this.madeOnUnix = true,
    this.declaredSize,
    this.crcOverride,
    this.localName,
    this.encrypted = false,
    this.method,
  }) : data = Uint8List.fromList(data);

  final String name;
  final Uint8List data;
  final bool deflate;

  /// e.g. 0xA1FF for a symlink, 0x81A4 for a regular file.
  final int? unixMode;
  final bool madeOnUnix;

  /// Lie about the uncompressed size.
  final int? declaredSize;
  final int? crcOverride;

  /// Different name in the local header than in the central directory.
  final String? localName;
  final bool encrypted;

  /// Force a compression method id (e.g. 12 for bzip2).
  final int? method;
}

/// Builds a ZIP byte-for-byte, allowing malformed/hostile archives.
Uint8List buildRawZip(List<RawZipEntry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

  for (final e in entries) {
    final nameBytes = e.name.codeUnits;
    final localNameBytes = (e.localName ?? e.name).codeUnits;
    final payload = e.deflate ? Uint8List.fromList(ZLibEncoder(raw: true).convert(e.data)) : e.data;
    final method = e.method ?? (e.deflate ? 8 : 0);
    final crc = e.crcOverride ?? getCrc32(e.data);
    final size = e.declaredSize ?? e.data.length;
    final flags = (e.encrypted ? 1 : 0) | 0x800; // UTF-8 names
    final offset = out.length;

    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, flags);
    u16(out, method);
    u16(out, 0);
    u16(out, 0x21);
    u32(out, crc);
    u32(out, payload.length);
    u32(out, size);
    u16(out, localNameBytes.length);
    u16(out, 0);
    out.add(localNameBytes);
    out.add(payload);

    u32(central, 0x02014b50);
    u16(central, e.madeOnUnix ? (3 << 8) | 20 : 20);
    u16(central, 20);
    u16(central, flags);
    u16(central, method);
    u16(central, 0);
    u16(central, 0x21);
    u32(central, crc);
    u32(central, payload.length);
    u32(central, size);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, (e.unixMode ?? (e.name.endsWith('/') ? 0x41ED : 0x81A4)) << 16);
    u32(central, offset);
    central.add(nameBytes);
  }
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, cd.length);
  u32(out, cdOffset);
  u16(out, 0);
  return out.toBytes();
}

String writeRawZip(Directory dir, String name, List<RawZipEntry> entries) {
  final f = File('${dir.path}/$name')..writeAsBytesSync(buildRawZip(entries));
  return f.path;
}
