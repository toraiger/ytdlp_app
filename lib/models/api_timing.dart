enum ApiOperation {
  mix('Mix取得'),
  stream('再生URL取得'),
  extend('曲の追加取得');

  const ApiOperation(this.label);
  final String label;
}

class ApiTiming {
  const ApiTiming({
    required this.operation,
    required this.total,
    required this.succeeded,
    this.toHeaders,
    this.statusCode,
  });

  final ApiOperation operation;
  final Duration total;
  final bool succeeded;
  final Duration? toHeaders;
  final int? statusCode;

  String get statusLabel =>
      statusCode == null
          ? '通信失敗'
          : succeeded
          ? 'HTTP $statusCode'
          : '失敗・HTTP $statusCode';
}
