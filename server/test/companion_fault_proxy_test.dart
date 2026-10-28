import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../tool/companion_fault_proxy.dart';
import '../tool/prepare_companion_journey.dart';
import 'support/sharing_fixtures.dart';
import 'support/chat_fixtures.dart';
import 'support/media_fixtures.dart';

void main() {
  late Directory temporary;
  late String journey;
  late String directory;
  late HttpServer upstream;
  late CompanionFaultProxy proxy;
  late HttpClient client;
  late String token;
  late String body;
  late List<String?> authorizations;
  late List<String> bodies;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('companion-fault-test-');
    journey = '${temporary.path}/journey';
    await prepareJourney(journey, 'synthetic-fault-test');
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final config = File('$journey/client-a.json');
    final values = jsonDecode(await config.readAsString()) as Map;
    token = values['COMPANION_JOURNEY_TOKEN'] as String;
    values['COMPANION_JOURNEY_URL'] = 'http://127.0.0.1:${upstream.port}';
    await config.writeAsString(jsonEncode(values));
    final prepared = await prepareFaultProxy(journey);
    directory = prepared['directory'] as String;
    authorizations = [];
    bodies = [];
    upstream.listen((request) async {
      authorizations.add(request.headers.value('authorization'));
      bodies.add(await utf8.decoder.bind(request).join());
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"result":"synthetic-accepted"}');
      await request.response.close();
    });
    proxy = await CompanionFaultProxy.open(directory);
    client = HttpClient();
    body = jsonEncode(
      publishRecord(
        sharingId(),
        sharingId(),
        DateTime.now().toUtc(),
        text: 'SYNTHETIC private text never logged',
      ).toJson(),
    );
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await upstream.close(force: true);
    await temporary.delete(recursive: true);
  });

  Future<(int, String)> send({
    String path = '/v1/companion/records/publish',
    String? actor,
    String? payload,
  }) async {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${proxy.server.port}$path'),
    );
    request.headers.set('authorization', 'Bearer ${actor ?? token}');
    request.headers.contentType = ContentType.json;
    request.write(payload ?? body);
    final response = await request.close();
    return (response.statusCode, await utf8.decoder.bind(response).join());
  }

  Future<File> held() async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 5)) {
      final matches = await Directory(directory)
          .list()
          .where(
            (file) =>
                file.path.contains('/held-') && file.path.endsWith('.json'),
          )
          .toList();
      if (matches.length == 1) return File(matches.single.path);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('No held backend response');
  }

  Future<String> waitingRace() async {
    final control =
        jsonDecode(await File('$directory/control.json').readAsString()) as Map;
    final id = control['id'] as String;
    final waiting = File('$directory/waiting-$id-0.json');
    final watch = Stopwatch()..start();
    while (!await waiting.exists()) {
      if (watch.elapsed > const Duration(seconds: 5)) {
        fail('Missing first race arrival');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return id;
  }

  for (final kind in ['send', 'leave', 'send-leave']) {
    test(
      '$kind barrier requires two different actors and records actual overlap',
      () async {
        final leave = pairingCommandRoutes.entries
            .singleWhere((e) => e.value == PairingCommandKind.leave)
            .key;
        final routes = kind == 'send'
            ? [
                chatCommandRoutes.keys.firstWhere((p) => p.endsWith('/send')),
                '/v1/companion/chat/send',
              ]
            : kind == 'leave'
            ? [leave, leave]
            : ['/v1/companion/chat/send', leave];
        final group = sharingId();
        final payloads = [
          for (final route in routes)
            jsonEncode(
              route == leave
                  ? PairingCommand.leave(sharingId(), group).toJson()
                  : chatSend(group, text: 'SYNTHETIC private race').toJson(),
            ),
        ];
        final peer =
            (jsonDecode(await File('$journey/client-b.json').readAsString())
                    as Map)['COMPANION_JOURNEY_TOKEN']
                as String;
        await setRace(directory, kind);
        final first = send(path: routes.first, payload: payloads.first);
        final id = await waitingRace();
        expect(bodies, isEmpty);
        expect(
          (await send(path: routes.first, payload: payloads.first)).$1,
          503,
        );
        expect(bodies, isEmpty);
        final second = send(
          path: routes.last,
          payload: payloads.last,
          actor: peer,
        );
        expect((await first).$1, 200);
        expect((await second).$1, 200);
        expect(bodies.toSet(), payloads.toSet());
        final release = jsonDecode(
          await File('$directory/released-$id.json').readAsString(),
        ) as Map;
        expect(release['distinct_actors'], 2);
        final requests = (release['requests'] as List).cast<Map>();
        expect(
          requests.map((e) => e['body_hash']).toSet(),
          payloads
              .map((p) => sha256.convert(utf8.encode(p)).toString())
              .toSet(),
        );
        final log = await File('$directory/events.jsonl').readAsString();
        for (final value in [token, peer, 'SYNTHETIC private race']) {
          expect(log, isNot(contains(value)));
        }
        expect(
          (await send(path: routes.first, payload: payloads.first)).$1,
          503,
        );
        expect(bodies.length, 2);
      },
    );
  }

  test(
    'changing mode cancels an incomplete barrier without forwarding',
    () async {
      await setRace(directory, 'send');
      final pending = send(
        path: '/v1/companion/chat/send',
        payload: jsonEncode(chatSend(sharingId()).toJson()),
      );
      final id = await waitingRace();
      await setFault(directory, 'pass');
      expect((await pending).$1, 503);
      expect(bodies, isEmpty);
      expect(await File('$directory/released-$id.json').exists(), false);
      await expectLater(
        setRace(directory, 'unsupported'),
        throwsFormatException,
      );
    },
  );

  test('race setup keeps independent credentials and routes both installations through the gate', () async {
    final other = '${temporary.path}/race';
    await prepareJourney(other, 'synthetic-race-test');
    await prepareFaultProxy(other, race: true);
    final clients = [
      for (final role in ['a', 'b'])
        jsonDecode(await File('$other/client-$role.json').readAsString())
            as Map,
    ];
    expect(
      clients.first['COMPANION_JOURNEY_URL'],
      clients.last['COMPANION_JOURNEY_URL'],
    );
    expect(
      clients.first['COMPANION_JOURNEY_TOKEN'],
      isNot(clients.last['COMPANION_JOURNEY_TOKEN']),
    );
    expect(
      clients.every((client) => client['COMPANION_JOURNEY_CONCURRENT'] == true),
      true,
    );
  });

  test('chat faults hold only sends and never log message contents', () async {
    await proxy.close();
    final file = File('$directory/config.json');
    final config = jsonDecode(await file.readAsString()) as Map;
    await file.writeAsString(
      jsonEncode({...config, 'fault_route': '/v1/companion/chat/send'}),
    );
    proxy = await CompanionFaultProxy.open(directory);
    body = jsonEncode(
      chatSend(sharingId(), text: 'SYNTHETIC private chat').toJson(),
    );
    await setFault(directory, 'offline');
    await expectLater(
      send(path: '/v1/companion/chat/send'),
      throwsA(isA<HttpException>()),
    );
    expect(bodies, isEmpty);
    expect((await send(path: '/v1/companion/chat/list')).$1, 200);
    await setFault(directory, 'hold');
    var completed = false;
    final response = send(path: '/v1/companion/chat/send').then((value) {
      completed = true;
      return value;
    });
    final marker = jsonDecode(await (await held()).readAsString()) as Map;
    expect(completed, false);
    expect(marker['route'], '/v1/companion/chat/send');
    expect(marker['operation_id'], (jsonDecode(body) as Map)['operation_id']);
    expect(marker['body_hash'], sha256.convert(utf8.encode(body)).toString());
    await setFault(directory, 'pass');
    expect((await response).$1, 200);
    final log = await File('$directory/events.jsonl').readAsString();
    expect(log, isNot(contains(token)));
    expect(log, isNot(contains('SYNTHETIC private chat')));
  });

  test(
    'reply faults preserve operation metadata without logging contents',
    () async {
      await proxy.close();
      final file = File('$directory/config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      await file.writeAsString(
        jsonEncode({...config, 'fault_route': '/v1/companion/replies/send'}),
      );
      proxy = await CompanionFaultProxy.open(directory);
      final command = SharingCommand.fromJson(SharingCommandKind.reply, {
        'protocol': companionProtocol,
        'operation_id': sharingId(),
        'group_id': sharingId(),
        'record_id': sharingId(),
        'text': 'SYNTHETIC private reply',
      });
      body = jsonEncode(command.toJson());
      await setFault(directory, 'offline');
      await expectLater(
        send(path: '/v1/companion/replies/send'),
        throwsA(isA<HttpException>()),
      );
      expect(bodies, isEmpty);
      expect((await send(path: sharedRepliesRoute)).$1, 200);
      await setFault(directory, 'hold');
      var completed = false;
      final response = send(path: '/v1/companion/replies/send').then((value) {
        completed = true;
        return value;
      });
      final marker = jsonDecode(await (await held()).readAsString()) as Map;
      expect(completed, false);
      expect(marker['route'], '/v1/companion/replies/send');
      expect(marker['operation_id'], command.operationId);
      expect(marker['body_hash'], sha256.convert(utf8.encode(body)).toString());
      expect(marker['status'], 200);
      await setFault(directory, 'pass');
      expect((await response).$1, 200);
      final log = await File('$directory/events.jsonl').readAsString();
      for (final value in [token, command.text!]) {
        expect(log, isNot(contains(value)));
        expect(jsonEncode(marker), isNot(contains(value)));
      }
    },
  );

  test(
    'upload faults hold accepted bytes without logging images or credentials',
    () async {
      await proxy.close();
      final file = File('$directory/config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      await file.writeAsString(
        jsonEncode({...config, 'fault_route': companionPhotoUploadRoute}),
      );
      proxy = await CompanionFaultProxy.open(directory);
      final command = mediaUpload(sharingId(), null);
      body = jsonEncode(command.toJson());
      await setFault(directory, 'offline');
      await expectLater(
        send(path: companionPhotoUploadRoute),
        throwsA(isA<HttpException>()),
      );
      expect(bodies, isEmpty);
      expect((await send(path: '/v1/companion/chat/list')).$1, 200);
      await setFault(directory, 'hold');
      var completed = false;
      final response = send(path: companionPhotoUploadRoute).then((value) {
        completed = true;
        return value;
      });
      final marker = jsonDecode(await (await held()).readAsString()) as Map;
      expect(completed, false);
      expect(marker['operation_id'], command.operationId);
      expect(marker['body_hash'], sha256.convert(utf8.encode(body)).toString());
      expect(marker['status'], 200);
      await setFault(directory, 'pass');
      expect((await response).$1, 200);
      final log = await File('$directory/events.jsonl').readAsString();
      for (final value in [token, base64Encode(command.bytes), body]) {
        expect(log, isNot(contains(value)));
        expect(jsonEncode(marker), isNot(contains(value)));
      }
    },
  );

  test('upload setup keeps B direct and refuses mixed journeys', () async {
    final other = '${temporary.path}/upload';
    await prepareJourney(other, 'synthetic-upload-test');
    final original =
        jsonDecode(await File('$other/client-b.json').readAsString()) as Map;
    await expectLater(
      prepareFaultProxy(other, upload: true, chat: true),
      throwsFormatException,
    );
    expect(await Directory('$other/fault-proxy').exists(), false);
    final prepared = await prepareFaultProxy(other, upload: true);
    for (final role in ['a', 'b']) {
      final client = jsonDecode(
        await File('$other/client-$role.json').readAsString(),
      ) as Map;
      expect(client['COMPANION_JOURNEY_UPLOAD_FAULTS'], true);
      expect(client['COMPANION_JOURNEY_RECOVERY'], false);
      expect(
        client['COMPANION_JOURNEY_URL'],
        role == 'a'
            ? 'http://127.0.0.1:${prepared['port']}'
            : original['COMPANION_JOURNEY_URL'],
      );
    }
  });

  test(
    'hold occurs after real upstream acceptance and logs no payload',
    () async {
      await setFault(directory, 'hold');
      var completed = false;
      final result = send().then((value) {
        completed = true;
        return value;
      });
      final marker = await held();
      expect(completed, false);
      expect(bodies, [body]);
      expect(authorizations, ['Bearer $token']);
      final metadata = jsonDecode(await marker.readAsString()) as Map;
      expect(metadata['status'], 200);
      expect(
        metadata['body_hash'],
        sha256.convert(utf8.encode(body)).toString(),
      );
      expect(
        metadata['operation_id'],
        (jsonDecode(body) as Map)['operation_id'],
      );
      await setFault(directory, 'pass');
      expect((await result).$1, 200);
      final log = await File('$directory/events.jsonl').readAsString();
      expect(log, isNot(contains(token)));
      expect(log, isNot(contains('SYNTHETIC private text')));
      expect(await marker.exists(), true);
    },
  );

  test(
    'offline closes without forwarding or returning success headers',
    () async {
      await setFault(directory, 'offline');
      await expectLater(send(), throwsA(isA<HttpException>()));
      expect(bodies, isEmpty);
      await setFault(directory, 'pass');
      expect((await send()).$1, 200);
      expect(bodies, [body]);
    },
  );

  test(
    'delay preserves accepted bytes and unrelated routes stay rejected',
    () async {
      await setFault(directory, 'delay', 100);
      final watch = Stopwatch()..start();
      final result = await send();
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100));
      expect(result, (200, '{"result":"synthetic-accepted"}'));
      expect((await send(path: '/private-not-a-proxy-route')).$1, 404);
      expect(bodies, hasLength(1));
      expect(
        await File('$directory/events.jsonl').readAsString(),
        isNot(contains('private-not-a-proxy-route')),
      );
    },
  );

  test(
    'setup preserves separate tokens and refuses overwrite or bad modes',
    () async {
      final a = jsonDecode(
        await File('$journey/client-a.json').readAsString(),
      ) as Map;
      final b = jsonDecode(
        await File('$journey/client-b.json').readAsString(),
      ) as Map;
      expect(a['COMPANION_JOURNEY_TOKEN'], token);
      expect(
        a['COMPANION_JOURNEY_URL'],
        'http://127.0.0.1:${proxy.server.port}',
      );
      expect(a['COMPANION_JOURNEY_RECOVERY'], true);
      expect(b['COMPANION_JOURNEY_RECOVERY'], true);
      expect(
        a['COMPANION_JOURNEY_TOKEN'] == b['COMPANION_JOURNEY_TOKEN'],
        false,
      );
      expect((await Directory(directory).stat()).mode & 0x3f, 0);
      expect((await File('$directory/config.json').stat()).mode & 0x3f, 0);
      await expectLater(prepareFaultProxy(journey), throwsFormatException);
      await expectLater(setFault(directory, 'invalid'), throwsFormatException);
      await expectLater(
        setFault(directory, 'delay', 30001),
        throwsFormatException,
      );
      await expectLater(setFault(directory, 'hold', 5), throwsFormatException);
    },
  );

  test(
    'network setup selects separate native phases for both clients',
    () async {
      final other = '${temporary.path}/network';
      await prepareJourney(other, 'synthetic-network-test');
      await prepareFaultProxy(other, network: true);
      for (final role in ['a', 'b']) {
        final config = jsonDecode(
          await File('$other/client-$role.json').readAsString(),
        ) as Map;
        expect(config['COMPANION_JOURNEY_RECOVERY'], false);
        expect(config['COMPANION_JOURNEY_NETWORK'], true);
        expect(config['COMPANION_JOURNEY_ROLE'], role);
        expect((await File('$other/client-$role.json').stat()).mode & 0x3f, 0);
      }
    },
  );

  test(
    'deletion setup preserves B direct access and holds only author removal',
    () async {
      final other = '${temporary.path}/deletion';
      await prepareJourney(other, 'synthetic-delete-test');
      final original =
          jsonDecode(await File('$other/client-b.json').readAsString()) as Map;
      await expectLater(
        prepareFaultProxy(other, chatRemoval: true, upload: true),
        throwsFormatException,
      );
      final prepared = await prepareFaultProxy(other, chatRemoval: true);
      final a =
          jsonDecode(await File('$other/client-a.json').readAsString()) as Map;
      final b =
          jsonDecode(await File('$other/client-b.json').readAsString()) as Map;
      expect(a['COMPANION_JOURNEY_DELETE_FAULTS'], true);
      expect(b['COMPANION_JOURNEY_DELETE_FAULTS'], true);
      expect(
        a['COMPANION_JOURNEY_URL'],
        'http://127.0.0.1:${prepared['port']}',
      );
      expect(b['COMPANION_JOURNEY_URL'], original['COMPANION_JOURNEY_URL']);
      await proxy.close();
      final file = File('$directory/config.json');
      final config = jsonDecode(await file.readAsString()) as Map;
      await file.writeAsString(
        jsonEncode({...config, 'fault_route': '/v1/companion/chat/remove'}),
      );
      proxy = await CompanionFaultProxy.open(directory);
      final command = chatRemove(sharingId(), sharingId());
      body = jsonEncode(command.toJson());
      await setFault(directory, 'hold');
      var completed = false;
      final response = send(path: '/v1/companion/chat/remove').then((value) {
        completed = true;
        return value;
      });
      final marker = jsonDecode(await (await held()).readAsString()) as Map;
      expect(completed, false);
      expect(marker['operation_id'], command.operationId);
      expect(marker['body_hash'], sha256.convert(utf8.encode(body)).toString());
      expect(marker['status'], 200);
      expect((await send(path: '/v1/companion/chat/list')).$1, 200);
      await setFault(directory, 'pass');
      expect((await response).$1, 200);
      final log = await File('$directory/events.jsonl').readAsString();
      expect(log, isNot(contains(token)));
      expect(log, isNot(contains(body)));
    },
  );

  test('reply setup faults only B and rejects mixed journeys', () async {
    final other = '${temporary.path}/reply';
    await prepareJourney(other, 'synthetic-reply-test');
    final original =
        jsonDecode(await File('$other/client-a.json').readAsString()) as Map;
    await expectLater(
      prepareFaultProxy(other, reply: true, network: true),
      throwsFormatException,
    );
    expect(await Directory('$other/fault-proxy').exists(), false);
    final result = await prepareFaultProxy(other, reply: true);
    for (final role in ['a', 'b']) {
      final config = jsonDecode(
        await File('$other/client-$role.json').readAsString(),
      ) as Map;
      expect(config['COMPANION_JOURNEY_REPLY_FAULTS'], true);
      expect(config['COMPANION_JOURNEY_RECOVERY'], false);
      expect(config['COMPANION_JOURNEY_NETWORK'], false);
      expect(
        config['COMPANION_JOURNEY_URL'],
        role == 'a'
            ? original['COMPANION_JOURNEY_URL']
            : 'http://127.0.0.1:${result['port']}',
      );
      expect((await File('$other/client-$role.json').stat()).mode & 0x3f, 0);
    }
    final proxyConfig = jsonDecode(
      await File('$other/fault-proxy/config.json').readAsString(),
    ) as Map;
    expect(proxyConfig['fault_route'], '/v1/companion/replies/send');
    expect(proxyConfig['upstream'], original['COMPANION_JOURNEY_URL']);
  });
}
