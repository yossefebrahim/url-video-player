// Runs the HlsCastProxy against a real live-HLS channel so an external player
// (ffprobe/ffmpeg) can verify the served playlist + segments are clear TS and
// decode. The receiver's job (HEVC decode) is separate — this proves the phone
// side (UA fetch, playlist rewrite, AES-128 strip, live re-poll).
//
// Usage: dart run tool/hls_proxy_validate.dart '<playlistUrl>' '<userAgent>'
import 'dart:async';
import 'dart:io';

import 'package:vp/services/cast_proxy_server.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln('usage: dart run tool/hls_proxy_validate.dart <playlistUrl> [userAgent]');
    return;
  }
  final proxy = HlsCastProxy(
    upstreamPlaylistUrl: args[0],
    upstreamHeaders: {
      if (args.length > 1 && args[1].isNotEmpty) 'User-Agent': args[1],
    },
  );
  final url = await proxy.start();
  stdout.writeln('PROXY_URL=$url');
  // Keep alive long enough to ffprobe / ffmpeg-record a few live segments.
  await Future<void>.delayed(const Duration(seconds: 90));
  await proxy.stop();
}
