/// Shared typed reads keep optional diagnostics free of arbitrary strings.
class DiagnosticValues {
  const DiagnosticValues(this.data);
  final Map<Object?, Object?> data;

  int? nonNegative(String key) {
    final value = data[key];
    return ((value is int) && (value >= 0)) ? value : null;
  }

  Duration? time(String key) {
    final microseconds = nonNegative(key);
    return microseconds == null ? null : Duration(microseconds: microseconds);
  }

  bool? boolean(String key) {
    final value = data[key];
    return value is bool ? value : null;
  }
}
