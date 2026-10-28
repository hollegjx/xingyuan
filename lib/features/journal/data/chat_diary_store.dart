import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../data/local/app_database.dart';
import '../../../data/local/local_goal_repository.dart';
import '../../../data/sync/identity_store.dart';
import '../../../shared/local_date.dart';
import '../domain/journal_entry.dart';
import '../domain/journal_suggestion.dart';
import 'local_journal_store.dart';

enum ChatDiaryMode { append, replace }

class ChatDiaryDraftConflict extends JournalRuleException {
  const ChatDiaryDraftConflict() : super('这一天有未保存的草稿，请先在日记中处理；原内容未改动。');
}

class ChatDiaryPreview {
  const ChatDiaryPreview._(this.proposal, this.day, this.existing);
  final StoredDiaryProposal proposal;
  final LocalDate day;
  final JournalEntry? existing;

  String get original => existing?.content ?? '';
  String result(ChatDiaryMode mode, {String? editedText}) =>
      mode == ChatDiaryMode.append && original.isNotEmpty
      ? '$original\n\n${editedText ?? proposal.content}'
      : editedText ?? proposal.content;
}

/// Local-only proposals and receipts; none of these reads enter AI context.
class ChatDiaryStore {
  ChatDiaryStore(this.goals);
  final LocalGoalRepository goals;
  AppDatabase get db => goals.db;
  String get owner => goals.owner;

  Future<void> _active() async {
    await goals.requireActiveIdentity();
    if ((await IdentityStore(db).active()).identity.owner != owner) {
      throw const StaleIdentity();
    }
  }

  Future<T> _transaction<T>(Future<T> Function() action) =>
      db.transaction(() async {
        await _active();
        final result = await action();
        await _active();
        return result;
      });

  Future<List<StoredDiaryProposal>> forSession(String id) => _transaction(
    () => (db.select(
      db.assistantDiaryProposals,
    )..where((p) => p.owner.equals(owner) & p.sessionId.equals(id))).get(),
  );

  Future<StoredDiaryProposal> _proposal(String id) async =>
      await (db.select(db.assistantDiaryProposals)
            ..where((p) => p.owner.equals(owner) & p.id.equals(id)))
          .getSingleOrNull() ??
      (throw const JournalRuleException('找不到这条日记建议'));

  Future<StoredDiaryProposal> proposal(String id) =>
      _transaction(() => _proposal(id));

  Future<JournalEntry?> _entry(LocalDate day) =>
      (db.select(db.diaryEntries)
            ..where((e) => e.owner.equals(owner) & e.day.equals(day.key)))
          .getSingleOrNull();

  Future<ChatDiaryPreview> preview(String id, LocalDate day) =>
      _transaction(() async {
        if (day.isAfter(goals.clock.read().day)) {
          throw const JournalRuleException('请选择今天或过去的日期');
        }
        final proposal = await _proposal(id);
        if (proposal.status != 'pending') {
          throw const JournalRuleException('这条日记建议已处理');
        }
        return ChatDiaryPreview._(proposal, day, await _entry(day));
      });

  Future<StoredDiaryProposal> cancel(String id) => _transaction(() async {
    final proposal = await _proposal(id);
    if (proposal.status == 'pending') {
      await (db.update(
        db.assistantDiaryProposals,
      )..where((p) => p.id.equals(id) & p.owner.equals(owner))).write(
        const AssistantDiaryProposalsCompanion(status: Value('cancelled')),
      );
    }
    return _proposal(id);
  });

