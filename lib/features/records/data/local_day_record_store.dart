import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../data/sync/sync_identity.dart';
import '../../../shared/local_date.dart';
import '../../companion/data/local_publication_store.dart';

class RecordRuleException implements Exception {
  const RecordRuleException(this.message);
  final String message;
}

class RecordConflict extends RecordRuleException {
  const RecordConflict() : super('记录已有新的修改，请重新打开后再保存');
}

class RecordPhotoInput {
  const RecordPhotoInput({
    required this.id,
    required this.width,
    required this.height,
    required this.byteCount,
    required this.sha256,
  });

  final String id;
  final int width;
  final int height;
  final int byteCount;
  final String sha256;
  String get filename => '$id.jpg';

  void validate() {
    if (!SyncIdentity.isUuid(id) ||
        width < 1 ||
        width > 1600 ||
        height < 1 ||
        height > 1600 ||
        byteCount < 1 ||
        byteCount > 2 * 1024 * 1024 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const RecordRuleException('照片文件无效，请重新选择');
    }
  }
}

class DayRecordSnapshot {
  DayRecordSnapshot(this.record, Iterable<StoredRecordPhoto> photos)
    : savedPhotos = List.unmodifiable(
        photos.where((p) => p.savedPosition != null).toList()
          ..sort((a, b) => a.savedPosition!.compareTo(b.savedPosition!)),
      ),
      draftPhotos = List.unmodifiable(
        photos.where((p) => p.draftPosition != null).toList()
          ..sort((a, b) => a.draftPosition!.compareTo(b.draftPosition!)),
      );

  final StoredDayRecord record;
  final List<StoredRecordPhoto> savedPhotos;
  final List<StoredRecordPhoto> draftPhotos;

  bool get hasDraftChanges =>
      record.draftText != null &&
      (record.draftText != record.content ||
          record.draftShareWithPartner != record.shareWithPartner ||
          draftPhotos.map((photo) => photo.id).join(',') !=
              savedPhotos.map((photo) => photo.id).join(','));
}

class LocalDayRecordStore {
  LocalDayRecordStore(this.goals) {
    if (goals.identityLease == null) {
      throw ArgumentError('Day records require an identity lease');
    }
  }

  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;
  int get _now => goals.clock.read().instant.microsecondsSinceEpoch;
  LocalPublicationStore get publications => LocalPublicationStore(goals);

  Future<T> _transaction<T>(Future<T> Function() action) =>
      db.transaction(() async {
        await goals.requireActiveIdentity();
        return action();
      });

