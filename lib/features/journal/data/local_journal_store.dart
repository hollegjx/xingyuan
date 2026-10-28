import 'package:characters/characters.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../data/sync/sync_identity.dart';
import '../../../shared/local_date.dart';
import '../../records/data/local_day_record_store.dart';
import '../domain/journal_entry.dart';

class JournalRuleException implements Exception {
  const JournalRuleException(this.message);
  final String message;
}

class JournalConflict extends JournalRuleException {
  const JournalConflict() : super('内容已有新的修改，请重新打开后再保存');
}

class LocalQuickNoteStore extends LocalJournalStore {
  LocalQuickNoteStore(LocalGoalRepository goals)
    : super(goals, JournalKind.quickNote);

  Future<JournalSnapshot> beginDraft({String? id, LocalDate? day}) =>
      _begin(id: id ?? const Uuid().v4(), day: day);
}

class LocalDiaryStore extends LocalJournalStore {
  LocalDiaryStore(LocalGoalRepository goals) : super(goals, JournalKind.diary);

  Future<JournalSnapshot> beginDraft(LocalDate day) => _transaction(() async {
    final existing =
        await (db.select(_entries)..where(
              (row) => row.owner.equals(owner) & row.day.equals(day.key),
            ))
            .getSingleOrNull();
    return _begin(id: existing?.id ?? const Uuid().v4(), day: day);
  });

  Future<JournalSnapshot?> atDay(LocalDate day) => _transaction(() async {
    final row =
        await (db.select(_entries)..where(
              (row) => row.owner.equals(owner) & row.day.equals(day.key),
            ))
            .getSingleOrNull();
    return row == null ? null : _snapshot(row);
  });
}

// The two private tables share a draft protocol, never a publication pipeline.
abstract class LocalJournalStore {
  LocalJournalStore(this.goals, this.kind) {
    if (goals.identityLease == null) {
      throw ArgumentError('Journal storage requires an identity lease');
    }
  }

  static const maxDraftLength = 10000;
  final LocalGoalRepository goals;
  final JournalKind kind;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;
  int get _now => goals.clock.read().instant.microsecondsSinceEpoch;

  TableInfo<JournalEntries, JournalEntry> get _entries =>
      kind == JournalKind.quickNote ? db.quickNotes : db.diaryEntries;
  TableInfo<JournalPhotos, JournalPhoto> get _photos =>
      kind == JournalKind.quickNote ? db.quickNotePhotos : db.diaryPhotos;

  Future<T> _transaction<T>(Future<T> Function() action) =>
      db.transaction(() async {
        await goals.requireActiveIdentity();
        return action();
      });

  void _uuid(String id) {
    if (!SyncIdentity.isUuid(id)) {
      throw const JournalRuleException('操作标识无效，请重新打开');
    }
  }

