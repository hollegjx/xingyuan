import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart' show loadDiaryCaptureFont;
import 'support/journal_fixtures.dart';
import 'support/record_fixtures.dart';
import 'support/ui_harness.dart';

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
  });
  Finder key(String name) => find.byKey(ValueKey(name));
  for (final kind in JournalKind.values) {
    Future<UiHarness> mount(
      WidgetTester tester,
      StubRecordPhotoPicker picker,
    ) async {
      final h = UiHarness();
      await h.mount(
        tester,
        journalPhotoFiles: {
          for (final item in JournalKind.values)
            item: MemoryJournalPhotoFiles(item),
        },
        recordPhotoPicker: picker,
      );
      await tapVisible(
        tester,
        key(kind == JournalKind.quickNote ? 'entry-quick-note' : 'entry-diary'),
      );
      return h;
    }

    testUiWidgets(
      '${kind.name} validates boundaries and five saves stay local',
      (tester) async {
        final h = await mount(tester, StubRecordPhotoPicker());
        final store = await h.container.read(journalStoreProvider(kind).future);
        await tapVisible(tester, key('save-journal'));
        expect(await store.savedOn(h.clock.day), isEmpty);
        expect(find.text('请写下文字或添加照片'), findsOneWidget);
        final text = '${'🙂' * (kind.maxLength - 2)}\n中';
        expect(text.characters.length, kind.maxLength);
        expect('$text文'.characters.length, kind.maxLength + 1);
        await tester.enterText(key('journal-text'), '$text文');
        await tester.pumpAndSettle();
        await tapVisible(tester, key('save-journal'));
        expect(await store.savedOn(h.clock.day), isEmpty);
        expect(find.text('正文最多 ${kind.maxLength} 字'), findsOneWidget);
        expect(key('journal-error'), findsNothing);
        expect(
          (await store.onDay(h.clock.day)).single.entry.draftText,
          '$text文',
        );
        await tester.enterText(key('journal-text'), text);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(key('journal-text')).controller!.text,
          text,
          reason: 'The replacement must reach the editor before saving',
        );
        expect((await store.onDay(h.clock.day)).single.entry.draftText, text);
        expect(await store.savedOn(h.clock.day), isEmpty);
        final save = key('save-journal');
        expect(save.hitTestable(), findsOneWidget);
        final position = tester.getCenter(save);
        for (var i = 0; i < 5; i++) {
          await tester.tapAt(position);
        }
        await tester.pumpAndSettle();
        expect(key('journal-text'), findsNothing);
        final saved = await store.savedOn(h.clock.day);
        expect(saved, hasLength(1));
        expect(saved.single.entry.content, text);
        expect(saved.single.entry.revision, 1);
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
        expect(h.container.exists(chatControllerProvider), isFalse);
      },
    );

    testUiWidgets(
      '${kind.name} photo cancel, denied, invalid and three-photo cap',
      (tester) async {
        final picker = StubRecordPhotoPicker();
        final h = await mount(tester, picker);
        final store = await h.container.read(journalStoreProvider(kind).future);
        const text = 'SYNTHETIC photo failure must retain draft';
        await tester.enterText(key('journal-text'), text);
        await tester.pumpAndSettle();
        await tapVisible(tester, key('journal-add-photo'));
        expect(picker.calls, 1);
        expect((await store.onDay(h.clock.day)).single.draftPhotos, isEmpty);
        picker.onPick = () async =>
            throw const RecordPhotoException('未获得相机权限，仍可写文字或从相册选照片');
        await tapVisible(tester, key('journal-take-photo'));
        expect(find.text('未获得相机权限，仍可写文字或从相册选照片'), findsOneWidget);
        expect((await store.onDay(h.clock.day)).single.entry.draftText, text);
        picker.onPick = () async => Uint8List.fromList([1, 2, 3]);
        await tapVisible(tester, key('journal-add-photo'));
        await waitForPhotoAction(tester);
        expect(key('journal-error'), findsOneWidget);
        expect((await store.onDay(h.clock.day)).single.draftPhotos, isEmpty);
        picker.onPick = () async =>
            img.encodePng(img.Image(width: 40, height: 30));
        for (var count = 1; count <= 3; count++) {
          await tapVisible(tester, key('journal-add-photo'));
          await waitForPhotoAction(tester, photos: count);
          expect(find.byTooltip('移除照片'), findsNWidgets(count));
        }
        expect(
          tester.widget<IconButton>(key('journal-add-photo')).onPressed,
          isNull,
        );
        expect(
          tester.widget<IconButton>(key('journal-take-photo')).onPressed,
          isNull,
        );
        expect(picker.calls, 6);
        await tapVisible(tester, key('save-journal'));
        final saved = (await store.savedOn(h.clock.day)).single;
        expect(saved.entry.content, text);
        expect(saved.savedPhotos, hasLength(3));
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
      },
    );
  }
}

Future<void> waitForPhotoAction(WidgetTester tester, {int photos = 0}) async {
  final save = find.byKey(const ValueKey('save-journal'));
  int decodedPhotos() => find
      .byType(RawImage)
      .evaluate()
      .where((element) => (element.widget as RawImage).image != null)
      .length;
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    if (tester.widget<TextButton>(save).onPressed != null &&
        decodedPhotos() == photos) {
      break;
    }
  }
  expect(
    decodedPhotos(),
    photos,
    reason: 'Wait for image decoding before settling loading indicators',
  );
  await tester.pumpAndSettle();
  expect(tester.widget<TextButton>(save).onPressed, isNotNull);
}
