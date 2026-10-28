import 'dart:convert';
import 'dart:ui' show ViewPadding;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_editor_page.dart';
import 'package:habit_checkin/features/journal/presentation/journal_list_page.dart';
import 'package:habit_checkin/features/goals/presentation/goal_form_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:uuid/uuid.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;

import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(tzdata.initializeTimeZones);

  Future<UiHarness> mount(
    WidgetTester tester, {
    StubRecordPhotoPicker? picker,
  }) async {
    final h = UiHarness();
    h.clock.setDay(2026, 10, 23);
    await h.mount(
      tester,
      journalPhotoFiles: {
        for (final kind in JournalKind.values)
          kind: MemoryJournalPhotoFiles(kind),
      },
      recordPhotoPicker: picker ?? StubRecordPhotoPicker(),
    );
    return h;
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  Future<void> write(WidgetTester tester, String value) async {
    await tester.enterText(key('journal-text'), value);
    await tester.pumpAndSettle();
    expect(find.text('草稿已保存在本机'), findsOneWidget);
  }

  testUiWidgets(
    'quick note bottom sheet focuses, resumes a draft and saves only once',
    (tester) async {
      final h = await mount(tester);
      await tapVisible(tester, key('entry-quick-note'));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        tester.widget<TextField>(key('journal-text')).focusNode!.hasFocus,
        isTrue,
      );
      await write(tester, 'SYNTHETIC first note\nsecond line');
      final store = await h.container.read(quickNoteStoreProvider.future);
      final initial = (await store.onDay(h.clock.day)).single.entry;
      expect(initial.savedAt, isNull);
      await goBack(tester);
      expect(find.byType(JournalEditorPage), findsNothing);
      await tapVisible(tester, key('journal-entry-${initial.id}'));
      expect(
        tester.widget<TextField>(key('journal-text')).controller!.text,
        initial.draftText,
      );
      await tester.tap(key('save-journal'));
      await tester.tap(key('save-journal'));
      await tester.pumpAndSettle();
      expect(find.byType(JournalEditorPage), findsNothing);
      final saved = await store.savedOn(h.clock.day);
      expect(saved, hasLength(1));
      expect(saved.single.entry.revision, 1);
      expect(saved.single.entry.content, initial.draftText);
      expect(h.container.exists(assistantConversationProvider), isFalse);
      expect(h.container.exists(pairingControllerProvider), isFalse);
    },
  );

  testUiWidgets(
    'diary appears in today, review and notebook; historical edits preserve day',
    (tester) async {
      final h = await mount(tester);
      final day = h.clock.day;
      await tapVisible(tester, key('entry-diary'));
      await write(tester, 'SYNTHETIC diary');
      await tapVisible(tester, key('save-journal'));
      expect(find.byType(JournalEditorPage), findsNothing);
      final store = await h.container.read(diaryStoreProvider.future);
      final entry = (await store.atDay(day))!.entry;
      await tester.pumpAndSettle();
      expect(key('journal-entry-${entry.id}'), findsOneWidget);
      h.clock.setDay(2026, 10, 24);
      await h.container.read(environmentProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(key('journal-entry-${entry.id}'), findsNothing);
      await tapVisible(tester, find.byTooltip('回顾'));
      await tapVisible(tester, key('review-day-${day.key}'));
      await tapVisible(tester, key('journal-entry-${entry.id}'));
      await write(tester, 'SYNTHETIC historical edit');
      await tapVisible(tester, key('save-journal'));
      expect(
        (await store.atDay(day))!.entry.content,
        'SYNTHETIC historical edit',
      );
      expect(await store.atDay(h.clock.day), isNull);
      await tapVisible(tester, find.byTooltip('我的'));
      await tapVisible(tester, key('my-diary'));
      expect(find.byType(JournalListPage), findsOneWidget);
      await tapVisible(tester, key('journal-entry-${entry.id}'));
      expect(
        tester.widget<TextField>(key('journal-text')).controller!.text,
        'SYNTHETIC historical edit',
      );
      await goBack(tester);
      await goBack(tester);
      await tapVisible(tester, key('my-quick-notes'));
      expect(find.text('还没有内容'), findsOneWidget);
    },
  );

  testUiWidgets(
    'check-in with no goals opens form; all former settings remain in My',
    (tester) async {
      final h = await mount(tester);
      await tapVisible(tester, key('entry-check-in'));
      expect(find.byType(GoalFormPage), findsOneWidget);
      await goBack(tester);
      await tapVisible(tester, find.byTooltip('我的'));
      for (final label in ['目标管理', '日记本', '全部随手记', 'AI 设置', '系统通知', '保存在本机']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(key('enable-day-analysis'), findsOneWidget);
      await tapVisible(tester, key('request-permission'));
      expect(h.permissions.requests, 1);
      await tapVisible(tester, key('open-notification-settings'));
      expect(h.permissions.settingsOpens, 1);
      h.container.read(notificationOpenProvider.notifier).opened();
      await tester.pumpAndSettle();
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0,
      );
    },
  );

  testUiWidgets(
    'photos add, open and remove; cancelled delete preserves data',
    (tester) async {
      final picker = StubRecordPhotoPicker()
        ..onPick = () async => img.encodePng(img.Image(width: 40, height: 30));
      final h = await mount(tester, picker: picker);
      await tapVisible(tester, key('entry-diary'));
      await write(tester, 'SYNTHETIC photo diary');
      await tapVisible(tester, key('journal-add-photo'));
      for (var attempt = 0; attempt < 200; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
        if (find.byTooltip('移除照片').evaluate().isNotEmpty &&
            find
                .byType(RawImage)
                .evaluate()
                .any((element) => (element.widget as RawImage).image != null)) {
          break;
        }
      }
      expect(
        find
            .byType(RawImage)
            .evaluate()
            .any((element) => (element.widget as RawImage).image != null),
        isTrue,
        reason: 'Decode must finish before settling the loading indicator',
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除照片'), findsOneWidget);
      final store = await h.container.read(diaryStoreProvider.future);
      final photo = (await store.atDay(h.clock.day))!.draftPhotos.single;
      await tapVisible(tester, key('journal-photo-${photo.id}'));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await goBack(tester);
      await tapVisible(tester, key('save-journal'));
      await tapVisible(tester, key('entry-diary'));
      await tapVisible(tester, key('delete-journal'));
      await tapVisible(tester, find.text('取消'));
      expect((await store.atDay(h.clock.day))!.entry.isSaved, isTrue);
      await tapVisible(tester, key('remove-journal-photo-${photo.id}'));
      await tapVisible(tester, key('save-journal'));
      expect((await store.atDay(h.clock.day))!.savedPhotos, isEmpty);
      await tapVisible(tester, key('entry-diary'));
      await tapVisible(tester, key('delete-journal'));
      await tapVisible(tester, key('confirm-delete-journal'));
      expect(find.byType(JournalEditorPage), findsNothing);
      expect(await store.savedOn(h.clock.day), isEmpty);
      expect(await h.database.select(h.database.checkIns).get(), isEmpty);
    },
  );

  testUiWidgets(
    'identity change hides journal editor and rejects its old lease after returning',
    (tester) async {
      final h = await mount(tester);
      await tapVisible(tester, key('entry-quick-note'));
      await write(tester, 'SYNTHETIC private');
      final identities = IdentityStore(h.database);
      await identities.finish(
        await identities.begin(
          SyncIdentity.account('55555555-5555-4555-8555-555555555555'),
        ),
      );
      await tester.pumpAndSettle();
      expect(key('journal-text'), findsNothing);
      expect(find.text('身份已变化或不可用。'), findsOneWidget);
      await identities.finish(await identities.begin(SyncIdentity.guest));
      await tester.pumpAndSettle();
      expect(key('journal-text'), findsNothing);
      expect(
        await h.database.select(h.database.quickNotes).get(),
        hasLength(1),
      );
    },
  );

  testUiWidgets(
    'failed draft blocks exit, retries in place and never claims saved',
    (tester) async {
      final h = await mount(tester);
      await tapVisible(tester, key('entry-quick-note'));
      await h.database.customStatement(
        "CREATE TRIGGER synthetic_draft_failure BEFORE UPDATE ON quick_notes "
        "WHEN NEW.draft_text LIKE 'SYNTHETIC%' BEGIN SELECT RAISE(ABORT, 'SYNTHETIC failure'); END",
      );
      await tester.enterText(key('journal-text'), 'SYNTHETIC preserve newest');
      await tester.pumpAndSettle();
      expect(find.text('草稿未保存'), findsOneWidget);
      await goBack(tester);
      expect(find.byType(JournalEditorPage), findsOneWidget);
      expect(
        tester.widget<TextField>(key('journal-text')).controller!.text,
        'SYNTHETIC preserve newest',
      );
      await tapVisible(tester, key('save-journal'));
      final store = await h.container.read(quickNoteStoreProvider.future);
      expect(await store.savedOn(h.clock.day), isEmpty);
      await h.database.customStatement('DROP TRIGGER synthetic_draft_failure');
      await tapVisible(tester, key('retry-journal-draft'));
      expect(find.text('草稿已保存在本机'), findsOneWidget);
      await tapVisible(tester, key('save-journal'));
      expect(
        (await store.savedOn(h.clock.day)).single.entry.content,
        'SYNTHETIC preserve newest',
      );
    },
  );

  testUiWidgets('check-in entry scrolls to goals without completing them', (
    tester,
  ) async {
    final h = await mount(tester);
    final id = await h.repository.create(
      const GoalDraft(title: 'SYNTHETIC goal', kind: GoalKind.habit),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, key('entry-check-in'));
    expect(find.text('今天的目标').hitTestable(), findsOneWidget);
    expect((await h.repository.loadGoals()).single.completions, isEmpty);
    await tapVisible(tester, key('complete-$id'));
    expect((await h.repository.loadGoals()).single.completions, hasLength(1));
  });

  testUiWidgets(
    'all-notes list pages beyond the first fifty without dropping records',
    (tester) async {
      final h = await mount(tester);
      final store = await h.container.read(quickNoteStoreProvider.future);
      for (var i = 0; i < 51; i++) {
        var row = await store.beginDraft();
        row = await store.writeDraft(
          row.entry.id,
          content: 'SYNTHETIC note $i',
          expectedDraftRevision: row.entry.draftRevision,
        );
        await store.save(
          row.entry.id,
          operationId: const Uuid().v4(),
          expectedRevision: row.entry.revision,
          expectedDraftRevision: row.entry.draftRevision,
        );
      }
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byTooltip('我的'));
      await tapVisible(tester, key('my-quick-notes'));
      expect(find.byType(JournalPreviewTile), findsNWidgets(50));
      await tapVisible(tester, key('journal-next-page'));
      expect(find.byType(JournalPreviewTile), findsOneWidget);
      expect(
        tester.widget<IconButton>(key('journal-next-page')).onPressed,
        isNull,
      );
      await tapVisible(tester, key('journal-previous-page'));
      expect(find.byType(JournalPreviewTile), findsNWidgets(50));
      expect(await store.list(), hasLength(51));
    },
  );

  for (final scale in [1.0, 3.5]) {
    for (final brightness in Brightness.values) {
      for (final kind in JournalKind.values) {
        for (final inheritedSafeAreas in [
          false,
          if (scale == 3.5 && kind == JournalKind.diary) true,
        ]) {
          testUiWidgets(
            inheritedSafeAreas
                ? 'inherited safe areas at 320px $scale ${brightness.name} with keyboard'
                : '${kind.name} at 320px $scale ${brightness.name} with keyboard',
            (tester) async {
              Map<String, double> edges(ViewPadding padding) => {
                'left': padding.left,
                'top': padding.top,
                'right': padding.right,
                'bottom': padding.bottom,
              };
              Map<String, Object> viewGeometry() => {
                'physical_size': tester.view.physicalSize.toString(),
                'dpr': tester.view.devicePixelRatio,
                'padding': edges(tester.view.padding),
                'view_padding': edges(tester.view.viewPadding),
                'view_insets': edges(tester.view.viewInsets),
              };
              final beforeOverride = viewGeometry();
              addTearDown(() {
                tester.view.resetPhysicalSize();
                tester.view.resetDevicePixelRatio();
                tester.view.resetPadding();
                tester.view.resetViewPadding();
                tester.view.resetViewInsets();
                tester.platformDispatcher.clearTextScaleFactorTestValue();
                tester.platformDispatcher.clearPlatformBrightnessTestValue();
              });
              if (inheritedSafeAreas) {
                // Reproduce A1-51's native edges surviving a size/DPR override.
                tester.view.physicalSize = const Size(1242, 2688);
                tester.view.devicePixelRatio = 3;
                tester.view.padding = const FakeViewPadding(
                  top: 132,
                  bottom: 102,
                );
                tester.view.viewPadding = const FakeViewPadding(
                  top: 132,
                  bottom: 102,
                );
                tester.view.viewInsets = const FakeViewPadding();
              }
              final beforeFixture = viewGeometry();
              tester.view.physicalSize = const Size(320, 568);
              tester.view.devicePixelRatio = 1;
              tester.view.padding = const FakeViewPadding(top: 20);
              tester.view.viewPadding = const FakeViewPadding(top: 20);
              tester.view.viewInsets = const FakeViewPadding();
              tester.platformDispatcher.textScaleFactorTestValue = scale;
              tester.platformDispatcher.platformBrightnessTestValue =
                  brightness;
              final h = await mount(tester);
              await tapVisible(
                tester,
                key(
                  kind == JournalKind.quickNote
                      ? 'entry-quick-note'
                      : 'entry-diary',
                ),
              );
              await write(tester, '合成日常记录\n今天按自己的节奏前进。');
              tester.view.viewInsets = const FakeViewPadding(bottom: 200);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              if (kind == JournalKind.diary) {
                final editor = find.byType(JournalEditorPage);
                final media = MediaQuery.of(tester.element(editor));
                final layout = tester.renderObject<RenderBox>(
                  find
                      .ancestor(
                        of: key('journal-editor-scroll'),
                        matching: find.byType(LayoutBuilder),
                      )
                      .first,
                );
                const actions = [
                  'journal-add-photo',
                  'journal-take-photo',
                  'delete-journal',
                  'journal-ai-request',
                ];
                for (final action in actions) {
                  final geometry = {
                    'action': action,
                    'scale': scale,
                    'theme': brightness.name,
                    'view_before_override': beforeOverride,
                    'view_before_fixture': beforeFixture,
                    'view_at_assertion': viewGeometry(),
                    'editor_size': media.size.toString(),
                    'editor_padding': media.padding.toString(),
                    'editor_view_padding': media.viewPadding.toString(),
                    'editor_view_insets': media.viewInsets.toString(),
                    'text_ancestor_constraints': layout.constraints.toString(),
                    'text_ancestor_size': layout.size.toString(),
                    'action_rects': [
                      for (final element in key(action).evaluate())
                        tester
                            .getRect(
                              find.byElementPredicate((e) => e == element),
                            )
                            .toString(),
                    ],
                  };
                  expect(
                    key(action).hitTestable(),
                    findsOneWidget,
                    reason: 'JOURNAL_ACTION_GEOMETRY ${jsonEncode(geometry)}',
                  );
                }
                final label = find.descendant(
                  of: key('journal-ai-request'),
                  matching: find.text('AI 写日记'),
                );
                // Width-based compaction also depends on the active font.
                if (scale > 1.6) expect(label, findsNothing);
                expect(find.byTooltip('AI 写日记'), findsOneWidget);
                if (label.evaluate().isEmpty) {
                  expect(
                    find.descendant(
                      of: key('journal-ai-request'),
                      matching: find.byWidgetPredicate(
                        (w) => w is Icon && w.semanticLabel == 'AI 写日记',
                      ),
                    ),
                    findsOneWidget,
                  );
                }
                expect(
                  MediaQuery.textScalerOf(
                    tester.element(key('journal-ai-request')),
                  ).scale(16),
                  closeTo(16 * scale, .001),
                );
                if (scale == 3.5) {
                  final field = key('journal-text');
                  final original = tester
                      .widget<TextField>(field)
                      .controller!
                      .text;
                  final store = await h.container.read(
                    diaryStoreProvider.future,
                  );
                  // Synthetic stress inset, not a measured system keyboard.
                  tester.view.viewInsets = const FakeViewPadding(bottom: 350);
                  await tester.pumpAndSettle();
                  expect(tester.takeException(), isNull);
                  expect(layout.constraints.maxHeight, lessThan(160));
                  for (final action in actions) {
                    expect(key(action), findsNothing);
                  }
                  expect(
                    tester.widget<TextField>(field).controller!.text,
                    original,
                  );

                  tester.widget<TextField>(field).focusNode!.unfocus();
                  tester.view.viewInsets = const FakeViewPadding();
                  await tester.pumpAndSettle();
                  expect(tester.takeException(), isNull);
                  expect(
                    layout.constraints.maxHeight,
                    greaterThanOrEqualTo(160),
                  );
                  for (final action in actions) {
                    expect(key(action).hitTestable(), findsOneWidget);
                  }
                  expect(
                    tester
                        .widget<IconButton>(key('journal-add-photo'))
                        .onPressed,
                    isNotNull,
                  );
                  expect(
                    MediaQuery.textScalerOf(
                      tester.element(key('journal-ai-request')),
                    ).scale(16),
                    closeTo(16 * scale, .001),
                  );
                  expect(
                    tester.widget<TextField>(field).controller!.text,
                    original,
                  );
                  expect(await store.savedOn(h.clock.day), isEmpty);

                  // Keep the original focused-keyboard save path as well.
                  await tester.showKeyboard(field);
                  tester.view.viewInsets = const FakeViewPadding(bottom: 200);
                  await tester.pumpAndSettle();
                  expect(
                    tester.widget<TextField>(field).focusNode!.hasFocus,
                    isTrue,
                  );
                  expect(tester.takeException(), isNull);
                  for (final action in actions) {
                    expect(key(action).hitTestable(), findsOneWidget);
                  }
                }
              }
              await tapVisible(tester, key('save-journal'));
              expect(find.byType(JournalEditorPage), findsNothing);
              final store = await h.container.read(
                journalStoreProvider(kind).future,
              );
              expect(
                (await store.savedOn(h.clock.day)).single.entry.content,
                contains('合成日常记录'),
              );
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }
}