  Future<JournalEntry?> _find(String id) =>
      (db.select(_entries)
            ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
          .getSingleOrNull();

  Future<JournalEntry> _entry(String id) async =>
      await _find(id) ?? (throw const JournalRuleException('找不到这条内容'));

  Future<JournalSnapshot> _snapshot(JournalEntry entry) async =>
      JournalSnapshot(
        entry,
        await (db.select(
              _photos,
            )..where((p) => p.entryId.equals(entry.id) & p.owner.equals(owner)))
            .get(),
      );

  Future<void> _write(String id, UpdateCompanion<JournalEntry> change) =>
      (db.update(_entries)
            ..where((row) => row.id.equals(id) & row.owner.equals(owner)))
          .write(change);

  Future<JournalSnapshot> _begin({required String id, LocalDate? day}) =>
      _transaction(() async {
        _uuid(id);
        var row = await _find(id);
        if (row == null) {
          final clock = goals.clock.read();
          final target = day ?? clock.day;
          if (target.isAfter(clock.day)) {
            throw const JournalRuleException('请选择今天或过去的日期');
          }
          final now = clock.instant.microsecondsSinceEpoch;
          await db
              .into(_entries)
              .insert(
                _entryChange(
                  id: Value(id),
                  owner: Value(owner),
                  day: Value(target.key),
                  zone: Value(clock.zone),
                  createdAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
          row = await _entry(id);
        } else if ((day != null && row.day != day.key) ||
            (kind == JournalKind.quickNote && row.deletedAt != null)) {
          throw const JournalConflict();
        }
        if (row.draftText == null) {
          final snapshot = await _snapshot(row);
          await _positions(
            id,
            snapshot.savedPhotos.map((p) => p.id).toList(),
            draft: true,
          );
          await _write(
            id,
            _entryChange(
              draftText: Value(row.content),
              draftRevision: Value(row.draftRevision + 1),
              updatedAt: Value(_now),
            ),
          );
        }
        return _snapshot(await _entry(id));
      });

  Future<JournalEntry> _draft(String id, int revision) async {
    final row = await _entry(id);
    if (row.draftText == null || row.draftRevision != revision) {
      throw const JournalConflict();
    }
    return row;
  }

  Future<JournalSnapshot> writeDraft(
    String id, {
    required String content,
    required int expectedDraftRevision,
  }) => _transaction(() async {
    final row = await _draft(id, expectedDraftRevision);
    if (content.characters.length > maxDraftLength) {
      throw const JournalRuleException('草稿最多 10000 字，请缩短后重试');
    }
    await _write(
      id,
      _entryChange(
        draftText: Value(content),
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
    return _snapshot(await _entry(id));
  });

  Future<void> _positions(
    String id,
    List<String> ids, {
    required bool draft,
  }) async {
    await (db.update(
      _photos,
    )..where((p) => p.entryId.equals(id) & p.owner.equals(owner))).write(
      _photoChange(
        savedPosition: draft ? const Value.absent() : const Value(null),
        draftPosition: draft ? const Value(null) : const Value.absent(),
      ),
    );
    for (var i = 0; i < ids.length; i++) {
      await (db.update(_photos)..where(
            (p) =>
                p.entryId.equals(id) &
                p.owner.equals(owner) &
                p.id.equals(ids[i]),
          ))
          .write(
            _photoChange(
              savedPosition: draft ? const Value.absent() : Value(i),
              draftPosition: draft ? Value(i) : const Value.absent(),
            ),
          );
    }
  }

  Future<JournalSnapshot> addPhoto(
    String id, {
    required RecordPhotoInput photo,
    required int expectedDraftRevision,
  }) => _transaction(() async {
    photo.validate();
    final row = await _draft(id, expectedDraftRevision);
    final snapshot = await _snapshot(row);
    if (snapshot.draftPhotos.length >= 3) {
      throw const JournalRuleException('每条内容最多 3 张照片');
    }
    await db
        .into(_photos)
        .insert(
          _photoChange(
            id: Value(photo.id),
            entryId: Value(id),
            owner: Value(owner),
            filename: Value(photo.filename),
            width: Value(photo.width),
            height: Value(photo.height),
            byteCount: Value(photo.byteCount),
            sha256: Value(photo.sha256),
            draftPosition: Value(snapshot.draftPhotos.length),
            createdAt: Value(_now),
          ),
        );
    await _write(
      id,
      _entryChange(
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
    return _snapshot(await _entry(id));
  });

  Future<JournalSnapshot> removePhoto(
    String id,
    String photoId, {
    required int expectedDraftRevision,
  }) => _transaction(() async {
    final row = await _draft(id, expectedDraftRevision);
    final ids = (await _snapshot(row)).draftPhotos.map((p) => p.id).toList();
    if (!ids.remove(photoId)) throw const JournalRuleException('找不到这张照片');
    await _positions(id, ids, draft: true);
    await _write(
      id,
      _entryChange(
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
    return _snapshot(await _entry(id));
  });

  Future<JournalSnapshot> save(
    String id, {
    required String operationId,
    required int expectedRevision,
    required int expectedDraftRevision,
  }) => _transaction(() async {
    _uuid(operationId);
    final row = await _entry(id);
    if (row.lastOperationId == operationId) {
      if (row.revision != expectedRevision + 1 ||
          !row.isSaved ||
          row.lastOperationDraftRevision != expectedDraftRevision) {
        throw const JournalConflict();
      }
      return _snapshot(row);
    }
    if (row.revision != expectedRevision) throw const JournalConflict();
    await _draft(id, expectedDraftRevision);
    final snapshot = await _snapshot(row);
    final text = row.draftText!;
    if (text.characters.length > kind.maxLength) {
      throw JournalRuleException('正文最多 ${kind.maxLength} 字');
    }
    if (text.trim().isEmpty && snapshot.draftPhotos.isEmpty) {
      throw const JournalRuleException('请写下文字或添加照片');
    }
    await _positions(
      id,
      snapshot.draftPhotos.map((p) => p.id).toList(),
      draft: false,
    );
    await _positions(id, const [], draft: true);
    final now = _now;
    await _write(
      id,
      _entryChange(
        content: Value(text),
        savedAt: Value(now),
        deletedAt: const Value(null),
        revision: Value(row.revision + 1),
        lastOperationId: Value(operationId),
        lastOperationDraftRevision: Value(expectedDraftRevision),
        draftText: const Value(null),
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(now),
      ),
    );
    return _snapshot(await _entry(id));
  });

  Future<void> delete(
    String id, {
    required String operationId,
    required int expectedRevision,
    required int expectedDraftRevision,
  }) => _transaction(() async {
    _uuid(operationId);
    final row = await _entry(id);
    if (row.lastOperationId == operationId) {
      if (row.revision != expectedRevision + 1 ||
          row.deletedAt == null ||
          row.lastOperationDraftRevision != expectedDraftRevision) {
        throw const JournalConflict();
      }
      return;
    }
    if (row.revision != expectedRevision ||
        row.draftRevision != expectedDraftRevision ||
        (row.deletedAt != null && row.draftText == null)) {
      throw const JournalConflict();
    }
    await _positions(id, const [], draft: true);
    await _positions(id, const [], draft: false);
    await _write(
      id,
      _entryChange(
        content: const Value(''),
        savedAt: const Value(null),
        deletedAt: Value(_now),
        revision: Value(row.revision + 1),
        lastOperationId: Value(operationId),
        lastOperationDraftRevision: Value(expectedDraftRevision),
        draftText: const Value(null),
        draftRevision: Value(row.draftRevision + 1),
        updatedAt: Value(_now),
      ),
    );
  });

  Future<JournalSnapshot?> at(String id) => _transaction(() async {
    final row = await _find(id);
    return row == null ? null : _snapshot(row);
  });

  Future<List<JournalSnapshot>> onDay(
    LocalDate day, {
    bool includeDrafts = true,
  }) => _list(day: day, includeDrafts: includeDrafts);

  Future<List<JournalSnapshot>> savedOn(LocalDate day) =>
      onDay(day, includeDrafts: false);

  Future<List<JournalSnapshot>> list({int limit = 100, int offset = 0}) {
    if (limit < 1 || limit > 500 || offset < 0) {
      throw ArgumentError('Invalid journal page');
    }
    return _list(limit: limit, offset: offset);
  }

  Future<List<JournalSnapshot>> _list({
    LocalDate? day,
    bool includeDrafts = true,
    int? limit,
    int offset = 0,
  }) => _transaction(() async {
    final query = db.select(_entries)
      ..where(
        (row) =>
            row.owner.equals(owner) &
            (day == null ? const Constant(true) : row.day.equals(day.key)) &
            ((row.savedAt.isNotNull() & row.deletedAt.isNull()) |
                (includeDrafts
                    ? row.draftText.isNotNull()
                    : const Constant(false))),
      )
      ..orderBy([
        (row) => OrderingTerm.desc(row.day),
        (row) => OrderingTerm.desc(row.createdAt),
        (row) => OrderingTerm.desc(row.id),
      ]);
    if (limit != null) query.limit(limit, offset: offset);
    return [for (final row in await query.get()) await _snapshot(row)];
  });

  Stream<List<JournalSnapshot>> watchOn(LocalDate day) =>
      _changes.asyncMap((_) => onDay(day));

  Stream<List<JournalSnapshot>> watchAll({int limit = 100, int offset = 0}) =>
      _changes.asyncMap((_) => list(limit: limit, offset: offset));

  Stream<List<QueryRow>> get _changes => db
      .customSelect(
        // Drift caches stream queries by SQL/parameters, not readsFrom.
        'SELECT 1 AS ${kind.photoFolder}_change',
        readsFrom: {_entries, _photos, db.identityStates},
      )
      .watch();

  Future<List<String>> photoFilenames() => _transaction(
    () async =>
        (await (db.select(_photos)..where((p) => p.owner.equals(owner))).get())
            .map((p) => p.filename)
            .toList(),
  );

  Future<List<JournalPhoto>> unreferencedPhotos() => _transaction(
    () =>
        (db.select(_photos)..where(
              (p) =>
                  p.owner.equals(owner) &
                  p.savedPosition.isNull() &
                  p.draftPosition.isNull(),
            ))
            .get(),
  );

  Future<void> cleanDetachedPhotos(
    Future<void> Function(JournalPhoto) remove,
  ) => _transaction(() async {
    for (final photo in await unreferencedPhotos()) {
      await remove(photo);
      await (db.delete(_photos)..where(
            (p) =>
                p.owner.equals(owner) &
                p.id.equals(photo.id) &
                p.savedPosition.isNull() &
                p.draftPosition.isNull(),
          ))
          .go();
    }
  });

  UpdateCompanion<JournalEntry> _entryChange({
    Value<String> id = const Value.absent(),
    Value<String> owner = const Value.absent(),
    Value<String> day = const Value.absent(),
    Value<String> zone = const Value.absent(),
    Value<String> content = const Value.absent(),
    Value<int> revision = const Value.absent(),
    Value<int?> savedAt = const Value.absent(),
    Value<int?> deletedAt = const Value.absent(),
    Value<String?> lastOperationId = const Value.absent(),
    Value<int?> lastOperationDraftRevision = const Value.absent(),
    Value<String?> draftText = const Value.absent(),
    Value<int> draftRevision = const Value.absent(),
    Value<int> createdAt = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) => kind == JournalKind.quickNote
      ? QuickNotesCompanion(
          id: id,
          owner: owner,
          day: day,
          zone: zone,
          content: content,
          revision: revision,
          savedAt: savedAt,
          deletedAt: deletedAt,
          lastOperationId: lastOperationId,
          draftText: draftText,
          lastOperationDraftRevision: lastOperationDraftRevision,
          draftRevision: draftRevision,
          createdAt: createdAt,
          updatedAt: updatedAt,
        )
      : DiaryEntriesCompanion(
          id: id,
          owner: owner,
          day: day,
          zone: zone,
          content: content,
          revision: revision,
          savedAt: savedAt,
          deletedAt: deletedAt,
          lastOperationId: lastOperationId,
          draftText: draftText,
          lastOperationDraftRevision: lastOperationDraftRevision,
          draftRevision: draftRevision,
          createdAt: createdAt,
          updatedAt: updatedAt,
        );

  UpdateCompanion<JournalPhoto> _photoChange({
    Value<String> id = const Value.absent(),
    Value<String> entryId = const Value.absent(),
    Value<String> owner = const Value.absent(),
    Value<String> filename = const Value.absent(),
    Value<int> width = const Value.absent(),
    Value<int> height = const Value.absent(),
    Value<int> byteCount = const Value.absent(),
    Value<String> sha256 = const Value.absent(),
    Value<int?> savedPosition = const Value.absent(),
    Value<int?> draftPosition = const Value.absent(),
    Value<int> createdAt = const Value.absent(),
  }) => kind == JournalKind.quickNote
      ? QuickNotePhotosCompanion(
          id: id,
          entryId: entryId,
          owner: owner,
          filename: filename,
          width: width,
          height: height,
          byteCount: byteCount,
          sha256: sha256,
          savedPosition: savedPosition,
          draftPosition: draftPosition,
          createdAt: createdAt,
        )
      : DiaryPhotosCompanion(
          id: id,
          entryId: entryId,
          owner: owner,
          filename: filename,
          width: width,
          height: height,
          byteCount: byteCount,
          sha256: sha256,
          savedPosition: savedPosition,
          draftPosition: draftPosition,
          createdAt: createdAt,
        );
}
