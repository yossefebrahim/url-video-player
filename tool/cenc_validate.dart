// Offline validation harness for CencDecryptor.
// Usage: dart run tool/cenc_validate.dart <keyHex> <init> <seg> <outInit> <outSeg>
import 'dart:io';
import 'dart:typed_data';

import 'package:vp/services/cenc_decryptor.dart';

Uint8List _hex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
    ]);

void main(List<String> args) {
  final key = _hex(args[0]);
  final init = File(args[1]).readAsBytesSync();
  final seg = File(args[2]).readAsBytesSync();

  final dec = CencDecryptor(key);
  final outInit = dec.rewriteInit(Uint8List.fromList(init));
  stderr.writeln('per_sample_IV_size = ${dec.ivSize}');
  final outSeg = dec.decryptSegment(Uint8List.fromList(seg));

  File(args[3]).writeAsBytesSync(outInit);
  File(args[4]).writeAsBytesSync(outSeg);
  stderr.writeln('wrote ${args[3]} (${outInit.length}) + ${args[4]} (${outSeg.length})');
}
