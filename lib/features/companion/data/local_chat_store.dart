import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:xingyuan_core/xingyuan_core.dart';

import '../../../data/local/app_database.dart';
import '../../../data/sync/sync_identity.dart';
import 'companion_service.dart';
import 'local_sharing_store.dart';

class ChatPhotoInput {
  const ChatPhotoInput({
    required this.id,
    required this.owner,
    required this.sessionId,
    required this.width,
    required this.height,
    required this.byteCount,
    required this.sha256,
  });
  final String id, owner, sessionId, sha256;
  final int width, height, byteCount;

  void validate() {
    if (!SyncIdentity.isUuid(id) ||
        !SyncIdentity.isUuid(sessionId) ||
        SyncIdentity.tryParse(owner) == null ||
        width < 1 ||
        height < 1 ||
        width > 1600 ||
        height > 1600 ||
        byteCount < 1 ||
        byteCount > companionPhotoByteLimit ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const CompanionServiceFailure('photo_format');
    }
  }
}

class ChatAttempt {
  const ChatAttempt(
    this.row,
    this.sessionId, {
    this.priorOutcomeUnknown = false,
  });
  final StoredChatCommand row;
  final String sessionId;
  final bool priorOutcomeUnknown;
  ChatCommand get command => ChatCommand.fromJson(
    ChatCommandKind.values.byName(row.kind),
    jsonDecode(row.requestJson!),
  );
}

class ChatLocalSnapshot {
  const ChatLocalSnapshot(this.state, this.messages, this.commands, this.photo);
  final StoredChatState state;
  final List<ChatMessage> messages;
  final List<ChatAttempt> commands;
  final StoredChatPhoto? photo;
}

class LocalChatStore {
  LocalChatStore._(this.sharing);
  final LocalSharingStore sharing;
  AppDatabase get db => sharing.db;
  String get owner => sharing.owner;
  String get sessionId => sharing.sessionId;
  String get groupId => sharing.groupId;
  String get memberId => sharing.memberId;
  String get partnerId => sharing.partnerId;
  int get _now =>
      sharing.pairing.goals.clock.read().instant.microsecondsSinceEpoch;

  static Future<LocalChatStore> open(LocalSharingStore sharing) =>
      sharing.db.transaction(() async {
        await sharing.currentState();
        final store = LocalChatStore._(sharing);
        final old = await (store.db.select(
          store.db.chatStates,
        )..where((r) => r.owner.equals(store.owner))).getSingleOrNull();
        if (old == null || old.sessionId != store.sessionId) {
          await store.db.clearChatContent(store.owner);
          await store.db
              .into(store.db.chatStates)
              .insert(
                ChatStatesCompanion.insert(
                  owner: store.owner,
                  sessionId: store.sessionId,
                ),
              );
        }
        return store;
      });

  Future<StoredChatState> _current() async {
    await sharing.currentState();
    final state = await (db.select(
      db.chatStates,
    )..where((r) => r.owner.equals(owner))).getSingleOrNull();
    if (state == null || state.sessionId != sessionId) {
      throw const CompanionServiceFailure('discarded');
    }
    return state;
  }

  Future<bool> isCurrent() async {
    try {
      await db.transaction(_current);
      return true;
    } catch (_) {
      return false;
    }
  }

  Stream<bool> watchCurrent() => db
      .customSelect(
        'SELECT 1 AS chat_scope',
        readsFrom: {
          db.identityStates,
          db.pairingStates,
          db.sharingStates,
          db.chatStates,
        },
      )
      .watch()
      .asyncMap((_) => isCurrent());

  Future<StoredChatPhoto> _photo(String id) async {
    final row =
        await (db.select(db.chatPhotos)..where(
              (r) =>
                  r.id.equals(id) &
                  r.owner.equals(owner) &
                  r.sessionId.equals(sessionId) &
                  r.retired.equals(false),
            ))
            .getSingleOrNull();
    if (row == null) throw const CompanionServiceFailure('photo_unavailable');
    return row;
  }

