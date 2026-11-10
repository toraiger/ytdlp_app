import "dart:typed_data";

import "../models/m4a_header_diagnostics.dart";

/// Reset only empty DASH initialization durations. Edit lists, sample tables,
/// fragment offsets and encoded audio stay byte-for-byte intact.
class M4aFragmentHeader {
  const M4aFragmentHeader(
    this.durationFields, {
    this.requiredLength,
    this.diagnostics = const M4aHeaderDiagnostics(
      outcome: M4aHeaderOutcome.pending,
    ),
  });

  static const maxLength =
      1024 * 1024; // One MiB bounds initialization buffering.
  final List<({int offset, int length})> durationFields;
  final int? requiredLength;
  final M4aHeaderDiagnostics diagnostics;

  static M4aFragmentHeader inspect(Uint8List bytes) =>
      _Inspection(bytes).inspect();

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

/// ISO BMFF layout constants shared by box and edit-list parsing.
abstract final class _Layout {
  static const word = 4;
  static const wideWord = 8;
  static const halfWord = 2;
  static const boxHeader = word * 2;
  static const fullHeader = word;
  static const version0 = 0;
  static const version1 = 1;
  static const versionShift = 24;
  static const flagMask = 0x00ffffff;
  static const normalRate = 1;
  static const singleEntry = 1;
}

class _Rejected implements Exception {
  const _Rejected(this.outcome);
  final M4aHeaderOutcome outcome;
}

class _Inspection {
  _Inspection(Uint8List bytes) : data = ByteData.sublistView(bytes);
  final ByteData data;
  bool? hasEditList;
  int? editVersion;
  int? editEntryCount;
  Duration? editStart;
  Duration? editDuration;

  M4aFragmentHeader result(
    M4aHeaderOutcome outcome, {
    List<({int offset, int length})> fields = const [],
    int? requiredLength,
  }) => M4aFragmentHeader(
    List.unmodifiable(fields),
    requiredLength: requiredLength,
    diagnostics: M4aHeaderDiagnostics(
      outcome: outcome,
      hasEditList: hasEditList,
      editVersion: editVersion,
      editEntryCount: editEntryCount,
      editStart: editStart,
      editDuration: editDuration,
    ),
  );

  M4aFragmentHeader inspect() {
    try {
      var dash = false;
      var offset = 0;
      while (offset + _Layout.boxHeader <= data.lengthInBytes) {
        final box = _Box.read(data, offset, data.lengthInBytes, partial: true);
        if (box.end > data.lengthInBytes) {
          final canReadMore =
              ((dash) &&
                  (box.type == "moov") &&
                  (box.end <= M4aFragmentHeader.maxLength));
          return canReadMore
              ? result(M4aHeaderOutcome.pending, requiredLength: box.end)
              : result(M4aHeaderOutcome.invalidHeader);
        }
        switch (box.type) {
          case "ftyp":
            box.requireBytes(box.body, _Layout.word * 2);
            dash = _text(data, box.body) == "dash";
          case "moov":
            if (!dash) return result(M4aHeaderOutcome.notDash);
            return inspectMovie(box);
          case "mdat" || "moof":
            return result(M4aHeaderOutcome.notFragmented);
        }
        offset = box.end;
      }
      return result(M4aHeaderOutcome.invalidHeader);
    } on _Rejected catch (rejection) {
      return result(rejection.outcome);
    } on Object {
      // Expose a fixed reason, never raw metadata or exception text.
      return result(M4aHeaderOutcome.invalidHeader);
    }
  }

  M4aFragmentHeader inspectMovie(_Box movie) {
    final children = movie.children(data);
    if (!children.any((child) => child.type == "mvex")) {
      return result(M4aHeaderOutcome.notFragmented);
    }
    final movieHeader = _single(children, "mvhd");
    final movieTimescale = movieHeader.timescale(data);
    final tracks = children.where((child) => child.type == "trak").toList();
    if (tracks.isEmpty) throw const FormatException();
    final fields = [movieHeader.durationField(data)];
    for (final track in tracks) {
      final parts = track.children(data);
      final trackHeader = _single(parts, "tkhd");
      final mediaParts = _single(parts, "mdia").children(data);
      final handler = _single(mediaParts, "hdlr");
      final handlerOffset = handler.body + _Layout.fullHeader + _Layout.word;
      handler.requireBytes(handlerOffset, _Layout.word);
      if (_text(data, handlerOffset) != "soun") {
        throw const _Rejected(M4aHeaderOutcome.notAudio);
      }
      final mediaHeader = _single(mediaParts, "mdhd");
      final mediaTimescale = mediaHeader.timescale(data);
      inspectEdits(parts, movieTimescale, mediaTimescale);
      inspectEmptyTables(mediaParts);
      fields.addAll([
        trackHeader.durationField(data),
        mediaHeader.durationField(data),
      ]);
    }
    hasEditList ??= false;
    // Publish changes only after every track and edit list passes validation.
    return result(M4aHeaderOutcome.normalized, fields: fields);
  }

  void inspectEmptyTables(List<_Box> mediaParts) {
    final tables = _single(
      _single(mediaParts, "minf").children(data),
      "stbl",
    ).children(data);
    for (final name in ["stts", "stsc", "stsz"]) {
      final table = _single(tables, name);
      final fixedSampleSizeBytes = name == "stsz" ? _Layout.word : 0;
      final countOffset =
          table.body + _Layout.fullHeader + fixedSampleSizeBytes;
      table.requireBytes(countOffset, _Layout.word);
      if (data.getUint32(countOffset) != 0) {
        throw const _Rejected(M4aHeaderOutcome.populatedSamples);
      }
    }
    final offsets =
        tables
            .where(
              (table) => ((table.type == "stco") || (table.type == "co64")),
            )
            .toList();
    if (offsets.length != _Layout.singleEntry) throw const FormatException();
    final table = offsets.single;
    final countOffset = table.body + _Layout.fullHeader;
    table.requireBytes(countOffset, _Layout.word);
    if (data.getUint32(countOffset) != 0) {
      throw const _Rejected(M4aHeaderOutcome.populatedSamples);
    }
  }

