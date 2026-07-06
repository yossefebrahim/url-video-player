// Runs the CastProxyServer against a real ClearKey DASH URL so an external
// player (ffmpeg) can verify the served manifest+segments are clear & playable.
// Usage: dart run tool/proxy_validate.dart <keyHex> <mpdUrl>
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:vp/services/cast_proxy_server.dart';
import 'package:vp/services/cenc_decryptor.dart';

Uint8List _hex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)
    ]);

Future<void> main(List<String> args) async {
  final server = CastProxyServer(
    upstreamMpdUrl: args[1],
    decryptor: CencDecryptor(_hex(args[0])),
    upstreamHeaders: const {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0'
    },
  );
  final url = await server.start();
  stdout.writeln('PROXY_URL=$url');
  await Future<void>.delayed(const Duration(seconds: 90));
  await server.stop();
}
