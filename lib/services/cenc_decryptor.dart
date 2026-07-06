import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// In-place decryptor for **CENC** (`cenc` scheme, AES-128-CTR) fragmented MP4.
///
/// The whole approach is size-preserving: every encryption-signalling box is
/// renamed to `free` (4 bytes, same length) and the `mdat` sample payload is
/// decrypted in place. Because no box changes size, no `trun`/`sidx`/`moof`
/// offset ever needs recomputation — which is what makes a from-scratch Dart
/// implementation safe.
///
///  * [rewriteInit] turns an init segment clear: `encv`→`avc1`, `enca`→`mp4a`,
///    `sinf`→`free`, `pssh`→`free`; it also reads `per_sample_IV_size` from
///    `tenc`.
///  * [decryptSegment] AES-CTR-decrypts each sample's protected bytes using the
///    per-sample IVs in `senc` (subsample-aware for video; whole-sample for
///    audio), then neutralises `senc`/`saiz`/`saio`/`sbgp`/`sgpd`/`pssh`.
///
/// Reused for casting DRM (ClearKey) series to a Chromecast, whose default
/// receiver can't decrypt CENC — the phone decrypts and serves clear DASH.
class CencDecryptor {
  /// 16-byte content key (the ClearKey `k`).
  final Uint8List key;

  /// per_sample_IV_size from `tenc` (8 for these streams); updated by [rewriteInit].
  int ivSize;

  CencDecryptor(this.key, {this.ivSize = 8});

  /// Rewrites [input] init segment to clear and captures [ivSize] from `tenc`.
  Uint8List rewriteInit(Uint8List input) {
    final data = Uint8List.fromList(input);
    for (final box in _collect(data)) {
      switch (box.type) {
        case 'tenc':
          // v(1) flags(3) reserved(1) crypt/skip(1) isProtected(1) ivSize(1) kid(16)
          if (box.contentStart + 8 <= data.length) {
            final v = data[box.contentStart + 7];
            if (v == 8 || v == 16) ivSize = v;
          }
          break;
        case 'encv':
          _setType(data, box.start, 'avc1');
          break;
        case 'enca':
          _setType(data, box.start, 'mp4a');
          break;
        case 'sinf':
        case 'pssh':
          _setType(data, box.start, 'free');
          break;
      }
    }
    return data;
  }

  /// Decrypts [input] media segment in place and neutralises crypto boxes.
  Uint8List decryptSegment(Uint8List input) {
    final data = Uint8List.fromList(input);
    final boxes = _collect(data);

    List<int>? sampleSizes;
    List<_Sample>? senc;
    int mdatStart = -1;

    for (final box in boxes) {
      switch (box.type) {
        case 'trun':
          sampleSizes = _parseTrun(data, box.contentStart);
          break;
        case 'senc':
          senc = _parseSenc(data, box.contentStart);
          break;
        case 'mdat':
          mdatStart = box.contentStart;
          break;
      }
    }

    if (sampleSizes != null && senc != null && mdatStart >= 0) {
      _decryptMdat(data, mdatStart, sampleSizes, senc);
    }

    // Neutralise auxiliary crypto boxes (size-preserving).
    for (final box in boxes) {
      switch (box.type) {
        case 'senc':
        case 'saiz':
        case 'saio':
        case 'sbgp':
        case 'sgpd':
        case 'pssh':
          _setType(data, box.start, 'free');
          break;
      }
    }
    return data;
  }

  // ── decryption ─────────────────────────────────────────────────────────────

  void _decryptMdat(
      Uint8List data, int mdatStart, List<int> sizes, List<_Sample> senc) {
    var offset = mdatStart;
    final count = sizes.length < senc.length ? sizes.length : senc.length;
    for (var i = 0; i < count; i++) {
      final size = sizes[i];
      final sample = senc[i];
      final cipher = _ctrFor(sample.iv);
      var pos = offset;
      if (sample.subsamples.isEmpty) {
        // Whole-sample encryption (audio).
        _ctrInPlace(cipher, data, pos, size);
      } else {
        for (final ss in sample.subsamples) {
          pos += ss.clear; // clear bytes: skip, no keystream consumed
          if (ss.encrypted > 0) {
            _ctrInPlace(cipher, data, pos, ss.encrypted);
            pos += ss.encrypted;
          }
        }
      }
      offset += size;
    }
  }

