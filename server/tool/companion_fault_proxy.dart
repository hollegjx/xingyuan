import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

const _publication = '/v1/companion/records/publish';
const _chatSend = '/v1/companion/chat/send';
const _chatRemove = '/v1/companion/chat/remove';
const _reply = '/v1/companion/replies/send';
final _leave = pairingCommandRoutes.entries
    .singleWhere((entry) => entry.value == PairingCommandKind.leave)
    .key;
const _modes = {'pass', 'hold', 'offline', 'delay'};
const _limit = 2800000;

List<String> _raceRoutes(String kind) => switch (kind) {
  'send' => [_chatSend, _chatSend],
  'leave' => [_leave, _leave],
  'send-leave' => [_chatSend, _leave],
  _ => throw const FormatException('Race kind'),
};

class _Race {
  final actors = <String>{};
  final requests = <Map<String, Object?>>[];
  final ready = Completer<bool>();
  var arrived = 0;
}

Future<void> _json(String path, Object value) async {
  final temporary = File('$path.tmp');
  await temporary.writeAsString(jsonEncode(value), flush: true);
  if ((await Process.run('chmod', ['600', temporary.path])).exitCode != 0) {
    throw const FileSystemException('Private permissions required');
  }
  await temporary.rename(path);
}

Future<Map<String, dynamic>> _read(String path) async =>
    jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;

Uri _loopback(String value) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'http' ||
      uri.host != '127.0.0.1' ||
      !uri.hasPort ||
      uri.port < 1024 ||
      uri.path.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('Loopback endpoint required');
  }
  return uri;
}

Future<void> setFault(String directory, String mode, [int delay = 0]) async {
  if (!_modes.contains(mode) ||
      (mode == 'delay' ? delay < 1 || delay > 30000 : delay != 0)) {
    throw const FormatException('Fault mode');
  }
  await _json('$directory/control.json', {
    'id': const Uuid().v4(),
    'mode': mode,
    'delay_ms': delay,
  });
}

Future<void> setRace(String directory, String kind) async {
  _raceRoutes(kind);
  await _json('$directory/control.json', {
    'id': const Uuid().v4(),
    'mode': 'race',
    'kind': kind,
    'delay_ms': 0,
  });
}

