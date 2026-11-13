import "dart:typed_data";

/// Synthetic fixtures use default-base-is-moof and relative sidx offsets, so
/// growing moov does not require rewriting fragment addresses.
Uint8List withEditList(
  Uint8List original, {
  int version = 0,
  int mediaStart = 1600,
  int? segmentDuration,
  int? movieTimescale,
  int entryCount = 1,
  int rateInteger = 1,
  int rateFraction = 0,
}) {
  const word = 4;
  const halfWord = 2;
  const fullHeader = word;
  const boxHeader = word * 2;

  Uint8List box(String type, List<int> payload) {
    final result = Uint8List(boxHeader + payload.length);
    ByteData.sublistView(result).setUint32(0, result.length);
    result.setRange(word, boxHeader, type.codeUnits);
    result.setRange(boxHeader, result.length, payload);
    return result;
  }

  List<({String type, Uint8List payload})> children(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final result = <({String type, Uint8List payload})>[];
    var offset = 0;
    while (offset < bytes.length) {
      final size = data.getUint32(offset);
      if ((size < boxHeader) || (offset + size > bytes.length)) {
        throw StateError("Invalid generated fixture box");
      }
      result.add((
        type: String.fromCharCodes(
          bytes.sublist(offset + word, offset + boxHeader),
        ),
        payload: bytes.sublist(offset + boxHeader, offset + size),
      ));
      offset += size;
    }
    return result;
  }

  final topBoxes = children(original);
  final movieParts = children(
    topBoxes.singleWhere((part) => part.type == "moov").payload,
  );
  final movieHeader =
      movieParts.singleWhere((part) => part.type == "mvhd").payload;
  final originalScale = ByteData.sublistView(
    movieHeader,
  ).getUint32(fullHeader + word * 2);
  final originalDuration = ByteData.sublistView(
    movieHeader,
  ).getUint32(fullHeader + word * 3);
  final targetScale = movieTimescale ?? originalScale;
  final targetDuration = originalDuration * targetScale ~/ originalScale;
  final timeWidth = version == 1 ? word * 2 : word;
  final entryWidth = timeWidth * 2 + halfWord * 2;
  final editPayload = Uint8List(fullHeader + word + entryWidth * entryCount);
  final editData = ByteData.sublistView(editPayload);
  editData.setUint8(0, version);
  editData.setUint32(fullHeader, entryCount);
  for (var entryIndex = 0; entryIndex < entryCount; entryIndex++) {
    final entryOffset = fullHeader + word + entryWidth * entryIndex;
    final duration = segmentDuration ?? targetDuration;
    if (version == 1) {
      editData.setUint64(entryOffset, duration);
      editData.setInt64(entryOffset + timeWidth, mediaStart);
    } else {
      editData.setUint32(entryOffset, duration);
      editData.setInt32(entryOffset + timeWidth, mediaStart);
    }
    editData.setInt16(entryOffset + timeWidth * 2, rateInteger);
    editData.setInt16(entryOffset + timeWidth * 2 + halfWord, rateFraction);
  }
  final editBox = box("edts", box("elst", editPayload));
  final rebuiltMovie = BytesBuilder(copy: false);
  for (final part in movieParts) {
    if (part.type == "mvhd") {
      final payload = Uint8List.fromList(part.payload);
      final data = ByteData.sublistView(payload);
      data.setUint32(fullHeader + word * 2, targetScale);
      data.setUint32(fullHeader + word * 3, targetDuration);
      rebuiltMovie.add(box(part.type, payload));
    } else if (part.type == "trak") {
      final rebuiltTrack = BytesBuilder(copy: false);
      for (final trackPart in children(part.payload)) {
        final payload = Uint8List.fromList(trackPart.payload);
        if (trackPart.type == "tkhd") {
          ByteData.sublistView(
            payload,
          ).setUint32(fullHeader + word * 4, targetDuration);
        }
        rebuiltTrack.add(box(trackPart.type, payload));
        if (trackPart.type == "tkhd") rebuiltTrack.add(editBox);
      }
      rebuiltMovie.add(box(part.type, rebuiltTrack.takeBytes()));
    } else {
      rebuiltMovie.add(box(part.type, part.payload));
    }
  }
  final rebuilt = BytesBuilder(copy: false);
  for (final part in topBoxes) {
    final payload =
        part.type == "moov" ? rebuiltMovie.takeBytes() : part.payload;
    rebuilt.add(box(part.type, payload));
  }
  return rebuilt.takeBytes();
}
