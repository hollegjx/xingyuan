import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/companion/data/chat_photo_files.dart';
import 'package:habit_checkin/features/companion/data/companion_service.dart';
import 'package:habit_checkin/features/companion/presentation/chat_controller.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'support/chat_fixtures.dart';
import 'support/pairing_fixtures.dart';
import 'support/sharing_fixtures.dart' show sharingId;

class ChatServiceStub implements CompanionChatService, CompanionMediaService {
  final commands = <ChatCommand>[];
  final uploads = <CompanionPhotoUpload>[];
  final rows = <Map<String, Object?>>[];
  final receipts = <String, ChatReceipt>{};
  int revision = 0;
  int reads = 0;
  int downloads = 0;
  CompanionServiceFailure? sendFailure;
  CompanionServiceFailure? readFailure;
  Future<void>? sendGate;
  Future<void>? readGate;
  Future<void>? uploadGate;
  Future<void>? downloadGate;
  CompanionCancellation? downloadCancellation;
  @override
  bool get configured => true;

  @override
  Future<ChatReceipt> executeChat(
    ChatCommand command, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    expect(await access.isCurrent(), true);
    commands.add(command);
    await sendGate;
    if (sendFailure case final failure?) throw failure;
    if (receipts[command.operationId] case final receipt?) return receipt;
    String id;
    if (command.kind == ChatCommandKind.send) {
      id = sharingId(100 + ++revision);
      rows.add(
        chatMessageJson(
          id: id,
          author: testMemberId,
          sequence: revision,
          text: command.text!,
          photo: command.photoId,
        ),
      );
    } else {
      id = command.messageId!;
      rows.removeWhere((r) => r['id'] == id);
      revision++;
    }
    return receipts[command.operationId] = ChatReceipt.fromJson({
      'protocol': companionProtocol,
      'group_id': command.groupId,
      'operation_id': command.operationId,
      'message_id': id,
      'sequence': command.kind == ChatCommandKind.send ? revision : 0,
    }, command: command);
  }

  @override
  Future<ChatPage> messages(
    SharedPageRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    reads++;
    await readGate;
    if (readFailure case final failure?) throw failure;
    return chatPage(rows.reversed.toList(), revision: revision);
  }

  @override
  Future<CompanionPhotoReceipt> uploadPhoto(
    CompanionPhotoUpload request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    uploads.add(request);
    await uploadGate;
    return chatUploadReceipt(request);
  }

  @override
  Future<CompanionPhotoDownload> downloadPhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async {
    downloads++;
    downloadCancellation = cancellation;
    await downloadGate;
    throw const CompanionServiceFailure('photo_unavailable');
  }

  @override
  Future<void> removePhoto(
    CompanionPhotoRequest request, {
    required CompanionAccess access,
    CompanionCancellation? cancellation,
  }) async => throw StateError('No staged-photo removal is expected here.');
}

