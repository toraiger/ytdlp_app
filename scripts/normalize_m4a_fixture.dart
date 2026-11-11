import 'dart:io';
import 'package:mix_player_app/services/m4a_fragment_header.dart';

void main(List<String> args) {
  if (args.length != 2) throw ArgumentError('Expected input and output paths');
  final bytes = File(args[0]).readAsBytesSync();
  final header = M4aFragmentHeader.inspect(bytes);
  if (header.durationFields.length != 3 || header.requiredLength != null) {
    throw StateError('Expected three empty audio initialization durations');
  }
  File(args[1]).writeAsBytesSync(header.apply(bytes, 0));
  stdout.writeln('Normalized ${header.durationFields.length} duration fields');
}
