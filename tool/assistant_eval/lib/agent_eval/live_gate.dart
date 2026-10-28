import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_server/model_access.dart';

import 'fixtures.dart';

const agentRelay = 'https://model.example.invalid/v1/chat/completions';

/// A local interlock, not a substitute for the owner's direct authorization.
class LivePermit {
  LivePermit._(this.id, this.limit, this.expires, this.productDigest);
  final String id;
  final int limit;
  final DateTime expires;
  final String productDigest;

  static LivePermit read({
    required bool live,
    required String? marker,
    required String productDigest,
    DateTime? now,
  }) {
    if (!live || marker == null) throw const FormatException('Live denied');
    final file = File(marker);
    if ((file.statSync().mode & 0x3f) != 0) {
      throw const FormatException('Live denied');
    }
    final value = object(jsonDecode(file.readAsStringSync()));
    final expires = DateTime.tryParse('${value['expires_at']}');
    final quota = value['max_calls'];
    if (value.keys.toSet().difference({
          'id',
          'scope',
          'owner_authorized',
          'max_calls',
          'expires_at',
          'endpoint',
          'product_digest',
        }).isNotEmpty ||
        value['scope'] != 'xingyuan-agent-a4-synthetic' ||
        value['owner_authorized'] != true ||
        value['endpoint'] != agentRelay ||
        value['product_digest'] != productDigest ||
        !RegExp(r'^[a-zA-Z0-9_-]{16,64}$').hasMatch('${value['id']}') ||
        quota is! int ||
        quota < 1 ||
        quota > 300 ||
        expires == null ||
        !expires.isUtc ||
        !expires.isAfter(now ?? DateTime.now().toUtc())) {
      throw const FormatException('Live denied');
    }
    return LivePermit._(value['id'] as String, quota, expires, productDigest);
  }

  void checkTime() {
    if (!expires.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('Authorization expired');
    }
  }

  Future<AssistantModelClient> loadConfig(String path) async {
    checkTime();
    // A0-style guard before optional Keychain access, using one parsed snapshot.
    return loadModelConfig(
      path,
      maxCompletionTokens: 1500,
      requiredEndpoint: Uri.parse(agentRelay),
    );
  }
}

class AgentDriverOptions {
  AgentDriverOptions._(
    this.live,
    this.output,
    this.marker,
    this.config,
    this.fixtureVersion,
  );
  final bool live;
  final String output;
  final String? marker;
  final String? config;
  final String fixtureVersion;

  factory AgentDriverOptions.parse(List<String> args) {
    if (args.isEmpty || !{'--live', '--scripted'}.contains(args.first)) {
      throw const FormatException('Explicit mode required');
    }
    final options = <String, String>{};
    for (var i = 1; i < args.length; i += 2) {
      if (i + 1 >= args.length ||
          !{
            '--output',
            '--authorization',
            '--config',
            '--fixture-version',
          }.contains(args[i]) ||
          options.containsKey(args[i]) ||
          args[i + 1].isEmpty ||
          args[i + 1].startsWith('--')) {
        throw const FormatException('Invalid options');
      }
      options[args[i]] = args[i + 1];
    }
    final live = args.first == '--live';
    final fixtureVersion = options['--fixture-version'] ?? 'agent-c26-v2';
    if (options['--output'] == null ||
        !agentDriverFixtures.containsKey(fixtureVersion) ||
        (live &&
            (options['--authorization'] == null ||
                options['--config'] == null)) ||
        (!live &&
            options.keys.any(
              (k) => !{'--output', '--fixture-version'}.contains(k),
            ))) {
      throw const FormatException('Invalid options');
    }
    return AgentDriverOptions._(
      live,
      options['--output']!,
      options['--authorization'],
      options['--config'],
      fixtureVersion,
    );
  }
}