  Future<StoredChatPhoto> photo(String id) => db.transaction(() async {
    await _current();
    return _photo(id);
  });

  Future<ChatLocalSnapshot> snapshot() => db.transaction(() async {
    final current = await _current();
    final messages =
        await (db.select(db.chatMessagesCache)
              ..where((r) => r.owner.equals(owner))
              ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
            .get();
    final commands =
        await (db.select(db.chatCommands)
              ..where((r) => r.owner.equals(owner))
              ..orderBy([(r) => OrderingTerm.asc(r.sequence)]))
            .get();
    return ChatLocalSnapshot(
      current,
      List.unmodifiable(
        messages.map((r) => ChatMessage.fromJson(jsonDecode(r.documentJson))),
      ),
      List.unmodifiable(
        commands
            .where((r) => r.status != 'succeeded' || r.requestJson != null)
            .map((r) => ChatAttempt(r, sessionId)),
      ),
      current.draftPhotoId == null ? null : await _photo(current.draftPhotoId!),
    );
  });

  Future<void> _saveState(StoredChatState state) =>
      db.into(db.chatStates).insertOnConflictUpdate(state.toCompanion(false));

  Future<void> _retireUnused() async {
    final state = await _current();
    final commands = await (db.select(
      db.chatCommands,
    )..where((r) => r.owner.equals(owner))).get();
    final retained = {
      if (state.draftPhotoId != null) state.draftPhotoId!,
      ...commands.map((r) => r.localPhotoId).whereType<String>(),
    };
    await (db.update(db.chatPhotos)..where(
          (r) =>
              r.owner.equals(owner) &
              r.sessionId.equals(sessionId) &
              r.id.isNotIn(retained),
        ))
        .write(const ChatPhotosCompanion(retired: Value(true)));
  }

  Future<int> writeDraft(
    String text, {
    required String? photoId,
    ChatPhotoInput? addedPhoto,
    required int expectedRevision,
  }) => db.transaction(() async {
    final current = await _current();
    if (current.draftRevision != expectedRevision) {
      throw const CompanionServiceFailure('draft_conflict');
    }
    if (text.characters.length > 10000) {
      throw const CompanionServiceFailure('request_too_large');
    }
    if (addedPhoto != null) {
      addedPhoto.validate();
      if (addedPhoto.id != photoId ||
          addedPhoto.owner != owner ||
          addedPhoto.sessionId != sessionId) {
        throw const CompanionServiceFailure('discarded');
      }
      final existing = await (db.select(
        db.chatPhotos,
      )..where((r) => r.id.equals(addedPhoto.id))).getSingleOrNull();
      if (existing != null) {
        throw const CompanionServiceFailure('operation_conflict');
      }
      await db
          .into(db.chatPhotos)
          .insert(
            ChatPhotosCompanion.insert(
              id: addedPhoto.id,
              owner: owner,
              sessionId: sessionId,
              width: addedPhoto.width,
              height: addedPhoto.height,
              byteCount: addedPhoto.byteCount,
              sha256: addedPhoto.sha256,
              createdAt: _now,
            ),
          );
    }
    if (photoId != null) await _photo(photoId);
    final revision = current.draftRevision + 1;
    await _saveState(
      current.copyWith(
        draftText: text,
        draftPhotoId: Value(photoId),
        draftRevision: revision,
      ),
    );
    await _retireUnused();
    return revision;
  });

  Future<StoredChatCommand?> _command(String operation) =>
      (db.select(db.chatCommands)..where(
            (r) => r.owner.equals(owner) & r.operationId.equals(operation),
          ))
          .getSingleOrNull();

  Future<ChatAttempt> enqueueSend(
    String operation, {
    required int expectedDraftRevision,
  }) => db.transaction(() async {
    final current = await _current();
    final old = await _command(operation);
    if (old != null) {
      if (old.kind != 'send' || old.draftRevision != expectedDraftRevision) {
        throw const CompanionServiceFailure('operation_conflict');
      }
      return ChatAttempt(old, sessionId);
    }
    if (!SyncIdentity.isUuid(operation)) {
      throw const FormatException('Operation ID');
    }
    if (current.draftRevision != expectedDraftRevision) {
      throw const CompanionServiceFailure('draft_conflict');
    }
    if (current.draftText.characters.length > 1000 ||
        (current.draftText.trim().isEmpty && current.draftPhotoId == null)) {
      throw const CompanionServiceFailure('invalid_request');
    }
    if (current.draftPhotoId != null) await _photo(current.draftPhotoId!);
    await db
        .into(db.chatCommands)
        .insert(
          ChatCommandsCompanion.insert(
            owner: owner,
            operationId: operation,
            kind: 'send',
            content: Value(current.draftText),
            localPhotoId: Value(current.draftPhotoId),
            uploadOperationId: Value(
              current.draftPhotoId == null ? null : const Uuid().v4(),
            ),
            draftRevision: Value(expectedDraftRevision),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
    await _saveState(
      current.copyWith(
        draftText: '',
        draftPhotoId: const Value(null),
        draftRevision: current.draftRevision + 1,
      ),
    );
    return ChatAttempt((await _command(operation))!, sessionId);
  });

  Future<ChatAttempt> enqueueRemove(String operation, String message) =>
      db.transaction(() async {
        await _current();
        final command = ChatCommand.fromJson(ChatCommandKind.remove, {
          'protocol': companionProtocol,
          'operation_id': operation,
          'group_id': groupId,
          'message_id': message,
        });
        final old = await _command(operation);
        if (old != null) {
          if (old.kind != 'remove' || old.messageId != message) {
            throw const CompanionServiceFailure('operation_conflict');
          }
          return ChatAttempt(old, sessionId);
        }
        final existing =
            await (db.select(db.chatCommands)..where(
                  (r) =>
                      r.owner.equals(owner) &
                      r.kind.equals('remove') &
                      r.messageId.equals(message),
                ))
                .get();
        if (existing.isNotEmpty) return ChatAttempt(existing.first, sessionId);
        final row =
            await (db.select(db.chatMessagesCache)
                  ..where((r) => r.owner.equals(owner) & r.id.equals(message)))
                .getSingleOrNull();
        if (row == null || row.authorId != memberId) {
          throw const CompanionServiceFailure('message_unavailable');
        }
        await db
            .into(db.chatCommands)
            .insert(
              ChatCommandsCompanion.insert(
                owner: owner,
                operationId: operation,
                kind: 'remove',
                messageId: Value(message),
                requestJson: Value(jsonEncode(command.toJson())),
                createdAt: _now,
                updatedAt: _now,
              ),
            );
        return ChatAttempt((await _command(operation))!, sessionId);
      });

  Future<ChatAttempt> begin(String operation) => db.transaction(() async {
    await _current();
    final row = await _command(operation);
    if (row == null || row.status == 'sending' || row.status == 'succeeded') {
      throw const CompanionServiceFailure('operation_pending');
    }
    if (row.kind == 'send') {
      final earlier =
          await (db.select(db.chatCommands)..where(
                (r) =>
                    r.owner.equals(owner) &
                    r.kind.equals('send') &
                    r.sequence.isSmallerThanValue(row.sequence) &
                    r.status.isNotValue('succeeded'),
              ))
              .get();
      if (earlier.isNotEmpty) {
        throw const CompanionServiceFailure('operation_pending');
      }
    }
    if (row.localPhotoId != null) await _photo(row.localPhotoId!);
    final next = row.copyWith(
      status: 'sending',
      attempts: row.attempts + 1,
      errorCode: const Value(null),
      updatedAt: _now,
    );
    await db
        .into(db.chatCommands)
        .insertOnConflictUpdate(next.toCompanion(false));
    return ChatAttempt(
      next,
      sessionId,
      priorOutcomeUnknown: row.status == 'uncertain',
    );
  });

  Future<StoredChatCommand?> _matching(ChatAttempt attempt) async {
    final row = await _command(attempt.row.operationId);
    if (row == null ||
        attempt.sessionId != sessionId ||
        attempt.row.owner != owner ||
        row.status != 'sending' ||
        row.attempts != attempt.row.attempts ||
        row.kind != attempt.row.kind ||
        row.content != attempt.row.content ||
        row.localPhotoId != attempt.row.localPhotoId ||
        row.uploadOperationId != attempt.row.uploadOperationId ||
        row.messageId != attempt.row.messageId ||
        (attempt.row.requestJson != null &&
            row.requestJson != attempt.row.requestJson)) {
      return null;
    }
    return row;
  }

  Future<ChatAttempt> acceptUpload(
    ChatAttempt attempt,
    CompanionPhotoUpload upload,
    CompanionPhotoReceipt receipt,
  ) => db.transaction(() async {
    await _current();
    final row = await _matching(attempt);
    if (row == null || row.kind != 'send' || row.localPhotoId == null) {
      throw const CompanionServiceFailure('discarded');
    }
    final local = await _photo(row.localPhotoId!);
    final valid = CompanionPhotoReceipt.fromJson(
      receipt.toJson(),
      request: upload,
    );
    if (upload.operationId != row.uploadOperationId ||
        upload.groupId != groupId ||
        upload.purpose != CompanionPhotoPurpose.chat ||
        valid.photo.authorId != memberId ||
        upload.bytes.length != local.byteCount ||
        crypto.sha256.convert(upload.bytes).toString() != local.sha256) {
      throw const CompanionServiceFailure(
        'invalid_response',
        outcomeUnknown: true,
      );
    }
    final json = jsonEncode(valid.toJson());
    if (row.photoReceiptJson != null && row.photoReceiptJson != json) {
      throw const CompanionServiceFailure(
        'invalid_response',
        outcomeUnknown: true,
      );
    }
    final next = row.copyWith(photoReceiptJson: Value(json), updatedAt: _now);
    await db
        .into(db.chatCommands)
        .insertOnConflictUpdate(next.toCompanion(false));
    return ChatAttempt(
      next,
      sessionId,
      priorOutcomeUnknown: attempt.priorOutcomeUnknown,
    );
  });

  Future<ChatAttempt> prepareRequest(ChatAttempt attempt) =>
      db.transaction(() async {
        await _current();
        final row = await _matching(attempt);
        if (row == null) throw const CompanionServiceFailure('discarded');
        if (row.requestJson != null) {
          return ChatAttempt(
            row,
            sessionId,
            priorOutcomeUnknown: attempt.priorOutcomeUnknown,
          );
        }
        String? photo;
        if (row.localPhotoId != null) {
          if (row.photoReceiptJson == null) {
            throw const CompanionServiceFailure('photo_unavailable');
          }
          photo = CompanionPhotoMetadata.fromJson(
            (jsonDecode(row.photoReceiptJson!) as Map)['photo'],
          ).id;
        }
        final request = ChatCommand.fromJson(ChatCommandKind.send, {
          'protocol': companionProtocol,
          'operation_id': row.operationId,
          'group_id': groupId,
          'text': row.content,
          'photo_id': photo,
        });
        final next = row.copyWith(
          requestJson: Value(jsonEncode(request.toJson())),
          updatedAt: _now,
        );
        await db
            .into(db.chatCommands)
            .insertOnConflictUpdate(next.toCompanion(false));
        return ChatAttempt(
          next,
          sessionId,
          priorOutcomeUnknown: attempt.priorOutcomeUnknown,
        );
      });

  Future<void> _scrub(StoredChatCommand row) => db
      .into(db.chatCommands)
      .insertOnConflictUpdate(
        row
            .copyWith(
              content: '',
              localPhotoId: const Value(null),
              uploadOperationId: const Value(null),
              photoReceiptJson: const Value(null),
              requestJson: const Value(null),
            )
            .toCompanion(false),
      );

  Future<bool> finish(ChatAttempt attempt, ChatReceipt receipt) =>
      db.transaction(() async {
        final state = await _current();
        final row = await _matching(attempt);
        if (row == null) return false;
        final valid = ChatReceipt.fromJson(
          receipt.toJson(),
          command: attempt.command,
        );
        final next = row.copyWith(
          status: 'succeeded',
          messageId: Value(valid.messageId),
          receiptJson: Value(jsonEncode(valid.toJson())),
          errorCode: const Value(null),
          updatedAt: _now,
        );
        await db
            .into(db.chatCommands)
            .insertOnConflictUpdate(next.toCompanion(false));
        if (row.kind == 'remove') {
          await (db.delete(db.chatMessagesCache)..where(
                (r) => r.owner.equals(owner) & r.id.equals(valid.messageId),
              ))
              .go();
          final sent =
              await (db.select(db.chatCommands)..where(
                    (r) =>
                        r.owner.equals(owner) &
                        r.kind.equals('send') &
                        r.messageId.equals(valid.messageId) &
                        r.status.equals('succeeded'),
                  ))
                  .get();
          for (final item in sent) {
            await _scrub(item);
          }
          await _scrub(next);
        }
        await _saveState(
          state.copyWith(
            cacheRevision: state.cacheRevision + 1,
            serverRevision: valid.sequence > (state.serverRevision ?? 0)
                ? Value(valid.sequence)
                : Value(state.serverRevision),
          ),
        );
        await _retireUnused();
        return true;
      });

  Future<bool> fail(ChatAttempt attempt, CompanionServiceFailure failure) =>
      db.transaction(() async {
        await _current();
        final row = await _matching(attempt);
        if (row == null) return false;
        final code = failure.code == 'message_unavailable'
            ? failure.code
            : sharingErrorCode(failure.code);
        await db
            .into(db.chatCommands)
            .insertOnConflictUpdate(
              row
                  .copyWith(
                    status:
                        failure.outcomeUnknown || attempt.priorOutcomeUnknown
                        ? 'uncertain'
                        : 'failed',
                    errorCode: Value(code),
                    updatedAt: _now,
                  )
                  .toCompanion(false),
            );
        return true;
      });

  Future<void> recoverInterrupted() => db.transaction(() async {
    await _current();
    await (db.update(
      db.chatCommands,
    )..where((r) => r.owner.equals(owner) & r.status.equals('sending'))).write(
      ChatCommandsCompanion(
        status: const Value('uncertain'),
        errorCode: const Value('interrupted'),
        updatedAt: Value(_now),
      ),
    );
  });

  Future<void> discard(String operation) => db.transaction(() async {
    await _current();
    final row = await _command(operation);
    if (row == null ||
        !(row.status == 'failed' ||
            (row.status == 'pending' && row.attempts == 0))) {
      throw const CompanionServiceFailure('operation_pending');
    }
    await (db.delete(db.chatCommands)..where(
          (r) => r.owner.equals(owner) & r.operationId.equals(operation),
        ))
        .go();
    await _retireUnused();
  });

  Future<bool> acceptPages(
    List<ChatPage> pages, {
    required int expectedRevision,
  }) => db.transaction(() async {
    final state = await _current();
    if (state.cacheRevision != expectedRevision) return false;
    if (pages.isEmpty) throw const CompanionServiceFailure('invalid_response');
    final revision = pages.first.revision;
    if (revision < (state.serverRevision ?? 0)) return false;
    final messages = <ChatMessage>[];
    int? cursor;
    for (var i = 0; i < pages.length; i++) {
      final request = SharedPageRequest.fromJson({
        'protocol': companionProtocol,
        'group_id': groupId,
        'before_sequence': cursor,
        'revision': cursor == null ? null : revision,
      });
      final page = ChatPage.fromJson(pages[i].toJson(), request: request);
      if (page.revision != revision ||
          (i + 1 < pages.length && page.nextBefore == null)) {
        throw const CompanionServiceFailure('snapshot_changed');
      }
      messages.addAll(page.messages);
      cursor = page.nextBefore;
    }
    if (cursor != null ||
        messages.map((r) => r.id).toSet().length != messages.length ||
        messages.map((r) => r.sequence).toSet().length != messages.length ||
        messages.any(
          (r) => r.authorId != memberId && r.authorId != partnerId,
        )) {
      throw const CompanionServiceFailure('invalid_response');
    }
    final old = await (db.select(
      db.chatMessagesCache,
    )..where((r) => r.owner.equals(owner))).get();
    final byId = {for (final row in old) row.id: row};
    if (state.snapshotRevision == revision) {
      final previous = old.map((r) => r.documentJson).toList()..sort();
      final incoming = messages.map((r) => jsonEncode(r.toJson())).toList()
        ..sort();
      if (jsonEncode(previous) != jsonEncode(incoming)) {
        throw const CompanionServiceFailure('invalid_response');
      }
    }
    for (final message in messages) {
      if (byId[message.id] case final cached?) {
        if (cached.documentJson != jsonEncode(message.toJson())) {
          throw const CompanionServiceFailure('invalid_response');
        }
      }
    }
    final completed =
        await (db.select(db.chatCommands)..where(
              (r) => r.owner.equals(owner) & r.status.equals('succeeded'),
            ))
            .get();
    final tombstones = completed
        .where((r) => r.kind == 'remove')
        .map((r) => r.messageId)
        .toSet();
    if (messages.any((r) => tombstones.contains(r.id))) {
      throw const CompanionServiceFailure('snapshot_changed');
    }
    for (final row in completed.where(
      (r) => r.kind == 'send' && r.requestJson != null,
    )) {
      final command = ChatAttempt(row, sessionId).command;
      final receipt = ChatReceipt.fromJson(
        jsonDecode(row.receiptJson!),
        command: command,
      );
      final found = messages
          .where((m) => m.id == receipt.messageId)
          .firstOrNull;
      if (found != null &&
          (found.authorId != memberId ||
              found.sequence != receipt.sequence ||
              found.text != command.text ||
              found.photoId != command.photoId)) {
        throw const CompanionServiceFailure('invalid_response');
      }
      if (revision >= receipt.sequence) await _scrub(row);
    }
    await (db.delete(
      db.chatMessagesCache,
    )..where((r) => r.owner.equals(owner))).go();
    for (final message in messages) {
      await db
          .into(db.chatMessagesCache)
          .insert(
            ChatMessagesCacheCompanion.insert(
              owner: owner,
              id: message.id,
              authorId: message.authorId,
              sequence: message.sequence,
              documentJson: jsonEncode(message.toJson()),
            ),
          );
    }
    await _saveState(
      state.copyWith(
        cacheRevision: state.cacheRevision + 1,
        serverRevision: Value(revision),
        snapshotRevision: Value(revision),
        refreshedAt: Value(_now),
      ),
    );
    await _retireUnused();
    return true;
  });

  Future<void> markRead({int? throughSequence}) => db.transaction(() async {
    final state = await _current();
    final latest =
        await (db.select(db.chatMessagesCache)
              ..where((r) => r.owner.equals(owner))
              ..orderBy([(r) => OrderingTerm.desc(r.sequence)])
              ..limit(1))
            .getSingleOrNull();
    final sequence = latest == null
        ? 0
        : (throughSequence == null || throughSequence > latest.sequence
              ? latest.sequence
              : throughSequence);
    if (sequence > state.readSequence) {
      await _saveState(state.copyWith(readSequence: sequence));
    }
  });
}
