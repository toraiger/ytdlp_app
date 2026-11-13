import "package:flutter/services.dart";
import "package:flutter_test/flutter_test.dart";
import "package:just_audio/just_audio.dart";
import "package:mix_player_app/services/api_client.dart";
import "package:mix_player_app/services/error_report.dart";

void main() {
  test("Native audio codes survive without copying exception messages", () {
    final failure = PlayerException(
      -1009,
      "https://private.example/media?token=secret Cookie=private-cookie",
      1,
    );
    final report =
        ErrorReport.capture(
          operation: "音声の読み込み",
          message: "音声を再生できません。",
          failure: failure,
          refreshed: true,
        ).toText();

    expect(report, contains("例外の種類: PlayerException"));
    expect(report, contains("ネイティブエラーコード: -1009"));
    expect(report, contains("エラー音源の番号: 2"));
    expect(report, contains("URL再取得後: はい"));
    expect(report, isNot(contains("secret")));
    expect(report, isNot(contains("private")));
    expect(report, isNot(contains("https://")));
  });

  test("Video errors extract numeric codes without platform details", () {
    final failure = PlatformException(
      code: "VideoError",
      message:
          "Error Domain=AVFoundationErrorDomain Code=-11800 private-message",
      details: {"Authorization": "private-token"},
    );
    final report =
        ErrorReport.capture(
          operation: "動画の再生",
          message: "動画を再生できません。",
          failure: failure,
        ).toText();

    expect(report, contains("ネイティブエラーコード: -11800"));
    expect(report, isNot(contains("private")));
    expect(report, isNot(contains("Authorization")));
  });

  test("API errors copy HTTP status without arbitrary exception text", () {
    final report =
        ErrorReport.capture(
          operation: "Mix取得",
          message: "API エラー。",
          failure: const ApiFailure("private-response-body", statusCode: 503),
        ).toText();

    expect(report, contains("HTTPステータス: 503"));
    expect(report, isNot(contains("private-response-body")));
  });

  test("Unexpected errors retain their type without serializing contents", () {
    final report =
        ErrorReport.capture(
          operation: "再生準備",
          message: "メディアを再生できません。",
          failure: StateError("X-API-Key=private-key Cookie=private-cookie"),
        ).toText();

    expect(report, contains("例外の種類: StateError"));
    expect(report, isNot(contains("private")));
  });
}
