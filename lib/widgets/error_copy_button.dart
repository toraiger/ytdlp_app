import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../services/error_report.dart";

class ErrorCopyButton extends StatelessWidget {
  const ErrorCopyButton({super.key, required this.report});

  final ErrorReport report;

  Future<void> _copy(BuildContext context) async {
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: report.toText()));
      message = "エラー詳細をコピーしました。";
    } catch (failure) {
      message = "エラー詳細をコピーできませんでした。もう一度お試しください。";
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: "エラー詳細をコピー",
    onPressed: () => _copy(context),
    icon: const Icon(Icons.copy_rounded),
  );
}