Future<Map<String, Object>> prepareFaultProxy(
  String journey, {
  bool network = false,
  bool chat = false,
  bool race = false,
  bool reply = false,
  bool upload = false,
  bool chatRemoval = false,
}) async {
  if ([
        network,
        chat,
        race,
        reply,
        upload,
        chatRemoval,
      ].where((selected) => selected).length >
      1) {
    throw const FormatException('Select one fault journey');
  }
  final manifest = await _read('$journey/journey.json');
  final directory = '$journey/fault-proxy';
  if (!File(journey).isAbsolute ||
      manifest['format'] != 'xingyuan-companion-journey-v1' ||
      await FileSystemEntity.type(directory, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw const FormatException('Use a fresh prepared journey');
  }
  final a = await _read('$journey/client-a.json');
  final b = await _read('$journey/client-b.json');
  for (final entry in {'a': a, 'b': b}.entries) {
    if (entry.value['COMPANION_JOURNEY_RUN'] != manifest['run'] ||
        entry.value['COMPANION_JOURNEY_ROLE'] != entry.key) {
      throw const FormatException('Client scope');
    }
  }
  final upstream = _loopback(a['COMPANION_JOURNEY_URL'] as String);
  await Directory(directory).create();
  if ((await Process.run('chmod', ['700', directory])).exitCode != 0) {
    throw const FileSystemException('Private permissions required');
  }
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  final config = <String, Object>{
    'upstream': upstream.toString(),
    'port': port,
    'fault_route': chatRemoval
        ? _chatRemove
        : upload
        ? companionPhotoUploadRoute
        : reply
        ? _reply
        : chat || race
        ? _chatSend
        : _publication,
  };
  await _json('$directory/config.json', config);
  await setFault(directory, 'pass');
  await _json('$journey/client-a.json', {
    ...a,
    if (!reply) 'COMPANION_JOURNEY_URL': 'http://127.0.0.1:$port',
    'COMPANION_JOURNEY_RECOVERY': !network && !reply && !upload && !chatRemoval,
    'COMPANION_JOURNEY_NETWORK': network,
    'COMPANION_JOURNEY_CONCURRENT': race,
    'COMPANION_JOURNEY_REPLY_FAULTS': reply,
    'COMPANION_JOURNEY_UPLOAD_FAULTS': upload,
    'COMPANION_JOURNEY_DELETE_FAULTS': chatRemoval,
  });
  await _json('$journey/client-b.json', {
    ...b,
    if (race || reply) 'COMPANION_JOURNEY_URL': 'http://127.0.0.1:$port',
    'COMPANION_JOURNEY_RECOVERY': !network && !reply && !upload && !chatRemoval,
    'COMPANION_JOURNEY_NETWORK': network,
    'COMPANION_JOURNEY_CONCURRENT': race,
    'COMPANION_JOURNEY_REPLY_FAULTS': reply,
    'COMPANION_JOURNEY_UPLOAD_FAULTS': upload,
    'COMPANION_JOURNEY_DELETE_FAULTS': chatRemoval,
  });
  return {'port': port, 'directory': directory};
}

// QA only: forwards real traffic and records opaque metadata, never payloads.
class CompanionFaultProxy {
  CompanionFaultProxy._(
    this.directory,
    this.upstream,
    this.server,
    this.faultRoute,
  );
  final String directory;
  final Uri upstream;
  final HttpServer server;
  final String faultRoute;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final _running = <Future<void>>{};
  Future<void> _logging = Future.value();
  bool _closed = false;
  final _races = <String, _Race>{};

  static Future<CompanionFaultProxy> open(String directory) async {
    final config = await _read('$directory/config.json');
    final upstream = _loopback(config['upstream'] as String);
    final port = config['port'] as int;
    final faultRoute = config['fault_route'] ?? _publication;
    if (!{
      _publication,
      _chatSend,
      _chatRemove,
      _reply,
      companionPhotoUploadRoute,
    }.contains(faultRoute)) {
      throw const FormatException('Unsupported fault route');
    }
    if (port < 1024 || port > 65535 || port == upstream.port) {
      throw const FormatException('Proxy port');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final proxy = CompanionFaultProxy._(
      directory,
      upstream,
      server,
      faultRoute as String,
    );
    server.listen((request) {
      late Future<void> operation;
      operation = proxy._handle(request).whenComplete(() {
        proxy._running.remove(operation);
      });
      proxy._running.add(operation);
    });
    return proxy;
  }

  Future<void> _event(Map<String, Object?> event) => _logging = _logging.then(
    (_) => File('$directory/events.jsonl').writeAsString(
      '${jsonEncode(event)}\n',
      mode: FileMode.append,
      flush: true,
    ),
  );

  Future<List<int>> _bytes(Stream<List<int>> stream) async {
    final result = <int>[];
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (result.length + chunk.length > _limit) {
        throw const FormatException('Bounded QA transport');
      }
      result.addAll(chunk);
    }
    return result;
  }

  Future<void> _race(
    Map<String, dynamic> control,
    Map<String, Object?> metadata,
    String? authorization,
  ) async {
    final id = control['id'] as String;
    final routes = _raceRoutes(control['kind'] as String);
    final gate = _races.putIfAbsent(id, _Race.new);
    final route = metadata['route'];
    if (authorization == null ||
        !RegExp(r'^Bearer [A-Za-z0-9_-]{43}$').hasMatch(authorization) ||
        gate.ready.isCompleted ||
        gate.actors.contains(authorization) ||
        gate.requests.where((request) => request['route'] == route).length >=
            routes.where((expected) => expected == route).length) {
      throw const FormatException('Two distinct matching actors required');
    }
    gate.actors.add(authorization);
    final slot = gate.requests.length;
    final entry = {...metadata, 'race_id': id, 'slot': slot};
    gate.requests.add(entry);
    await _json('$directory/waiting-$id-$slot.json', entry);
    await _event({...entry, 'forwarded': false, 'waiting': true});
    gate.arrived++;
    if (gate.arrived == 2 && !gate.ready.isCompleted) {
      await _json('$directory/released-$id.json', {
        'kind': control['kind'],
        'requests': gate.requests,
        'distinct_actors': 2,
      });
      gate.ready.complete(true);
    }
    final watch = Stopwatch()..start();
    while (!gate.ready.isCompleted) {
      if (_closed ||
          watch.elapsed > const Duration(minutes: 5) ||
          (await _read('$directory/control.json'))['id'] != id) {
        gate.ready.complete(false);
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!await gate.ready.future ||
        _closed ||
        (await _read('$directory/control.json'))['id'] != id) {
      throw const FormatException('Race cancelled');
    }
  }

  Future<void> _handle(HttpRequest incoming) async {
    try {
      final path = incoming.uri.path;
      final allowed = {
        '/v1/health',
        pairingStateRoute,
        ...pairingCommandRoutes.keys,
        ...sharingCommandRoutes.keys,
        sharingGrantsRoute,
        sharedFeedRoute,
        sharedRecordRoute,
        sharedRepliesRoute,
        publicationResolveRoute,
        companionPhotoUploadRoute,
        companionPhotoReadRoute,
        companionPhotoRemoveRoute,
        ...chatCommandRoutes.keys,
        chatMessagesRoute,
      };
      if (!allowed.contains(path) || incoming.uri.hasQuery) {
        incoming.response.statusCode = 404;
        await incoming.response.close();
        return;
      }
      final body = await _bytes(incoming);
      final control = await _read('$directory/control.json');
      final racing =
          control['mode'] == 'race' &&
          _raceRoutes(control['kind'] as String).contains(path);
      final mode = racing
          ? 'race'
          : path == faultRoute && control['mode'] != 'race'
          ? control['mode'] as String
          : 'pass';
      if (!_modes.contains(mode) && mode != 'race') {
        throw const FormatException('Fault mode');
      }
      final metadata = <String, Object?>{'route': path, 'mode': mode};
      if (path == faultRoute || racing) {
        final payload = jsonDecode(utf8.decode(body));
        metadata['operation_id'] = path == companionPhotoUploadRoute
            ? CompanionPhotoUpload.fromJson(payload).operationId
            : path == _leave
            ? PairingCommand.fromJson(
                PairingCommandKind.leave,
                payload,
              ).operationId
            : path == _publication || path == _reply
            ? SharingCommand.fromJson(
                path == _reply
                    ? SharingCommandKind.reply
                    : SharingCommandKind.publish,
                payload,
              ).operationId
            : ChatCommand.fromJson(
                path == _chatRemove
                    ? ChatCommandKind.remove
                    : ChatCommandKind.send,
                payload,
              ).operationId;
        metadata['body_hash'] = sha256.convert(body).toString();
      }
      if (racing) {
        metadata['race_id'] = control['id'];
        await _race(control, metadata, incoming.headers.value('authorization'));
      }
      if (mode == 'offline') {
        await _event({...metadata, 'forwarded': false});
        (await incoming.response.detachSocket(writeHeaders: false)).destroy();
        return;
      }
      final request = await _client.openUrl(
        incoming.method,
        upstream.replace(path: path),
      );
      request.followRedirects = false;
      for (final header in ['authorization', 'content-type']) {
        final value = incoming.headers.value(header);
        if (value != null) request.headers.set(header, value);
      }
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      final responseBody = await _bytes(response);
      metadata.addAll({'forwarded': true, 'status': response.statusCode});
      await _event(metadata);
      if (mode == 'hold' && response.statusCode == 200) {
        await _json('$directory/held-${control['id']}.json', metadata);
        final deadline = DateTime.now().add(const Duration(minutes: 5));
        while (!_closed && DateTime.now().isBefore(deadline)) {
          if ((await _read('$directory/control.json'))['id'] != control['id']) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      } else if (mode == 'delay') {
        await Future<void>.delayed(
          Duration(milliseconds: control['delay_ms'] as int),
        );
      }
      if (_closed) return;
      incoming.response.statusCode = response.statusCode;
      incoming.response.headers.contentType = ContentType.json;
      incoming.response.add(responseBody);
      await incoming.response.close();
    } catch (_) {
      try {
        incoming.response.statusCode = 503;
        incoming.response.write('{"error":"qa_proxy_unavailable"}');
        await incoming.response.close();
      } catch (_) {
        // Forced client termination intentionally breaks the response stream.
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final gate in _races.values) {
      if (!gate.ready.isCompleted) gate.ready.complete(false);
    }
    _client.close(force: true);
    await server.close(force: true);
    await Future.wait(_running.toList());
    await _logging;
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.length == 2 &&
        {
          'prepare',
          'prepare-network',
          'prepare-chat',
          'prepare-race',
          'prepare-reply',
          'prepare-upload',
          'prepare-delete',
        }.contains(args.first)) {
      stdout.writeln(
        jsonEncode(
          await prepareFaultProxy(
            args[1],
            network: args.first == 'prepare-network',
            chat: args.first == 'prepare-chat',
            race: args.first == 'prepare-race',
            reply: args.first == 'prepare-reply',
            upload: args.first == 'prepare-upload',
            chatRemoval: args.first == 'prepare-delete',
          ),
        ),
      );
    } else if (args.length == 2 && args.first == 'serve') {
      final proxy = await CompanionFaultProxy.open('${args[1]}/fault-proxy');
      for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
        signal.watch().listen((_) async {
          await proxy.close();
          exit(0);
        });
      }
      stdout.writeln('QA loopback fault proxy ready.');
    } else if (args.length == 3 && args.first == 'race') {
      await setRace('${args[1]}/fault-proxy', args[2]);
      stdout.writeln('QA race gate armed.');
    } else if ((args.length == 3 || args.length == 4) && args.first == 'mode') {
      await setFault(
        '${args[1]}/fault-proxy',
        args[2],
        args.length == 4 ? int.parse(args[3]) : 0,
      );
      stdout.writeln('QA fault mode updated.');
    } else {
      throw const FormatException();
    }
  } catch (_) {
    stderr.writeln(
      'Usage: companion_fault_proxy prepare|prepare-network|prepare-chat|prepare-race|prepare-reply|prepare-upload|prepare-delete|serve PRIVATE_JOURNEY | '
      'mode PRIVATE_JOURNEY pass|hold|offline|delay [DELAY_MS] | race PRIVATE_JOURNEY send|leave|send-leave',
    );
    exitCode = 64;
  }
}