  Future<StoredDayRecord> _record(String id) async {
    final row =
        await (db.select(db.dayRecords)
              ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
            .getSingleOrNull();
    if (row == null) throw const RecordRuleException('找不到这条记录');
    return row;
  }

  Future<void> _writableGoal(int id) async {
    final row =
        await (db.select(db.goals)
              ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
            .getSingleOrNull();
    if (row == null) throw const RecordRuleException('找不到这个目标');
    if (row.archivedAt != null) throw const RecordRuleException('已归档目标只可查看');
  }

  Future<DayRecordSnapshot> _snapshot(StoredDayRecord row) async =>
      DayRecordSnapshot(
        row,
        await (db.select(db.recordPhotos)..where(
              (photo) =>
                  photo.recordId.equals(row.id) & photo.owner.equals(owner),
            ))
            .get(),
      );

  Future<void> _write(String id, DayRecordsCompanion change) => (db.update(
    db.dayRecords,
  )..where((row) => row.id.equals(id) & row.owner.equals(owner))).write(change);

  Future<void> _positions(
    String record,
    List<String> ids, {
    required bool draft,
  }) async {
    final clear = db.update(db.recordPhotos)
      ..where((row) => row.recordId.equals(record) & row.owner.equals(owner));
    await clear.write(
      draft
          ? const RecordPhotosCompanion(draftPosition: Value(null))
          : const RecordPhotosCompanion(savedPosition: Value(null)),
    );
    for (var i = 0; i < ids.length; i++) {
      await (db.update(db.recordPhotos)..where(
            (row) =>
                row.recordId.equals(record) &
                row.owner.equals(owner) &
                row.id.equals(ids[i]),
          ))
          .write(
            draft
                ? RecordPhotosCompanion(draftPosition: Value(i))
                : RecordPhotosCompanion(savedPosition: Value(i)),
          );
    }
  }

  Future<DayRecordSnapshot> beginDraft(int goalId, LocalDate day) =>
      _transaction(() async {
        await _writableGoal(goalId);
        var row =
            await (db.select(db.dayRecords)..where(
                  (row) =>
                      row.goalId.equals(goalId) &
                      row.owner.equals(owner) &
                      row.day.equals(day.key),
                ))
                .getSingleOrNull();
        final clock = goals.clock.read();
        if (row == null) {
          if (day != clock.day) throw const RecordRuleException('只能从今天开始一条新记录');
          final id = const Uuid().v4();
          await db
              .into(db.dayRecords)
              .insert(
                DayRecordsCompanion.insert(
                  id: id,
                  goalId: goalId,
                  owner: owner,
                  day: day.key,
                  zone: Value(clock.zone),
                  createdAt: _now,
                  updatedAt: _now,
                ),
              );
          row = await _record(id);
          await publications.recordCreated(row);
        } else if (day != clock.day && row.draftText == null) {
          throw const RecordRuleException('过去的记录只可查看或删除');
        }
        if (row.draftText == null) {
          final saved = await _snapshot(row);
          final consent = row.shareWithPartner
              ? await publications.recordConsent(row, 'saved')
              : null;
          await publications.writeConsent(row.id, 'draft', consent);
          await _positions(
            row.id,
            saved.savedPhotos.map((photo) => photo.id).toList(),
            draft: true,
          );
          await _write(
            row.id,
            DayRecordsCompanion(
              draftText: Value(row.content),
              draftShareWithPartner: Value(consent != null),
              draftRevision: Value(row.draftRevision + 1),
              updatedAt: Value(_now),
            ),
          );
        }
        return _snapshot(await _record(row.id));
      });

  Future<StoredDayRecord> _draft(String id, int revision) async {
    final row = await _record(id);
    await _writableGoal(row.goalId);
    if (row.draftText == null || row.draftRevision != revision) {
      throw const RecordConflict();
    }
    return row;
  }

  Future<DayRecordSnapshot> writeDraft(
    String id, {
    required String content,
    required int expectedDraftRevision,
    bool? shareWithPartner,
    RecordSharingConsent? sharingConsent,
  }) => _transaction(() async {
    final row = await _draft(id, expectedDraftRevision);
    // Retain invalid user input for correction; the published limit is 500.
    if (content.characters.length > 10000) {
      throw const RecordRuleException('草稿过长，请缩短后重试');
    }
    final RecordSharingConsent? consent;
    if (shareWithPartner == true) {
      if (sharingConsent == null ||
          !await publications.validConsent(row, sharingConsent)) {
        throw const RecordRuleException('分享授权已变化，请重新确认分享给 TA');
      }
      consent = sharingConsent;
    } else if (shareWithPartner == false) {
      consent = null;
    } else {
      consent = row.draftShareWithPartner
          ? await publications.recordConsent(row, 'draft')
          : null;
    }
    await publications.writeConsent(id, 'draft', consent);
    await _write(
      id,
      DayRecordsCompanion(
        draftText: Value(content),
        draftShareWithPartner: Value(consent != null),
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
    return _snapshot(await _record(id));
  });

  Future<DayRecordSnapshot> addPhoto(
    String id, {
    required RecordPhotoInput photo,
    required int expectedDraftRevision,
  }) => _transaction(() async {
    photo.validate();
    final row = await _draft(id, expectedDraftRevision);
    final snapshot = await _snapshot(row);
    if (snapshot.draftPhotos.length >= 3) {
      throw const RecordRuleException('每条记录最多 3 张照片');
    }
    await db
        .into(db.recordPhotos)
        .insert(
          RecordPhotosCompanion.insert(
            id: photo.id,
            recordId: id,
            owner: owner,
            filename: photo.filename,
            width: photo.width,
            height: photo.height,
            byteCount: photo.byteCount,
            sha256: photo.sha256,
            draftPosition: Value(snapshot.draftPhotos.length),
            createdAt: _now,
          ),
        );
    await _write(
      id,
      DayRecordsCompanion(
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
    return _snapshot(await _record(id));
  });

  Future<DayRecordSnapshot> removePhoto(
    String id,
    String photoId, {
    required int expectedDraftRevision,
  }) => _transaction(() async {
    final row = await _draft(id, expectedDraftRevision);
    final current = (await _snapshot(row)).draftPhotos
        .map((photo) => photo.id)
        .toList();
    if (!current.remove(photoId)) throw const RecordRuleException('找不到这张照片');
    await _positions(id, current, draft: true);
    await _write(
      id,
      DayRecordsCompanion(
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
    return _snapshot(await _record(id));
  });

  void _operation(String id) {
    if (!SyncIdentity.isUuid(id)) throw const RecordRuleException('操作标识无效，请重试');
  }

  Future<DayRecordSnapshot> save(
    String id, {
    required String operationId,
    required int expectedRevision,
    required int expectedDraftRevision,
  }) => _transaction(() async {
    _operation(operationId);
    final row = await _record(id);
    await _writableGoal(row.goalId);
    if (row.lastOperationId == operationId) {
      if (row.revision != expectedRevision + 1 || row.deletedAt != null) {
        throw const RecordConflict();
      }
      return _snapshot(row);
    }
    if (row.revision != expectedRevision) throw const RecordConflict();
    await _draft(id, expectedDraftRevision);
    final snapshot = await _snapshot(row);
    final content = row.draftText!;
    if (content.characters.length > 500) {
      throw const RecordRuleException('文字记录最多 500 字');
    }
    if (content.trim().isEmpty && snapshot.draftPhotos.isEmpty) {
      throw const RecordRuleException('请写下文字或添加照片');
    }
    final consent = row.draftShareWithPartner
        ? await publications.recordConsent(row, 'draft')
        : null;
    await publications.writeConsent(id, 'saved', consent);
    await publications.writeConsent(id, 'draft', null);
    await _positions(
      id,
      snapshot.draftPhotos.map((photo) => photo.id).toList(),
      draft: false,
    );
    await _positions(id, const [], draft: true);
    await _write(
      id,
      DayRecordsCompanion(
        content: Value(content),
        shareWithPartner: Value(consent != null),
        revision: Value(row.revision + 1),
        lastOperationId: Value(operationId),
        savedAt: Value(_now),
        deletedAt: const Value(null),
        draftText: const Value(null),
        draftShareWithPartner: const Value(false),
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
        syncState: const Value('local'),
      ),
    );
    await publications.capture(row.goalId, row.day, recordMutation: true);
    return _snapshot(await _record(id));
  });

  Future<void> delete(
    String id, {
    required String operationId,
    required int expectedRevision,
  }) => _transaction(() async {
    _operation(operationId);
    final row = await _record(id);
    if (row.lastOperationId == operationId) {
      if (row.revision != expectedRevision + 1 || row.deletedAt == null) {
        throw const RecordConflict();
      }
      return;
    }
    if (row.revision != expectedRevision) throw const RecordConflict();
    await publications.writeConsent(id, 'saved', null);
    await publications.writeConsent(id, 'draft', null);
    await _positions(id, const [], draft: false);
    await _positions(id, const [], draft: true);
    await _write(
      id,
      DayRecordsCompanion(
        content: const Value(''),
        shareWithPartner: const Value(false),
        revision: Value(row.revision + 1),
        lastOperationId: Value(operationId),
        savedAt: const Value(null),
        deletedAt: Value(_now),
        draftText: const Value(null),
        draftShareWithPartner: const Value(false),
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
        syncState: const Value('local'),
      ),
    );
    await publications.capture(row.goalId, row.day, recordMutation: true);
  });

  Future<List<DayRecordSnapshot>> savedOn(LocalDate day, {int? goalId}) =>
      onDay(day, goalId: goalId, includeDrafts: false);

  Future<DayRecordSnapshot?> at(int goalId, LocalDate day) =>
      _transaction(() async {
        final row =
            await (db.select(db.dayRecords)..where(
                  (row) =>
                      row.owner.equals(owner) &
                      row.goalId.equals(goalId) &
                      row.day.equals(day.key),
                ))
                .getSingleOrNull();
        return row == null ? null : _snapshot(row);
      });

  Stream<List<DayRecordSnapshot>> watchOn(LocalDate day) => db
      .customSelect(
        'SELECT 1',
        readsFrom: {db.dayRecords, db.recordPhotos, db.identityStates},
      )
      .watch()
      .asyncMap((_) => onDay(day));

  Future<List<DayRecordSnapshot>> onDay(
    LocalDate day, {
    int? goalId,
    bool includeDrafts = true,
  }) => _transaction(() async {
    final rows =
        await (db.select(db.dayRecords)
              ..where(
                (row) =>
                    row.owner.equals(owner) &
                    row.day.equals(day.key) &
                    ((row.savedAt.isNotNull() & row.deletedAt.isNull()) |
                        (includeDrafts
                            ? row.draftText.isNotNull()
                            : const Constant(false))) &
                    (goalId == null
                        ? const Constant(true)
                        : row.goalId.equals(goalId)),
              )
              ..orderBy([(row) => OrderingTerm.asc(row.goalId)]))
            .get();
    return [for (final row in rows) await _snapshot(row)];
  });

  Future<List<String>> photoFilenames() => _transaction(
    () async =>
        (await (db.select(
              db.recordPhotos,
            )..where((row) => row.owner.equals(owner))).get())
            .map((row) => row.filename)
            .toList(),
  );

  Future<void> cleanDetachedPhotos(
    Future<void> Function(StoredRecordPhoto photo) remove,
  ) => _transaction(() async {
    final detached = await unreferencedPhotos();
    for (final photo in detached) {
      await remove(photo);
      await (db.delete(db.recordPhotos)..where(
            (row) =>
                row.id.equals(photo.id) &
                row.owner.equals(owner) &
                row.savedPosition.isNull() &
                row.draftPosition.isNull(),
          ))
          .go();
    }
  });

  Future<List<StoredRecordPhoto>> unreferencedPhotos() => _transaction(
    () =>
        (db.select(db.recordPhotos)..where(
              (row) =>
                  row.owner.equals(owner) &
                  row.savedPosition.isNull() &
                  row.draftPosition.isNull() &
                  row.id.isNotInQuery(
                    db.selectOnly(db.sharingPublicationPhotos)
                      ..addColumns([db.sharingPublicationPhotos.photoId])
                      ..where(db.sharingPublicationPhotos.owner.equals(owner)),
                  ),
            ))
            .get(),
  );
}
