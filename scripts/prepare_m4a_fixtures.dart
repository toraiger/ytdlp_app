import "dart:convert";
import "dart:io";

import "package:mix_player_app/services/m4a_fragment_header.dart";
import "../test/support/m4a_fixture.dart";

void main(List<String> arguments) {
  const expectedArguments = 2;
  const durationToleranceSeconds =
      0.1; // AAC priming and native timestamp rounding.
  const expectedDurationSeconds =
      6.023220; // The checked-in six-second AAC tone.
  if (arguments.length != expectedArguments) {
    throw ArgumentError("Expected fixture and directory");
  }
  final original = File(arguments.first).readAsBytesSync();
  final directory = Directory(arguments.last)..createSync(recursive: true);
  final variants = {
    "plain": original,
    "edit-zero": withEditList(original, mediaStart: 0),
    "edit-v0": withEditList(original),
    "edit-v1": withEditList(original, version: 1),
    "edit-clock": withEditList(original, movieTimescale: 44100),
  };
  final manifest = <Map<String, Object>>[];
  for (final variant in variants.entries) {
    final inspected = M4aFragmentHeader.inspect(variant.value);
    if (inspected.durationFields.length != 3) {
      throw StateError("Fixture was not normalized");
    }
    final originalName = "${variant.key}-original.m4a";
    final normalizedName = "${variant.key}-normalized.m4a";
    File("${directory.path}/$originalName").writeAsBytesSync(variant.value);
    File(
      "${directory.path}/$normalizedName",
    ).writeAsBytesSync(inspected.apply(variant.value, 0));
    manifest.add({
      "name": variant.key,
      "original": originalName,
      "normalized": normalizedName,
      "expectedSeconds": expectedDurationSeconds,
      "toleranceSeconds": durationToleranceSeconds,
    });
  }
  File(
    "${directory.path}/manifest.json",
  ).writeAsStringSync(jsonEncode(manifest));
  stdout.writeln("Prepared ${manifest.length} M4A native timing cases");
}