  Future<StoredDiaryProposal> apply(
    ChatDiaryPreview preview,
    ChatDiaryMode mode, {
    String? editedText,
  }) => _transaction(() async {
    final proposal = await _proposal(preview.proposal.id);
    // The durable proposal ID is the idempotency key, including after restart.
    if (proposal.status == 'applied') return proposal;
    if (proposal.status != 'pending' ||
        proposal.content != preview.proposal.content) {
      throw const JournalRuleException('这条日记建议已处理，请重新打开');
    }
    if (preview.day.isAfter(goals.clock.read().day)) {
      throw const JournalRuleException('请选择今天或过去的日期');
    }
    final current = await _entry(preview.day);
    final expected = preview.existing;
    if (current?.id != expected?.id ||
        current?.revision != expected?.revision ||
        current?.draftRevision != expected?.draftRevision) {
      throw const JournalConflict();
    }
    if (current != null) {
      final photos =
          await (db.select(db.diaryPhotos)..where(
                (p) => p.owner.equals(owner) & p.entryId.equals(current.id),
              ))
              .get();
      if (JournalSnapshot(current, photos).hasDraftChanges) {
        throw const ChatDiaryDraftConflict();
      }
    }
    final problem = journalSuggestionError(
      editedText ?? proposal.content,
      kind: JournalKind.diary,
      original: preview.original,
      append: mode == ChatDiaryMode.append,
    );
    if (problem != null) {
      throw JournalRuleException(problem);
    }
    final content = preview.result(mode, editedText: editedText);
    final now = goals.clock.read();
    final instant = now.instant.microsecondsSinceEpoch;
    final id = current?.id ?? const Uuid().v4();
    final revision = (current?.revision ?? 0) + 1;
    final draftRevision = (current?.draftRevision ?? 0) + 1;
    final change = DiaryEntriesCompanion(
      content: Value(content),
      savedAt: Value(instant),
      deletedAt: const Value(null),
      revision: Value(revision),
      draftRevision: Value(draftRevision),
      draftText: Value(current?.draftText == null ? null : content),
      lastOperationId: Value(proposal.id),
      lastOperationDraftRevision: Value(current?.draftRevision ?? 0),
      updatedAt: Value(instant),
    );
    if (current == null) {
      await db
          .into(db.diaryEntries)
          .insert(
            change.copyWith(
              id: Value(id),
              owner: Value(owner),
              day: Value(preview.day.key),
              zone: Value(now.zone),
              createdAt: Value(instant),
            ),
          );
    } else {
      await (db.update(
        db.diaryEntries,
      )..where((e) => e.id.equals(id) & e.owner.equals(owner))).write(change);
    }
    // Text-only application leaves every photo and its saved/draft slot intact.
    final before = current == null
        ? null
        : jsonEncode({
            'content': current.content,
            'saved_at': current.savedAt,
            'deleted_at': current.deletedAt,
            'draft_text': current.draftText,
          });
    await (db.update(
      db.assistantDiaryProposals,
    )..where((p) => p.id.equals(proposal.id) & p.owner.equals(owner))).write(
      AssistantDiaryProposalsCompanion(
        status: const Value('applied'),
        targetDay: Value(preview.day.key),
        entryId: Value(id),
        beforeJson: Value(before),
        appliedRevision: Value(revision),
        appliedDraftRevision: Value(draftRevision),
        appliedAt: Value(instant),
      ),
    );
    return _proposal(proposal.id);
  });

  Future<StoredDiaryProposal> undo(String id) => _transaction(() async {
    final proposal = await _proposal(id);
    if (proposal.status == 'undone') return proposal;
    if (proposal.status != 'applied') {
      throw const JournalRuleException('这条日记建议尚未保存');
    }
    final entry = await _entry(LocalDate.parse(proposal.targetDay!));
    if (entry == null ||
        entry.id != proposal.entryId ||
        entry.revision != proposal.appliedRevision ||
        entry.lastOperationId != proposal.id) {
      throw const JournalRuleException('日记已有后续修改，不能自动撤销；后续内容已保留。');
    }
    final before = proposal.beforeJson == null
        ? null
        : jsonDecode(proposal.beforeJson!) as Map<String, dynamic>;
    if (entry.draftRevision != proposal.appliedDraftRevision) {
      final photos =
          await (db.select(db.diaryPhotos)..where(
                (p) => p.entryId.equals(entry.id) & p.owner.equals(owner),
              ))
              .get();
      // beginDraft clones saved text/photos once; any later write advances again.
      final onlyOpened =
          before?['draft_text'] == null &&
          entry.draftRevision == proposal.appliedDraftRevision! + 1 &&
          entry.draftText == entry.content &&
          !JournalSnapshot(entry, photos).hasDraftChanges;
      if (!onlyOpened) {
        throw const JournalRuleException('日记已有后续修改，不能自动撤销；后续内容已保留。');
      }
      await (db.update(db.diaryPhotos)
            ..where((p) => p.entryId.equals(entry.id) & p.owner.equals(owner)))
          .write(const DiaryPhotosCompanion(draftPosition: Value(null)));
    }
    final now = goals.clock.read().instant.microsecondsSinceEpoch;
    await (db.update(
      db.diaryEntries,
    )..where((e) => e.id.equals(entry.id) & e.owner.equals(owner))).write(
      DiaryEntriesCompanion(
        content: Value(before?['content'] as String? ?? ''),
        savedAt: Value(before?['saved_at'] as int?),
        deletedAt: Value(before == null ? now : before['deleted_at'] as int?),
        draftText: Value(before?['draft_text'] as String?),
        revision: Value(entry.revision + 1),
        draftRevision: Value(entry.draftRevision + 1),
        lastOperationId: Value(const Uuid().v4()),
        lastOperationDraftRevision: Value(entry.draftRevision),
        updatedAt: Value(now),
      ),
    );
    await (db.update(db.assistantDiaryProposals)
          ..where((p) => p.id.equals(id) & p.owner.equals(owner)))
        .write(const AssistantDiaryProposalsCompanion(status: Value('undone')));
    return _proposal(id);
  });
}
