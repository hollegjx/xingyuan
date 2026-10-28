import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/chat_photo_files.dart';
import 'package:habit_checkin/features/companion/presentation/chat_controller.dart';
import 'package:habit_checkin/features/companion/presentation/companion_foreground.dart';
import 'package:habit_checkin/features/companion/presentation/pairing_controller.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/chat_fixtures.dart';
import 'support/chat_service.dart';

void main() {
  late ChatFixture f;
  late ChatPhotoFiles files;
  late TestChatService service;
  late ChatController chat;
  late PairingController pairing;
  late SharingController sharing;
  late CompanionForeground foreground;
  Future<ChatController> Function()? load;
  setUp(() async {
    tzdata.initializeTimeZones();
    f = ChatFixture(await Directory.systemTemp.createTemp('chat-foreground-'));
    await f.open();
    service = TestChatService();
    files = ChatPhotoFiles(Directory('${f.directory.path}/photos'), f.db);
    chat = ChatController(
      store: f.store,
      service: service,
      media: service,
      files: files,
    );
    pairing = PairingController(store: f.pairing, service: service);
    sharing = SharingController(store: f.sharing, service: service);
    await chat.initialize();
    await pairing.initialize();
    await sharing.initialize();
    load = null;
    foreground = CompanionForeground(
      pairing: pairing,
      loadSharing: () async => sharing,
      loadRunner: () async =>
          throw StateError('SYNTHETIC publication unavailable'),
      loadChat: () => load?.call() ?? Future.value(chat),
      groupChanged: () {},
    );
  });
  tearDown(() async {
    foreground.dispose();
    await foreground.idle;
    chat.dispose();
    sharing.dispose();
    pairing.dispose();
    await files.dispose();
    await f.db.close();
    await f.directory.delete(recursive: true);
  });

  test(
    'publication load failure does not prevent foreground chat and unread',
    () async {
      service.incoming('SYNTHETIC incoming');
      foreground.setForeground(true);
      await foreground.idle;
      expect(chat.unread, 1);
      expect(service.chatReads, 1);
      foreground.setForeground(false);
      await chat.editText('SYNTHETIC queued');
      await chat.send();
      expect(service.chatCommands, isEmpty);
      foreground.setForeground(true);
      await foreground.idle;
      expect(service.chatCommands, hasLength(1));
      expect(chat.unread, 1);
    },
  );

  test('controller loaded after background transition cannot send', () async {
    final started = Completer<void>();
    final gate = Completer<ChatController>();
    load = () {
      started.complete();
      return gate.future;
    };
    foreground.setForeground(true);
    await started.future;
    foreground.setForeground(false);
    gate.complete(chat);
    await foreground.idle;
    await chat.editText('SYNTHETIC later');
    await chat.send();
    expect(service.chatCommands, isEmpty);
    expect(service.chatReads, 0);
  });
}