  void inspectEdits(
    List<_Box> trackParts,
    int movieTimescale,
    int mediaTimescale,
  ) {
    final editBoxes = trackParts.where((part) => part.type == "edts").toList();
    if (editBoxes.isEmpty) return;
    // Independently edited tracks need a general timeline remux.
    final previouslyEdited = hasEditList == true;
    hasEditList = true;
    if ((previouslyEdited) || (editBoxes.length != _Layout.singleEntry)) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    final editLists = editBoxes.single.children(data);
    if ((editLists.length != _Layout.singleEntry) ||
        (editLists.single.type != "elst")) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    final editList = editLists.single;
    editList.requireBytes(editList.body, _Layout.fullHeader + _Layout.word);
    final versionFlags = data.getUint32(editList.body);
    final version = versionFlags >> _Layout.versionShift;
    editVersion = version;
    editEntryCount = data.getUint32(editList.body + _Layout.fullHeader);
    if ((versionFlags & _Layout.flagMask) != 0) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    if (editEntryCount != _Layout.singleEntry) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    final wide = version == _Layout.version1;
    if ((!wide) && (version != _Layout.version0)) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    final timeWidth = wide ? _Layout.wideWord : _Layout.word;
    final entryOffset = editList.body + _Layout.fullHeader + _Layout.word;
    final rateOffset = entryOffset + timeWidth * 2;
    final expectedEnd = rateOffset + _Layout.halfWord * 2;
    if (expectedEnd != editList.end) throw const FormatException();
    final segmentTicks =
        wide ? data.getUint64(entryOffset) : data.getUint32(entryOffset);
    final startOffset = entryOffset + timeWidth;
    final startTicks =
        wide ? data.getInt64(startOffset) : data.getInt32(startOffset);
    if ((segmentTicks <= 0) || (startTicks < 0)) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    final rateInteger = data.getInt16(rateOffset);
    final rateFraction = data.getInt16(rateOffset + _Layout.halfWord);
    if ((rateInteger != _Layout.normalRate) || (rateFraction != 0)) {
      throw const _Rejected(M4aHeaderOutcome.unsupportedEditList);
    }
    // elst duration uses the movie clock; media_time uses the track clock.
    editStart = _time(startTicks, mediaTimescale);
    editDuration = _time(segmentTicks, movieTimescale);
  }
}

Duration _time(int ticks, int timescale) {
  final microseconds =
      BigInt.from(ticks) *
      BigInt.from(Duration.microsecondsPerSecond) ~/
      BigInt.from(timescale);
  if (!microseconds.isValidInt) throw const FormatException();
  return Duration(microseconds: microseconds.toInt());
}

_Box _single(List<_Box> boxes, String type) {
  final matches = boxes.where((box) => box.type == type).toList();
  if (matches.length != _Layout.singleEntry) throw const FormatException();
  return matches.single;
}

String _text(ByteData data, int offset) => String.fromCharCodes([
  for (var byteIndex = 0; byteIndex < _Layout.word; byteIndex++)
    data.getUint8(offset + byteIndex),
]);

class _Box {
  const _Box(this.type, this.body, this.end);
  final String type;
  final int body;
  final int end;

  static _Box read(ByteData data, int offset, int end, {bool partial = false}) {
    if (offset + _Layout.boxHeader > end) throw const FormatException();
    var size = data.getUint32(offset);
    var header = _Layout.boxHeader;
    if (size == 1) {
      // Extended 64-bit box size.
      if (offset + header + _Layout.wideWord > end) {
        throw const FormatException();
      }
      size = data.getUint64(offset + header);
      header += _Layout.wideWord;
    } else if (size == 0) {
      // Final box extends to the supplied boundary.
      size = end - offset;
    }
    if ((size < header) || ((!partial) && (offset + size > end))) {
      throw const FormatException();
    }
    return _Box(
      _text(data, offset + _Layout.word),
      offset + header,
      offset + size,
    );
  }

  void requireBytes(int offset, int length) {
    if ((offset < body) || (offset + length > end)) {
      throw const FormatException();
    }
  }

  List<_Box> children(ByteData data) {
    final result = <_Box>[];
    var offset = body;
    while (offset < end) {
      final child = read(data, offset, end);
      result.add(child);
      offset = child.end;
    }
    return result;
  }

  int timestampWidth(ByteData data) {
    requireBytes(body, _Layout.fullHeader);
    final version = data.getUint8(body);
    if (version == _Layout.version0) return _Layout.word;
    if (version == _Layout.version1) return _Layout.wideWord;
    throw const FormatException();
  }

  int timescale(ByteData data) {
    final timescaleOffset =
        body + _Layout.fullHeader + timestampWidth(data) * 2;
    requireBytes(timescaleOffset, _Layout.word);
    final value = data.getUint32(timescaleOffset);
    if (value == 0) throw const FormatException();
    return value;
  }

  ({int offset, int length}) durationField(ByteData data) {
    final width = timestampWidth(data);
    final precedingWords = type == "tkhd" ? 2 : 1;
    final offset =
        body + _Layout.fullHeader + width * 2 + precedingWords * _Layout.word;
    requireBytes(offset, width);
    return (offset: offset, length: width);
  }
}
