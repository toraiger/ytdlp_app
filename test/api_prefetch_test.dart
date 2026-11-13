import "dart:async";

import "package:fake_async/fake_async.dart";
import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;
import "package:http/testing.dart";
import "package:mix_player_app/models/api_models.dart";
import "package:mix_player_app/services/api_client.dart";
import "package:mix_player_app/services/request_scope.dart";

import "support/fakes.dart";

class _StalledClient extends http.BaseClient {
  final requests = <http.AbortableRequest>[];
  int aborted = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final abortable = request as http.AbortableRequest;
    requests.add(abortable);
    unawaited(abortable.abortTrigger!.then((_) => aborted++));
    return Completer<http.StreamedResponse>().future;
  }
}

void main() {
  test(
    "Cancelling prefetch aborts promptly and leaves no stale diagnostics",
    () async {
      final client = _StalledClient();
      final api = ApiClient(
        serverUrl: "https://api.example.test",
        apiKey: "secret",
        client: client,
      );
      final scope = RequestScope(1);
      final pending = api.resolveStream("a", scope: scope);
      final cancellation = expectLater(
        pending,
        throwsA(isA<RequestCancelled>()),
      );
      scope.cancel();
      await cancellation;
      await drain();
      expect(client.aborted, 1);
      expect(api.lastTiming.value, isNull);
      api.close();
    },
  );

  test(
    "Concurrent requests are shared within a scope and separated across path generations",
    () async {
      final responses = <Completer<http.Response>>[];
      final api = ApiClient(
        serverUrl: "https://api.example.test",
        apiKey: "secret",
        client: MockClient((request) {
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        }),
      );
      addTearDown(api.close);
      final oldScope = RequestScope(1);
      final old = api.resolveStream("a", scope: oldScope);
      final oldCancelled = expectLater(old, throwsA(isA<RequestCancelled>()));
      expect(identical(old, api.resolveStream("a", scope: oldScope)), isTrue);
      await drain();
      oldScope.cancel();
      final fresh = api.resolveStream(
        "a",
        scope: RequestScope(2),
        refresh: true,
      );
      await drain();
      expect(responses, hasLength(2));
      final result = streamJson("a");
      (result["audio"] as Map)["url"] = "https://media.example.test/fresh";
      responses.last.complete(jsonResponse(result));
      await fresh;
      await oldCancelled;
      responses.first.complete(jsonResponse(streamJson("a")));
      await drain();
      expect(api.cachedMedia("a", PlaybackMode.audio)!.url!.path, "/fresh");
    },
  );

  test(
    "A late normal response cannot overwrite a newer prefetch cache entry",
    () async {
      final responses = <Completer<http.Response>>[];
      final api = ApiClient(
        serverUrl: "https://api.example.test",
        apiKey: "secret",
        client: MockClient((request) {
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        }),
      );
      addTearDown(api.close);
      final normal = api.resolveStream("a");
      final fresh = api.resolveStream(
        "a",
        scope: RequestScope(2),
        refresh: true,
      );
      await drain();
      final result = streamJson("a");
      (result["audio"] as Map)["url"] = "https://media.example.test/fresh";
      responses.last.complete(jsonResponse(result));
      await fresh;
      responses.first.complete(jsonResponse(streamJson("a")));
      await normal;
      expect(api.cachedMedia("a", PlaybackMode.audio)!.url!.path, "/fresh");
    },
  );

  test(
    "Prefetch times out and aborts at 20 seconds; normal requests retain 90 seconds",
    () {
      fakeAsync((clock) {
        final client = _StalledClient();
        final api = ApiClient(
          serverUrl: "https://api.example.test",
          apiKey: "secret",
          client: client,
        );
        Object? prefetchFailure;
        Object? normalFailure;
        unawaited(
          api
              .resolveStream("a", scope: RequestScope(1))
              .then<void>(
                (_) {},
                onError: (Object failure) => prefetchFailure = failure,
              ),
        );
        unawaited(
          api
              .resolveStream("b")
              .then<void>(
                (_) {},
                onError: (Object failure) => normalFailure = failure,
              ),
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 19));
        expect(prefetchFailure, isNull);
        clock.elapse(const Duration(seconds: 1));
        expect(
          prefetchFailure,
          isA<ApiFailure>().having(
            (failure) => failure.retryable,
            "retryable",
            isTrue,
          ),
        );
        expect(normalFailure, isNull);
        expect(client.aborted, 1);
        clock.elapse(const Duration(seconds: 70));
        expect(normalFailure, isA<ApiFailure>());
        expect(client.aborted, 2);
        api.close();
      });
    },
  );
}
