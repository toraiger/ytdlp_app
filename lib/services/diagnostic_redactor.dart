/// Redact before retaining diagnostics, rather than only when copying them.
class DiagnosticRedactor {
  DiagnosticRedactor({Iterable<String> secrets = const []})
    : _secrets =
          (secrets.where((value) => value.isNotEmpty).toSet().toList()
            ..sort((a, b) => b.length.compareTo(a.length)));

  final List<String> _secrets;

  String _redact(String input) {
    var text = input
        .replaceAll(r'\/', '/')
        .replaceAll(r'\"', '"')
        .replaceAll(r"\'", "'");
    text = text.replaceAllMapped(
      RegExp(
        r'''(["']?(?:authorization|proxy-authorization|x-api-key|cookie|set-cookie)["']?\s*[:=]\s*)[^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}[REDACTED]',
    );
    text = text.replaceAll(
      RegExp(
        r'''(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>"']+''',
        caseSensitive: false,
      ),
      '[URL]',
    );
    text = text.replaceAllMapped(
      RegExp(
        r'''(^|[^a-z0-9_])(?:[a-z]:[\\/]|/)[^\s<>"']+''',
        caseSensitive: false,
        multiLine: true,
      ),
      (match) => '${match[1]}[PATH]',
    );
    for (final secret in _secrets) {
      text = text.replaceAll(secret, '[REDACTED]');
      text = text.replaceAll(Uri.encodeComponent(secret), '[REDACTED]');
    }
    return text.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), '');
  }

  String message(String input) => _limit(_redact(input), 2000);

  String stack(StackTrace stack) {
    final lines = _redact(stack.toString()).split('\n');
    return _limit(
      [...lines.take(20), if (lines.length > 20) '[以降省略]'].join('\n'),
      8000,
    );
  }

  String _limit(String input, int limit) {
    if (input.length <= limit) return input;
    const suffix = '[以降省略]';
    var end = limit - suffix.length;
    // Do not split a UTF-16 surrogate pair at the clipboard boundary.
    final last = input.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    return '${input.substring(0, end)}$suffix';
  }
}