void main() {
  late ChatFixture f;
  late ChatPhotoFiles files;
  late ChatServiceStub service;
  late ChatController controller;
  setUp(() async {
    tzdata.initializeTimeZones();
    f = ChatFixture(await Directory.systemTemp.createTemp('chat-controller-'));
    await f.open();
    files = ChatPhotoFiles(Directory('${f.directory.path}/photos'), f.db);
    service = ChatServiceStub();
    controller = ChatController(
      store: f.store,
      service: service,
      media: service,
      files: files,
    );
    await controller.initialize();
  });
  tearDown(() async {
    await controller.flushDraft();
    controller.dispose();
    await files.dispose();
    await f.db.close();
    await f.directory.delete(recursive: true);
  });
  Future<void> until(bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(ready(), true);
  }

  test(
    'markRead never consumes a newer snapshot not yet shown by controller',
    () async {
      service.rows.add(chatMessageJson(sequence: 1));
      service.revision = 1;
      await controller.refresh();
      final before = await f.store.snapshot();
      await f.store.acceptPages([
        chatPage([
          chatMessageJson(id: sharingId(11), sequence: 2),
          chatMessageJson(sequence: 1),
        ], revision: 2),
      ], expectedRevision: before.state.cacheRevision);
      await controller.markRead();
      expect((await f.store.snapshot()).state.readSequence, 1);
      expect(controller.unread, 1);
    },
  );

  test('background cancels active authenticated photo downloads', () async {
    service.rows.add(chatMessageJson(photo: sharingId(40)));
    service.revision = 1;
    await controller.refresh();
    final gate = Completer<void>();
    service.downloadGate = gate.future;
    final cancel = CompanionCancellation();
    final download = controller.downloadPhoto(
      sharingId(10),
      sharingId(40),
      cancel,
    );
    final checked = expectLater(
      download,
      throwsA(isA<CompanionServiceFailure>()),
    );
    await until(() => service.downloads == 1);
    controller.setForeground(false);
    final cancelled = service.downloadCancellation!.isCancelled;
    gate.complete();
    await checked;
    expect(cancelled, true);
  });

  test('five sends enqueue once; next input survives slow server and reinitialization', () async {
    final gate = Completer<void>();
    service.sendGate = gate.future;
    await controller.editText('SYNTHETIC first');
    final sends = List.generate(5, (_) => controller.send());
    await until(() => service.commands.isNotEmpty);
    await controller.editText('SYNTHETIC next\n草稿');
    gate.complete();
    expect((await Future.wait(sends)).where((sent) => sent), hasLength(1));
    expect(service.commands, hasLength(1));
    expect(controller.draftText, 'SYNTHETIC next\n草稿');
    controller.dispose();
    controller = ChatController(
      store: f.store,
      service: service,
      media: service,
      files: files,
    );
    await controller.initialize();
    expect(controller.draftText, 'SYNTHETIC next\n草稿');
    expect(controller.snapshot!.messages.single.text, 'SYNTHETIC first');
  });

  test(
    'typing immediately after send keeps the new draft in the serialized queue',
    () async {
      await controller.editText('SYNTHETIC first');
      final send = controller.send();
      final next = controller.editText('SYNTHETIC second');
      await Future.wait([send, next]);
      expect(service.commands.single.text, 'SYNTHETIC first');
      expect(controller.draftText, 'SYNTHETIC second');
      expect((await f.store.snapshot()).state.draftText, 'SYNTHETIC second');
    },
  );

  test(
    'offline unknown send blocks later sends and refresh never resends it',
    () async {
      service.sendFailure = const CompanionServiceFailure(
        'network',
        outcomeUnknown: true,
      );
      await controller.editText('SYNTHETIC first');
      await controller.send();
      final unknown = controller.pending.single;
      expect(unknown.row.status, 'uncertain');
      expect(controller.canDiscard(unknown), false);
      await controller.editText('SYNTHETIC second');
      await controller.send();
      await controller.refresh();
      expect(service.commands, hasLength(1));
      expect(controller.pending.map((p) => p.row.status), [
        'uncertain',
        'pending',
      ]);
      service.sendFailure = null;
      await Future.wait(List.generate(5, (_) => controller.retry(unknown)));
      expect(service.commands, hasLength(3));
      expect(service.commands[1].toJson(), service.commands[0].toJson());
      expect(controller.snapshot!.messages.map((m) => m.text), [
        'SYNTHETIC first',
        'SYNTHETIC second',
      ]);
      expect(controller.pending, isEmpty);
    },
  );

  test(
    'new send queued during a slow refresh is drained after that refresh',
    () async {
      final gate = Completer<void>();
      service.readGate = gate.future;
      final refresh = controller.refresh();
      await until(() => service.reads == 1);
      await controller.editText('SYNTHETIC during refresh');
      final send = controller.send();
      await until(() => controller.pending.isNotEmpty);
      service.readGate = null;
      gate.complete();
      await Future.wait([refresh, send]);
      expect(service.commands, hasLength(1));
      expect(
        controller.snapshot!.messages.single.text,
        'SYNTHETIC during refresh',
      );
    },
  );

  test(
    'background cancels an active read and does not drain a newly queued send',
    () async {
      final gate = Completer<void>();
      service.readGate = gate.future;
      final refresh = controller.refresh();
      await until(() => service.reads == 1);
      await controller.editText('SYNTHETIC pending in background');
      final send = controller.send();
      await until(() => controller.pending.isNotEmpty);
      controller.setForeground(false);
      service.readGate = null;
      gate.complete();
      await Future.wait([refresh, send]);
      expect(service.commands, isEmpty);
      expect(controller.pending.single.row.status, 'pending');
      await controller.refresh();
      expect(service.reads, 1);
      controller.setForeground(true);
      await controller.runPending();
      expect(service.commands, hasLength(1));
    },
  );

  test(
    'definite failed send can be discarded so the next queued message proceeds',
    () async {
      service.sendFailure = const CompanionServiceFailure('invalid_request');
      await controller.editText('SYNTHETIC rejected');
      await controller.send();
      final failed = controller.pending.single;
      expect(controller.canDiscard(failed), true);
      await controller.editText('SYNTHETIC next');
      await controller.send();
      expect(service.commands, hasLength(1));
      service.sendFailure = null;
      await controller.discard(failed);
      expect(controller.snapshot!.messages.single.text, 'SYNTHETIC next');
      expect(service.commands, hasLength(2));
    },
  );

  test(
    'cold-start interrupted work is not resent by initialization or refresh',
    () async {
      await controller.editText('SYNTHETIC interrupted before receipt');
      final revision = (await f.store.snapshot()).state.draftRevision;
      await f.store.enqueueSend(sharingId(70), expectedDraftRevision: revision);
      await f.store.prepareRequest(await f.store.begin(sharingId(70)));
      controller.dispose();
      controller = ChatController(
        store: f.store,
        service: service,
        media: service,
        files: files,
      );
      await controller.initialize();
      await controller.runPending();
      expect(controller.pending.single.row.status, 'uncertain');
      expect(service.commands, isEmpty);
      expect(controller.canRetry(controller.pending.single), true);
    },
  );

  test('uploaded photo receipt is reused on retry and file is retired only after feed', () async {
    expect(await controller.attachPhoto(chatJpeg()), true);
    final photo = controller.draftPhotoId!;
    service.sendFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    await controller.send();
    expect(service.uploads, hasLength(1));
    expect((await files.read(f.store, photo)), isNotEmpty);
    final attempt = controller.pending.single;
    service.sendFailure = null;
    await controller.retry(attempt);
    expect(service.uploads, hasLength(1));
    expect(service.commands[1].toJson(), service.commands[0].toJson());
    expect(controller.snapshot!.messages.single.photoId, sharingId(40));
    await files.sweep();
    expect(await f.db.select(f.db.chatPhotos).get(), isEmpty);
  });

  test(
    'empty and overlength drafts never reach network; boundary emoji does',
    () async {
      expect(await controller.send(), false);
      await controller.editText('👨‍👩‍👧‍👦' * 1001);
      expect(await controller.send(), false);
      expect(service.commands, isEmpty);
      expect(controller.draftText, '👨‍👩‍👧‍👦' * 1001);
      await controller.editText('👨‍👩‍👧‍👦' * 1000);
      expect(await controller.send(), true);
      expect(service.commands, hasLength(1));
    },
  );

  test('cancelled waiting keeps unknown result; same-ID retry recovers exactly once', () async {
    final gate = Completer<void>();
    service.sendGate = gate.future;
    await controller.editText('SYNTHETIC interrupted');
    final send = controller.send();
    await until(() => service.commands.isNotEmpty);
    controller.cancelWaiting();
    gate.complete();
    await send;
    expect(service.rows, hasLength(1));
    expect(controller.pending.single.row.status, 'uncertain');
    await controller.retry(controller.pending.single);
    expect(service.rows, hasLength(1));
    expect(service.commands[1].toJson(), service.commands[0].toJson());
    expect(controller.pending, isEmpty);
  });

  test('successful send followed by failed refresh is not reported as an unconfirmed send', () async {
    service.readFailure = const CompanionServiceFailure('network');
    await controller.editText('SYNTHETIC accepted before refresh failure');
    await controller.send();
    expect(service.rows, hasLength(1));
    expect(controller.pending.single.row.status, 'succeeded');
    expect(controller.error, startsWith('消息操作已完成'));
    expect(controller.canRetry(controller.pending.single), false);
    service.readFailure = null;
    await controller.refresh();
    expect(service.commands, hasLength(1));
    expect(controller.pending, isEmpty);
  });

  test('cancelled refresh never describes an unknown send as unsent', () async {
    service.sendFailure = const CompanionServiceFailure(
      'timeout',
      outcomeUnknown: true,
    );
    await controller.editText('SYNTHETIC unknown result');
    await controller.send();
    final original = controller.pending.single;
    service.readFailure = const CompanionServiceFailure('cancelled');
    await controller.refresh();
    expect(controller.pending.single.row.operationId, original.row.operationId);
    expect(controller.pending.single.row.status, 'uncertain');
    expect(controller.canDiscard(controller.pending.single), false);
    expect(controller.error, isNot(contains('尚未发送')));
  });

  test(
    'cancelled post-send refresh does not contradict the confirmed write',
    () async {
      service.readFailure = const CompanionServiceFailure('cancelled');
      await controller.editText('SYNTHETIC accepted');
      await controller.send();
      expect(service.rows, hasLength(1));
      expect(controller.pending.single.row.status, 'succeeded');
      expect(controller.error, startsWith('消息操作已完成'));
      expect(controller.error, isNot(contains('尚未发送')));
    },
  );

  test(
    'server revocation wipes chat without changing personal records',
    () async {
      await controller.editText('SYNTHETIC private');
      service.readFailure = const CompanionServiceFailure('unauthorized');
      await controller.refresh();
      expect(controller.invalidated, true);
      expect(controller.snapshot, isNull);
      expect(controller.draftText, isEmpty);
      expect(await f.db.select(f.db.chatStates).get(), isEmpty);
      expect((await f.pairing.snapshot()).state, isNull);
    },
  );

  test(
    'unpair during upload rejects late receipt and never sends message',
    () async {
      final gate = Completer<void>();
      service.uploadGate = gate.future;
      await controller.attachPhoto(chatJpeg());
      final send = controller.send();
      await until(() => service.uploads.isNotEmpty);
      await f.pairing.forgetRemote();
      gate.complete();
      await send;
      expect(service.commands, isEmpty);
      expect(controller.invalidated, true);
      expect(await f.db.select(f.db.chatCommands).get(), isEmpty);
      await files.sweep();
      expect(await f.db.select(f.db.chatPhotos).get(), isEmpty);
    },
  );

  test(
    'local unread counts only partner messages and is never sent to service',
    () async {
      service.rows.addAll([
        chatMessageJson(id: sharingId(101), sequence: 1),
        chatMessageJson(id: sharingId(102), sequence: 2, author: testMemberId),
        chatMessageJson(id: sharingId(103), sequence: 3),
      ]);
      service.revision = 3;
      await controller.refresh();
      expect(controller.unread, 2);
      await controller.markRead();
      expect(controller.unread, 0);
      expect(service.commands, isEmpty);
      expect((await f.store.snapshot()).state.readSequence, 3);
    },
  );

  test(
    'delete own message once and refuse partner or missing photo references',
    () async {
      await controller.editText('SYNTHETIC remove');
      await controller.send();
      final id = controller.snapshot!.messages.single.id;
      await Future.wait(List.generate(5, (_) => controller.remove(id)));
      expect(
        service.commands.where((c) => c.kind == ChatCommandKind.remove),
        hasLength(1),
      );
      expect(controller.snapshot!.messages, isEmpty);
      await expectLater(
        controller.downloadPhoto(id, sharingId(40), CompanionCancellation()),
        throwsA(isA<CompanionServiceFailure>()),
      );
      expect(service.downloads, 0);
    },
  );
}
