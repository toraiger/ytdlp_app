import "diagnostic_values.dart";

/// Fixed outcomes and numeric edit information are safe for copied reports.
enum M4aHeaderOutcome {
  pending,
  normalized,
  notDash,
  notFragmented,
  notAudio,
  populatedSamples,
  unsupportedEditList,
  invalidHeader,
}

class M4aHeaderDiagnostics {
  const M4aHeaderDiagnostics({
    required this.outcome,
    this.hasEditList,
    this.editVersion,
    this.editEntryCount,
    this.editStart,
    this.editDuration,
  });

  static M4aHeaderDiagnostics? fromMap(Map<Object?, Object?> data) {
    M4aHeaderOutcome? outcome;
    for (final candidate in M4aHeaderOutcome.values) {
      if (data["m4aHeaderOutcome"] == candidate.name) outcome = candidate;
    }
    if (outcome == null) return null;
    final values = DiagnosticValues(data);
    return M4aHeaderDiagnostics(
      outcome: outcome,
      hasEditList: values.boolean("m4aHasEditList"),
      editVersion: values.nonNegative("m4aEditVersion"),
      editEntryCount: values.nonNegative("m4aEditEntryCount"),
      editStart: values.time("m4aEditStartUs"),
      editDuration: values.time("m4aEditDurationUs"),
    );
  }

  final M4aHeaderOutcome outcome;
  final bool? hasEditList;
  final int? editVersion;
  final int? editEntryCount;
  final Duration? editStart;
  final Duration? editDuration;

  Map<String, Object?> toMap() => {
    "m4aHeaderOutcome": outcome.name,
    "m4aHasEditList": hasEditList,
    "m4aEditVersion": editVersion,
    "m4aEditEntryCount": editEntryCount,
    "m4aEditStartUs": editStart?.inMicroseconds,
    "m4aEditDurationUs": editDuration?.inMicroseconds,
  };
}
