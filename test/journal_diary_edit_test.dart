import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'assistant_diary_ui_test.dart' show openDiarySuggestion, tapDiaryControl;
import 'journal_diary_experience_test.dart' show openEditorPreview;
import 'support/ui_harness.dart';
import 'support/sync_fixtures.dart';

Finder control(String key) => find.byKey(ValueKey(key));
const original = '原来的日记';
const edited = '今天有点累，不想加一个积极的结尾。';

Future<void> edit(WidgetTester tester, String prefix, String text) async {
  await tapDiaryControl(tester, control('$prefix-edit'));
  await tester.enterText(control('$prefix-edited-text'), text);
  await tester.pumpAndSettle();
  await tapDiaryControl(tester, control('$prefix-edit'));
}

void main() {
  setUpAll(tzdata.initializeTimeZones);
  for (final chat in [false, true]) {
    final prefix = chat ? 'chat-diary' : 'journal-ai';
    final actionKey = chat ? 'chat-diary-save' : 'journal-ai-use';
    Future<(UiHarness, void Function())> open(WidgetTester tester) async {
      if (chat) {
        final (app, service) = await openDiarySuggestion(
          tester,
          original: original,
          preconsented: true,
        );
        await tapDiaryControl(tester, control('chat-diary-suggested-date'));
        return (app, () => expect(service.requests, hasLength(1)));
      }
      final (app, service) = await openEditorPreview(
        tester,
        original: original,
      );
      return (app, () => expect(service.calls, hasLength(1)));
    }

    testUiWidgets(
      '$prefix changing modes and declining discard retains edits',
      (tester) async {
        final (app, onlyRequest) = await open(tester);
        await edit(tester, prefix, edited);
        expect(control('$prefix-local-edit-status'), findsOneWidget);
        for (final mode in ['追加', '替换', '追加']) {
          await tapDiaryControl(tester, find.text(mode));
          expect(
            tester.widget<Text>(control('$prefix-suggestion')).data,
            mode == '追加' ? '$original\n\n$edited' : edited,
          );
        }
        await Navigator.of(tester.element(control(actionKey))).maybePop();
        await tester.pumpAndSettle();
        expect(find.textContaining('关闭应用后不会保留'), findsOneWidget);
        await tapVisible(tester, control('$prefix-discard-cancel'));
        expect(
          tester.widget<Text>(control('$prefix-suggestion')).data,
          '$original\n\n$edited',
        );
        await tapDiaryControl(
          tester,
          control(chat ? 'chat-diary-cancel' : 'journal-ai-keep'),
        );
        await tapVisible(tester, control('$prefix-discard-cancel'));
        expect(
          tester.widget<Text>(control('$prefix-suggestion')).data,
          '$original\n\n$edited',
        );
        await tapDiaryControl(
          tester,
          control(chat ? 'chat-diary-cancel' : 'journal-ai-keep'),
        );
        await tapVisible(tester, control('$prefix-discard-confirm'));
        final diaries = await app.container.read(diaryStoreProvider.future);
        expect(
          (await diaries.savedOn(app.clock.day))
              .map((row) => row.entry.content),
          chat ? [original] : isEmpty,
        );
        if (!chat) {
          expect(
            tester.widget<TextField>(control('journal-text')).controller!.text,
            original,
          );
        }
        onlyRequest();
      },
    );

    testUiWidgets(
      '$prefix validates without trimming or clearing edited text',
      (tester) async {
        final (_, onlyRequest) = await open(tester);
        await tapDiaryControl(tester, find.text('追加'));
        await tapDiaryControl(tester, control('$prefix-edit'));
        for (final text in ['', ' \n ', '好' * 5001, '好' * 4994]) {
          await tester.enterText(control('$prefix-edited-text'), text);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(control('$prefix-edited-text'))
                .controller!
                .text,
            text,
          );
          expect(control('$prefix-edit-error'), findsOneWidget);
          expect(
            tester.widget<FilledButton>(control(actionKey)).onPressed,
            isNull,
          );
        }
        await tapDiaryControl(tester, find.text('替换'));
        expect(control('$prefix-edit-error'), findsNothing);
        expect(
          tester.widget<FilledButton>(control(actionKey)).onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<TextField>(control('$prefix-edited-text'))
              .controller!
              .text,
          '好' * 4994,
        );
        onlyRequest();
      },
    );

    testUiWidgets(
      '$prefix failed local write retains edited text for explicit retry',
      (tester) async {
        final (app, onlyRequest) = await open(tester);
        await edit(tester, prefix, edited);
        await tapDiaryControl(tester, find.text('替换'));
        await app.database.customStatement(
          "CREATE TRIGGER fail_edited_ui BEFORE UPDATE ON ${chat ? 'assistant_diary_proposals' : 'diary_entries'} BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END",
        );
        await tapDiaryControl(tester, control(actionKey));
        if (chat) await tapVisible(tester, control('chat-diary-confirm-save'));
        expect(tester.widget<Text>(control('$prefix-suggestion')).data, edited);
        final diaries = await app.container.read(diaryStoreProvider.future);
        expect(
          (await diaries.savedOn(app.clock.day))
              .map((row) => row.entry.content),
          chat ? [original] : isEmpty,
        );
        await app.database.customStatement('DROP TRIGGER fail_edited_ui');
        await tapDiaryControl(tester, control(actionKey));
        if (chat) {
          await tapVisible(tester, control('chat-diary-confirm-save'));
          expect(
            (await diaries.savedOn(app.clock.day)).single.entry.content,
            edited,
          );
        } else {
          expect(
            tester.widget<TextField>(control('journal-text')).controller!.text,
            edited,
          );
        }
        onlyRequest();
      },
    );

    for (final identity in [false, true]) {
      testUiWidgets(
        '$prefix protects edits against ${identity ? 'identity' : 'draft'} changes',
        (tester) async {
          final (app, onlyRequest) = await open(tester);
          await edit(tester, prefix, edited);
          await tapDiaryControl(tester, find.text('替换'));
          if (identity) {
            if (chat) await tapDiaryControl(tester, control(actionKey));
            final identities = IdentityStore(app.database);
            await identities.finish(await identities.begin(accountA));
            await tester.pumpAndSettle();
            expect(control('$prefix-suggestion'), findsNothing);
            expect(find.text(edited), findsNothing);
          } else {
            final diaries = await app.container.read(diaryStoreProvider.future);
            final draft = await diaries.beginDraft(app.clock.day);
            await diaries.writeDraft(
              draft.entry.id,
              content: '并发草稿',
              expectedDraftRevision: draft.entry.draftRevision,
            );
            await tapDiaryControl(tester, control(actionKey));
            if (chat) {
              await tapVisible(tester, control('chat-diary-confirm-save'));
            }
            expect(
              tester.widget<Text>(control('$prefix-suggestion')).data,
              edited,
            );
            expect(
              (await diaries.atDay(app.clock.day))!.entry.draftText,
              '并发草稿',
            );
          }
          onlyRequest();
        },
      );
    }

    for (final brightness in Brightness.values) {
      testUiWidgets(
        '$prefix composing text and keyboard dismissal at large size ${brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = const FakeViewPadding(top: 20);
          tester.view.viewPadding = const FakeViewPadding(top: 20);
          tester.platformDispatcher.textScaleFactorTestValue = 3.5;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.view.resetPadding();
            tester.view.resetViewPadding();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.platformDispatcher.clearPlatformBrightnessTestValue();
          });
          final (app, onlyRequest) = await open(tester);
          await tapDiaryControl(tester, find.text('追加'));
          await tapDiaryControl(tester, control('$prefix-edit'));
          tester.view.viewInsets = const FakeViewPadding(bottom: 200);
          await tester.pumpAndSettle();
          final input = control('$prefix-edited-text');
          await tester.showKeyboard(input);
          const text = '合成中文输入👨‍👩‍👧‍👦\n下一行';
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: 4),
              composing: TextRange(start: 2, end: 4),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<TextField>(input).controller!.value.composing,
            const TextRange(start: 2, end: 4),
          );
          expect(tester.widget<TextField>(input).controller!.text, text);
          FocusManager.instance.primaryFocus?.unfocus();
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
          await tapDiaryControl(tester, control('$prefix-edit'));
          expect(
            tester.widget<Text>(control('$prefix-suggestion')).data,
            '$original\n\n$text',
          );
          await tapDiaryControl(tester, find.text('替换'));
          expect(tester.widget<Text>(control('$prefix-suggestion')).data, text);
          await tapDiaryControl(tester, control(actionKey));
          if (chat) {
            await tapDiaryControl(tester, control('chat-diary-abort-save'));
            expect(
              tester.widget<Text>(control('$prefix-suggestion')).data,
              text,
            );
            await tapDiaryControl(tester, control(actionKey));
            await tapDiaryControl(tester, control('chat-diary-confirm-save'));
            final diaries = await app.container.read(diaryStoreProvider.future);
            expect(
              (await diaries.savedOn(app.clock.day)).single.entry.content,
              text,
            );
          } else {
            expect(
              tester
                  .widget<TextField>(control('journal-text'))
                  .controller!
                  .text,
              text,
            );
          }
          expect(tester.takeException(), isNull);
          onlyRequest();
        },
      );
    }
    for (final append in [false, true]) {
      testUiWidgets(
        'local correction before ${chat ? 'save' : 'use'} ${append ? 'append' : 'replace'}',
        (tester) async {
          final prefix = chat ? 'chat-diary' : 'journal-ai';
          final UiHarness app;
          final void Function() onlyInitialRequest;
          if (chat) {
            final (h, service) = await openDiarySuggestion(
              tester,
              original: original,
              preconsented: true,
            );
            app = h;
            onlyInitialRequest = () => expect(service.requests, hasLength(1));
            await tapDiaryControl(tester, control('chat-diary-suggested-date'));
          } else {
            final (h, service) = await openEditorPreview(
              tester,
              original: original,
            );
            app = h;
            onlyInitialRequest = () => expect(service.calls, hasLength(1));
          }
          expect(control('$prefix-edited-text'), findsNothing);
          await edit(tester, prefix, edited);
          await tapDiaryControl(tester, find.text(append ? '追加' : '替换'));
          final expected = append ? '$original\n\n$edited' : edited;
          expect(
            tester.widget<Text>(control('$prefix-suggestion')).data,
            expected,
          );
          final diaries = await app.container.read(diaryStoreProvider.future);
          expect(
            (await diaries.savedOn(app.clock.day))
                .map((row) => row.entry.content),
            chat ? [original] : isEmpty,
          );
          await tapDiaryControl(
            tester,
            control(chat ? 'chat-diary-save' : 'journal-ai-use'),
          );
          if (chat) {
            await tapVisible(tester, control('chat-diary-abort-save'));
            expect(
              tester.widget<Text>(control('$prefix-suggestion')).data,
              expected,
            );
            await tapDiaryControl(tester, control('chat-diary-save'));
            await tapVisible(tester, control('chat-diary-confirm-save'));
            expect(
              (await diaries.savedOn(app.clock.day)).single.entry.content,
              expected,
            );
            expect(
              (await app.database
                      .select(app.database.assistantDiaryProposals)
                      .getSingle())
                  .content,
              '合成新正文',
            );
            await tapDiaryControl(tester, control('chat-diary-undo'));
            await tapVisible(tester, control('chat-diary-confirm-undo'));
            expect(
              (await diaries.savedOn(app.clock.day)).single.entry.content,
              original,
            );
          } else {
            expect(
              tester
                  .widget<TextField>(control('journal-text'))
                  .controller!
                  .text,
              expected,
            );
            expect(await diaries.savedOn(app.clock.day), isEmpty);
            await tapVisible(tester, control('journal-ai-undo'));
            expect(
              tester
                  .widget<TextField>(control('journal-text'))
                  .controller!
                  .text,
              original,
            );
          }
          onlyInitialRequest();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testUiWidgets(
    'chat corrected text survives target date changes and final confirmation cancellation',
    (tester) async {
      final (app, service) = await openDiarySuggestion(
        tester,
        original: original,
        preconsented: true,
      );
      await edit(tester, 'chat-diary', edited);
      await tapDiaryControl(tester, control('chat-diary-suggested-date'));
      await tapDiaryControl(tester, find.text('追加'));
      await tapDiaryControl(tester, control('chat-diary-date'));
      await tester.tap(find.text('8').last);
      await tapVisible(tester, find.text('确定'));
      expect(
        tester.widget<Text>(control('chat-diary-suggestion')).data,
        edited,
      );
      await tapDiaryControl(tester, control('chat-diary-save'));
      await tapVisible(tester, control('chat-diary-abort-save'));
      expect(
        tester.widget<Text>(control('chat-diary-suggestion')).data,
        edited,
      );
      await tapDiaryControl(tester, control('chat-diary-save'));
      await tapVisible(tester, control('chat-diary-confirm-save'));
      final diaries = await app.container.read(diaryStoreProvider.future);
      expect(
        (await diaries.atDay(app.clock.day.addDays(-1)))!.entry.content,
        edited,
      );
      expect((await diaries.atDay(app.clock.day))!.entry.content, original);
      expect(service.requests, hasLength(1));
    },
  );
}
