import 'dart:typed_data';

/// Empty DASH initialization tables must not also declare populated media time.
/// AVFoundation can add that time to the following fragments a second time.
/// This repair only clears duration fields; no offsets or media bytes move.
class M4aFragmentHeader {
  const M4aFragmentHeader(this.durationFields, {this.requiredLength});

  final List<({int offset, int length})> durationFields;
  final int? requiredLength;
  static const maxLength = 1024 * 1024;

  static M4aFragmentHeader inspect(Uint8List bytes) {
    const unchanged = M4aFragmentHeader([]);
    final data = ByteData.sublistView(bytes);
    try {
      var dash = false;
      for (var at = 0; at + 8 <= bytes.length;) {
        final box = _Box.read(data, at, bytes.length, partial: true);
        if (box.end > bytes.length) {
          return dash && box.type == 'moov' && box.end <= maxLength
              ? M4aFragmentHeader([], requiredLength: box.end)
              : unchanged;
        }
        if (box.type == 'ftyp') {
          dash = box.end >= box.body + 8 && _text(data, box.body) == 'dash';
        } else if (box.type == 'moov') {
          if (!dash) return unchanged;
          final children = box.children(data);
          if (!children.any((b) => b.type == 'mvex')) return unchanged;
          final movie = children.singleWhere((b) => b.type == 'mvhd');
          final tracks = children.where((b) => b.type == 'trak').toList();
          if (tracks.isEmpty) return unchanged;
          final fields = [movie.durationField(data)];
          for (final track in tracks) {
            final parts = track.children(data);
            // Edit lists or populated initialization samples need a full remux.
            if (parts.any((b) => b.type == 'edts')) return unchanged;
            final header = parts.singleWhere((b) => b.type == 'tkhd');
            final media = parts.singleWhere((b) => b.type == 'mdia');
            final mediaParts = media.children(data);
            final handler = mediaParts.singleWhere((b) => b.type == 'hdlr');
            if (handler.end < handler.body + 12 ||
                _text(data, handler.body + 8) != 'soun') {
              return unchanged;
            }
            final mediaHeader = mediaParts.singleWhere((b) => b.type == 'mdhd');
            final tables = mediaParts
                .singleWhere((b) => b.type == 'minf')
                .children(data)
                .singleWhere((b) => b.type == 'stbl')
                .children(data);
            for (final name in ['stts', 'stsc', 'stsz']) {
              final table = tables.singleWhere((b) => b.type == name);
              final countAt = table.body + (name == 'stsz' ? 8 : 4);
              if (countAt + 4 > table.end || data.getUint32(countAt) != 0) {
                return unchanged;
              }
            }
            final offsets = tables.singleWhere(
              (b) => b.type == 'stco' || b.type == 'co64',
            );
            if (offsets.body + 8 > offsets.end ||
                data.getUint32(offsets.body + 4) != 0) {
              return unchanged;
            }
            fields.addAll([
              header.durationField(data),
              mediaHeader.durationField(data),
            ]);
          }
          return M4aFragmentHeader(List.unmodifiable(fields));
        } else if (box.type == 'mdat' || box.type == 'moof') {
          return unchanged;
        }
        at = box.end;
      }
    } on Object {
      // Unrecognized or malformed input passes through without guessing.
    }
    return unchanged;
  }

  Uint8List apply(List<int> chunk, int offset) {
    final output = Uint8List.fromList(chunk);
    for (final field in durationFields) {
      final start = (field.offset - offset).clamp(0, output.length);
      final end = (field.offset + field.length - offset).clamp(
        0,
        output.length,
      );
      output.fillRange(start, end, 0);
    }
    return output;
  }
}

String _text(ByteData data, int at) =>
    String.fromCharCodes([for (var i = 0; i < 4; i++) data.getUint8(at + i)]);

class _Box {
  const _Box(this.type, this.body, this.end);
  final String type;
  final int body;
  final int end;

  static _Box read(ByteData data, int at, int end, {bool partial = false}) {
    if (at + 8 > end) throw const FormatException();
    var size = data.getUint32(at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > end) throw const FormatException();
      size = data.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = end - at;
    }
    if (size < header || (!partial && at + size > end)) {
      throw const FormatException();
    }
    return _Box(_text(data, at + 4), at + header, at + size);
  }

  List<_Box> children(ByteData data) {
    final result = <_Box>[];
    var at = body;
    while (at < end) {
      final box = read(data, at, end);
      result.add(box);
      at = box.end;
    }
    return result;
  }

  ({int offset, int length}) durationField(ByteData data) {
    if (body + 4 > end) throw const FormatException();
    final version = data.getUint8(body);
    if (version > 1) throw const FormatException();
    final offset =
        body +
        (type == 'tkhd' ? (version == 1 ? 28 : 20) : (version == 1 ? 24 : 16));
    final length = version == 1 ? 8 : 4;
    if (offset + length > end) throw const FormatException();
    return (offset: offset, length: length);
  }
}
