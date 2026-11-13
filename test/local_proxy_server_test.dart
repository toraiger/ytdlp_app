import "dart:async";
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:just_audio/src/local_proxy_server.dart";

void main() {
  Future<void> respond(HttpRequest request) async {
    request.response.write("audio-test");
    await request.response.close();
  }

  Future<String> read(LocalProxyServer server) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.http("localhost:${server.port}", "/test"),
      );
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      return await response.transform(SystemEncoding().decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  test("Concurrent users await one completed bind", () async {
    final bound = Completer<HttpServer>();
    var binds = 0;
    final listener = LocalProxyServer(
      bind: () {
        binds++;
        return bound.future;
      },
    );
    addTearDown(listener.stop);
    final first = listener.ensureRunning(respond);
    final second = listener.ensureRunning(respond);
    var ready = false;
    final observed = second.then((ignoredValue) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    expect(listener.snapshot.listening, isFalse);
    bound.complete(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    await Future.wait([first, second, observed]);
    expect(binds, 1);
    expect(await read(listener), "audio-test");
    expect(listener.snapshot.requestCount, 1);
  });

  test(
    "A failed bind does not leave a running flag or failed future",
    () async {
      var attempts = 0;
      final listener = LocalProxyServer(
        bind: () {
          attempts++;
          if (attempts == 1) throw const SocketException("Bind failed");
          return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        },
      );
      addTearDown(listener.stop);
      await expectLater(
        listener.ensureRunning(respond),
        throwsA(isA<SocketException>()),
      );
      expect(listener.snapshot.listening, isFalse);
      await listener.ensureRunning(respond);
      expect(attempts, 2);
      expect(await read(listener), "audio-test");
    },
  );

  test("Stop during bind completes before a replacement starts", () async {
    final pending = Completer<HttpServer>();
    var binds = 0;
    final listener = LocalProxyServer(
      bind: () {
        binds++;
        return binds == 1
            ? pending.future
            : HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      },
    );
    addTearDown(listener.stop);
    final starting = listener.ensureRunning(respond);
    final stopping = listener.stop();
    final restarting = listener.ensureRunning(respond);
    pending.complete(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    await Future.wait([starting, stopping, restarting]);
    expect(listener.snapshot.generation, 2);
    expect(await read(listener), "audio-test");
    expect(listener.snapshot.requestCount, 1);
  });

  test(
    "Closed listener can restart and old completion cannot stop it",
    () async {
      final listeners = <HttpServer>[];
      final listener = LocalProxyServer(
        bind: () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          listeners.add(server);
          return server;
        },
      );
      addTearDown(listener.stop);
      await listener.ensureRunning(respond);
      await listeners.first.close(force: true);
      await Future<void>.delayed(Duration.zero);
      await listener.ensureRunning(respond);
      expect(listener.snapshot.generation, 2);
      expect(await read(listener), "audio-test");
      await listener.stop();
      await listener.stop();
      await listener.ensureRunning(respond);
      expect(listener.snapshot.generation, 3);
      expect(await read(listener), "audio-test");
    },
  );
  test(
    "A handler failure after sending headers still closes its response",
    () async {
      final listener = LocalProxyServer();
      addTearDown(listener.stop);
      await listener.ensureRunning((request) async {
        request.response.write("partial");
        await request.response.flush();
        throw StateError("Private source failure");
      });
      const completionLimit = Duration(seconds: 2);
      expect(await read(listener).timeout(completionLimit), "partial");
    },
  );
}
