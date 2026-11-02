import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/assistant/data/local_memory_store.dart';
import 'package:habit_checkin/features/assistant/domain/agent_run_metadata.dart';
import 'package:habit_checkin/features/assistant/presentation/agent_run_details.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'assistant_c69_tools_test.dart' show C69ScriptedService;
import 'assistant_conversation_ui_test.dart' show openPlanning, sendText;
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';
import 'support/journal_fixtures.dart';

import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/features/journal/presentation/chat_diary_page.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);
  testUiWidgets(
    'C69 past-day confirmation denial is visible and cancellation closes confirmation',
    (tester) async {
      final app = UiHarness();
      final service = C69ScriptedService();
      final day = app.clock.day.addDays(-1).key;
      service.tool('get_journal_text', {
        'day': day,
        'kinds': ['quickNote'],
      });
      service.reply('TEST read denied, continue conversation');
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST use yesterday notes', waiting: true);
      await pumpWaiting(tester);
      expect(
        find.byKey(const ValueKey('assistant-read-confirm')),
        findsOneWidget,
      );
      expect(find.text('只读这一天的完成情况、随手记和日记，用来写日记或回顾。'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-read-deny')),
      );
      expect(find.text('你选择了不读取，我只根据你说的内容来写'), findsOneWidget);
      expect(
        service.requestsSeen.last.results.single['status'],
        'not_authorized',
      );
      service.tool('get_journal_text', {
        'day': day,
        'kinds': ['quickNote'],
      });
      await sendText(tester, 'TEST another past read', waiting: true);
      await pumpWaiting(tester);
      expect(
        find.byKey(const ValueKey('assistant-read-confirm')),
        findsOneWidget,
      );
      final controller = await app.container.read(
        assistantConversationProvider.future,
      );
      await controller.cancel();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('assistant-read-confirm')),
        findsNothing,
      );
      expect(service.requestsSeen, hasLength(3));
    },
  );
  testUiWidgets(
    'C69 explicit today entry carries scope and preserves unsent composer',
    (tester) async {
      final app = UiHarness();
      final service = C69ScriptedService();
      service.tool('get_day_summary', {'day': app.clock.day.key});
      service.reply('TEST no material');
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
      );
      await LocalMemoryStore(app.repository).consent();
      await openPlanning(tester);
      await tester.enterText(
        find.byKey(const ValueKey('assistant-input')),
        'TEST unsent',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('assistant-record-entry')),
      );
      expect(service.requestsSeen, hasLength(2));
      expect(
        find.byKey(const ValueKey('assistant-read-confirm')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('assistant-input')))
            .controller!
            .text,
        'TEST unsent',
      );
      expect(find.textContaining('没有完成记录'), findsOneWidget);
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
    },
  );
  for (final scale in [1.0, 3.5]) {
    testWidgets(
      'C69 actual receipt metadata renders at ${scale}x without source text',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 568),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: AgentRunDetails(
                    scope: 'test',
                    metadata: AgentRunMetadata(
                      date: CalendarDate.parse('2026-11-01'),
                      assistantFallback: true,
                      recordHistoryWithheld: true,
                      statuses: {'truncated'},
                      trace: [
                        const AgentTraceEntry(
                          'get_journal_text',
                          'truncated',
                          1,
                        ),
                      ],
                      readReceipts: [
                        {
                          'day': '2026-11-01',
                          'kinds': ['quickNote'],
                          'count': 2,
                          'status': 'truncated',
                          'cached': false,
                        },
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          find.text('为了保护你的记录，这一轮只发送你刚才说的话；之前读过记录的对话没有一起发送。'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('assistant-record-history-withheld')),
          findsOneWidget,
        );
        expect(find.text('已读取 11月1日 的 2 条随手记（内容较多，只读了前面一部分）'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('assistant-capability-fallback')),
          findsOneWidget,
        );
        expect(find.textContaining('只读取了部分日程'), findsNothing);
        expect(find.textContaining('查了冲突'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testUiWidgets(
    'C73 fallback opens current-day editor without a model call or formal save',
    (tester) async {
      final app = UiHarness();
      final service = C69ScriptedService()..capable = false;
      service.reply('TEST fallback');
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
        journalPhotoFiles: {
          JournalKind.diary: MemoryJournalPhotoFiles(JournalKind.diary),
        },
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST help');
      expect(
        find.byKey(const ValueKey('assistant-capability-fallback')),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('打开今天的日记'), settle: false);
      await pumpWaiting(tester);
      final editor = tester.widget<JournalEditorPage>(
        find.byType(JournalEditorPage),
      );
      expect(editor.kind, JournalKind.diary);
      expect(editor.day, app.clock.day);
      expect(service.requestsSeen, hasLength(1));
      expect(
        (await app.database.select(app.database.diaryEntries).get()).where(
          (row) => row.savedAt != null,
        ),
        isEmpty,
      );
    },
  );
  testUiWidgets(
    'C73 tool diary card opens a pending editable proposal without saving',
    (tester) async {
      final app = UiHarness();
      final service = C69ScriptedService();
      service.tool('create_diary_draft', {
        'day': app.clock.day.key,
        'text': 'TEST editable suggestion',
      });
      await app.mount(
        tester,
        assistantService: service,
        assistantCredentials: ConversationTestCredentials(),
        journalPhotoFiles: {
          JournalKind.diary: MemoryJournalPhotoFiles(JournalKind.diary),
        },
      );
      await openPlanning(tester);
      await sendText(tester, 'TEST diary draft');
      expect(find.text('打开草稿'), findsOneWidget);
      await tapVisible(tester, find.text('打开草稿'));
      expect(find.byType(ChatDiaryPage), findsOneWidget);
      expect(
        await app.database.select(app.database.diaryEntries).get(),
        isEmpty,
      );
      expect(
        (await app.database.select(app.database.assistantDiaryProposals).get())
            .single
            .status,
        'pending',
      );
    },
  );
}
