import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_ai_service.dart';
import 'support/journal_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  Finder key(String name) => find.byKey(ValueKey(name));
  String draft(WidgetTester tester) =>
      tester.widget<TextField>(key('journal-text')).controller!.text;

  Future<UiHarness> mount(
    WidgetTester tester,
    SyntheticJournalAi service,
  ) async {
    final h = UiHarness();
    h.clock.setDay(2026, 10, 23);
    await h.mount(
      tester,
      journalAiService: service,
      assistantCredentials: ConversationTestCredentials(),
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
    );
    final store = await h.container.read(assistantStoreProvider.future);
    await store.memories.consent();
    h.container.invalidate(assistantSettingsProvider);
    await tester.pumpAndSettle();
    return h;
  }

  testUiWidgets(
    'failed polish retries explicitly and repeated taps stay single flight',
    (tester) async {
      final service = SyntheticJournalAi()..fail = true;
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-quick-note'));
      await tester.enterText(key('journal-text'), '合成原文');
      await tester.pumpAndSettle();
      await tapVisible(tester, key('journal-ai-request'));
      expect(service.calls, hasLength(1));
      expect(key('journal-ai-suggestion'), findsNothing);
      expect(draft(tester), '合成原文');
      await tester.pump(const Duration(seconds: 3));
      expect(service.calls, hasLength(1));
      service
        ..fail = false
        ..gate = Completer<void>();
      await tapVisible(tester, key('journal-ai-request'), settle: false);
      expect(key('journal-ai-cancel'), findsOneWidget);
      expect(
        tester.widget<TextButton>(key('journal-ai-request')).onPressed,
        isNull,
      );
      for (var i = 0; i < 5; i++) {
        await tester.tap(key('journal-ai-request'));
      }
      await pumpWaiting(tester);
      expect(service.calls, hasLength(2));
      expect(
        service.calls.first['request_id'],
        isNot(service.calls.last['request_id']),
      );
      expect(service.calls.last.keys.toSet(), {
        'protocol',
        'request_id',
        'text',
      });
      expect(service.calls.last['text'], '合成原文');
      service.gate!.complete();
      await tester.pumpAndSettle();
      expect(key('journal-ai-suggestion'), findsOneWidget);
      await tapVisible(tester, key('journal-ai-use'));
      expect(draft(tester), service.rewrite);
      final store = await h.container.read(quickNoteStoreProvider.future);
      expect(await store.savedOn(h.clock.day), isEmpty);
      await tapVisible(tester, key('journal-ai-undo'));
      expect(draft(tester), '合成原文');
      expect(
        (await h.database.select(h.database.quickNotes).get()).single.draftText,
        '合成原文',
      );
    },
  );

  testUiWidgets(
    'editing during AI wait preserves the newer draft and hides stale result',
    (tester) async {
      final service = SyntheticJournalAi()..gate = Completer<void>();
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-quick-note'));
      await tester.enterText(key('journal-text'), '原来的合成文字');
      await tester.pumpAndSettle();
      await tapVisible(tester, key('journal-ai-request'), settle: false);
      expect(service.calls, hasLength(1));
      await tester.enterText(key('journal-text'), '等待时新增的合成文字');
      await pumpWaiting(tester);
      expect(draft(tester), '等待时新增的合成文字');
      service.gate!.complete();
      await tester.pumpAndSettle();
      expect(key('journal-ai-suggestion'), findsNothing);
      expect(find.textContaining('内容已变化'), findsOneWidget);
      expect(draft(tester), '等待时新增的合成文字');
      final row = (await h.database.select(h.database.quickNotes).get()).single;
      expect(row.draftText, '等待时新增的合成文字');
      expect(row.savedAt, isNull);
      expect(service.calls.single['text'], '原来的合成文字');
    },
  );

  testUiWidgets(
    'leaving a pending request cannot open a late preview and draft reopens',
    (tester) async {
      final service = SyntheticJournalAi()..gate = Completer<void>();
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-quick-note'));
      await tester.enterText(key('journal-text'), '返回后仍保留的草稿');
      await tester.pumpAndSettle();
      await tapVisible(tester, key('journal-ai-request'), settle: false);
      expect(service.calls, hasLength(1));
      final original =
          (await h.database.select(h.database.quickNotes).get()).single;
      await goBack(tester);
      service.gate!.complete();
      await tester.pumpAndSettle();
      expect(key('journal-text'), findsNothing);
      expect(key('journal-ai-suggestion'), findsNothing);
      await tapVisible(tester, key('journal-entry-${original.id}'));
      expect(draft(tester), '返回后仍保留的草稿');
      final rows = await h.database.select(h.database.quickNotes).get();
      expect(rows, hasLength(1));
      expect(rows.single.savedAt, isNull);
      expect(rows.single.draftText, '返回后仍保留的草稿');
      expect(service.calls, hasLength(1));
    },
  );

  testUiWidgets(
    'over-limit diary append stays in preview and preserves exact draft',
    (tester) async {
      final service = SyntheticJournalAi();
      final h = await mount(tester, service);
      await tapVisible(tester, key('entry-quick-note'));
      await tester.enterText(key('journal-text'), '今天读完了一章');
      await tester.pumpAndSettle();
      await tapVisible(tester, key('save-journal'));
      await tapVisible(tester, key('entry-diary'));
      final original = '文' * 4999;
      await tester.enterText(key('journal-text'), original);
      await tester.pumpAndSettle();
      await tapVisible(tester, key('journal-ai-request'));
      await tapVisible(tester, find.text('追加'));
      expect(
        tester.widget<FilledButton>(key('journal-ai-use')).onPressed,
        isNull,
      );
      await tapVisible(tester, key('journal-ai-use'));
      expect(key('journal-ai-suggestion'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(BottomSheet).last,
          matching: find.text('追加后超过 5000 字，请精简新正文或选择替换。'),
        ),
        findsOneWidget,
      );
      await tapVisible(tester, key('journal-ai-keep'));
      expect(draft(tester), original);
      final row =
          (await h.database.select(h.database.diaryEntries).get()).single;
      expect(row.draftText, original);
      expect(row.savedAt, isNull);
      expect(service.calls, hasLength(1));
    },
  );
}