  StreamCipher _ctrFor(Uint8List iv8) {
    // CENC AES-CTR: 16-byte counter = IV (left-aligned) padded with zeros.
    final iv16 = Uint8List(16);
    iv16.setRange(0, iv8.length > 16 ? 16 : iv8.length, iv8);
    return SICStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv16));
  }

  void _ctrInPlace(StreamCipher cipher, Uint8List data, int offset, int len) {
    // Continuous keystream across calls (subsamples of one sample).
    cipher.processBytes(data, offset, len, data, offset);
  }

  // ── parsing ────────────────────────────────────────────────────────────────

  /// trun: v(1) flags(3) sample_count(4) [data_offset(4)] [first_flags(4)]
  /// then per sample: [duration(4)] [size(4)] [flags(4)] [cto(4)] per flags bits.
  List<int> _parseTrun(Uint8List d, int c) {
    final flags = (d[c + 1] << 16) | (d[c + 2] << 8) | d[c + 3];
    final count = _u32(d, c + 4);
    var p = c + 8;
    if (flags & 0x000001 != 0) p += 4; // data_offset
    if (flags & 0x000004 != 0) p += 4; // first_sample_flags
    final hasDuration = flags & 0x000100 != 0;
    final hasSize = flags & 0x000200 != 0;
    final hasFlags = flags & 0x000400 != 0;
    final hasCto = flags & 0x000800 != 0;
    final sizes = <int>[];
    for (var i = 0; i < count; i++) {
      if (hasDuration) p += 4;
      if (hasSize) {
        sizes.add(_u32(d, p));
        p += 4;
      } else {
        sizes.add(0); // would need tfhd/trex default; not used by these streams
      }
      if (hasFlags) p += 4;
      if (hasCto) p += 4;
    }
    return sizes;
  }

  /// senc: v(1) flags(3) sample_count(4); per sample IV(ivSize)
  /// [+ subsample_count(2) + n×(clear(2), encrypted(4))] when flags&2.
  List<_Sample> _parseSenc(Uint8List d, int c) {
    final flags = (d[c + 1] << 16) | (d[c + 2] << 8) | d[c + 3];
    final hasSub = flags & 0x000002 != 0;
    final count = _u32(d, c + 4);
    var p = c + 8;
    final out = <_Sample>[];
    for (var i = 0; i < count; i++) {
      final iv = Uint8List.sublistView(d, p, p + ivSize);
      p += ivSize;
      final subs = <_Subsample>[];
      if (hasSub) {
        final n = (d[p] << 8) | d[p + 1];
        p += 2;
        for (var j = 0; j < n; j++) {
          final clear = (d[p] << 8) | d[p + 1];
          final enc = _u32(d, p + 2);
          subs.add(_Subsample(clear, enc));
          p += 6;
        }
      }
      out.add(_Sample(Uint8List.fromList(iv), subs));
    }
    return out;
  }

  // ── box walking ──────────────────────────────────────────────────────────

  /// Flat list of every box (recursing containers), for read-then-mutate passes.
  List<_Box> _collect(Uint8List d) {
    final out = <_Box>[];
    _walk(d, 0, d.length, out);
    return out;
  }

  static const _containers = {
    'moov', 'trak', 'mdia', 'minf', 'stbl', 'moof', 'traf', 'mvex', 'edts',
    'dinf', 'schi',
  };

  void _walk(Uint8List d, int start, int end, List<_Box> out) {
    var off = start;
    while (off + 8 <= end) {
      var size = _u32(d, off);
      final type = String.fromCharCodes(d, off + 4, off + 8);
      var header = 8;
      if (size == 1) {
        size = _u64(d, off + 8);
        header = 16;
      } else if (size == 0) {
        size = end - off;
      }
      if (size < header || off + size > end) break;
      out.add(_Box(type, off, off + header, off + size));

      if (_containers.contains(type)) {
        _walk(d, off + header, off + size, out);
      } else if (type == 'stsd') {
        _walk(d, off + header + 8, off + size, out);
      } else if (type == 'encv' || type == 'avc1' || type == 'hvc1' ||
          type == 'hev1') {
        _walk(d, off + header + 78, off + size, out); // VisualSampleEntry
      } else if (type == 'enca' || type == 'mp4a') {
        _walk(d, off + header + 28, off + size, out); // AudioSampleEntry
      } else if (type == 'sinf') {
        _walk(d, off + header, off + size, out);
      }
      off += size;
    }
  }

  void _setType(Uint8List d, int boxStart, String type) {
    d[boxStart + 4] = type.codeUnitAt(0);
    d[boxStart + 5] = type.codeUnitAt(1);
    d[boxStart + 6] = type.codeUnitAt(2);
    d[boxStart + 7] = type.codeUnitAt(3);
  }

  static int _u32(Uint8List d, int o) =>
      (d[o] << 24) | (d[o + 1] << 16) | (d[o + 2] << 8) | d[o + 3];

  static int _u64(Uint8List d, int o) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | d[o + i];
    }
    return v;
  }
}

class _Box {
  final String type;
  final int start;
  final int contentStart;
  final int end;
  _Box(this.type, this.start, this.contentStart, this.end);
}

class _Sample {
  final Uint8List iv;
  final List<_Subsample> subsamples;
  _Sample(this.iv, this.subsamples);
}

class _Subsample {
  final int clear;
  final int encrypted;
  _Subsample(this.clear, this.encrypted);
}
