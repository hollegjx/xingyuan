// R16 adapts the handed-off CO40 journeys (source 6ca2c09d); AI1 files stay intact.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/data/sync/identity_store.dart';
import 'package:habit_checkin/data/sync/sync_identity.dart';
import 'package:habit_checkin/features/assistant/assistant_providers.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/journal/data/journal_photo_files.dart';
import 'package:habit_checkin/features/journal/data/local_journal_store.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/journal_providers.dart';
import 'package:habit_checkin/features/journal/presentation/journal_photo_view.dart';
import 'package:habit_checkin/features/records/data/record_photo.dart';
import 'package:habit_checkin/shared/local_date.dart';
import 'package:image/image.dart' as img;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:uuid/uuid.dart';

import 'journal_diary_capture_test.dart'
    show captureDirectory, captureFont, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart' show configure, key;
import 'support/journal_ai_service.dart';
import 'support/record_fixtures.dart';
import 'support/test_assistant_service.dart';
import 'support/ui_harness.dart';

const _tested = String.fromEnvironment('R16_PRODUCT_SOURCE');
const _testSource = String.fromEnvironment('R16_TEST_SOURCE');
const _source = 'test/journal_photo_retry_test.dart';
const _saved = '合成：已经保存的照片记录。';
const _draft = '合成：尚未保存的照片说明。';

enum _Scenario {
  ordinary,
  narrow,
  repeated,
  back,
  identity,
  owner,
  path,
  length,
  hash,
  decode,
}

class _ReadProbe extends JournalPhotoFiles {
  _ReadProbe(super.root, super.owner, super.kind, {required this.failOnce});

  final bool failOnce;
  final releaseFailure = Completer<void>();
  final releaseRetry = Completer<void>();
  _Scenario scenario = _Scenario.ordinary;
  final events = <Map<String, Object?>>[];
  int reads = 0;

  @override
  Future<Uint8List> read(JournalPhoto photo) async {
    final attempt = ++reads;
    events.add({'attempt': attempt, 'state': 'started', 'photo': photo.id});
    if (failOnce && attempt == 1) {
      await releaseFailure.future;
      events.add({'attempt': attempt, 'state': 'injected-read-failure'});
      throw const FileSystemException('SYNTHETIC temporary read failure');
    }
    if (failOnce && attempt == 2) {
      await releaseRetry.future;
      if (scenario == _Scenario.repeated) {
        events.add({'attempt': attempt, 'state': 'injected-read-failure'});
        throw const FileSystemException('SYNTHETIC second read failure');
      }
      // Only the read input is corrupted; stored metadata and files stay intact.
      if ([
        _Scenario.owner,
        _Scenario.path,
        _Scenario.length,
        _Scenario.hash,
      ].contains(scenario)) {
        photo = JournalPhoto(
          id: photo.id,
          entryId: photo.entryId,
          owner: scenario == _Scenario.owner
              ? 'account:55555555-5555-4555-8555-555555555555'
              : photo.owner,
          filename: scenario == _Scenario.path
              ? '../${photo.filename}'
              : photo.filename,
          width: photo.width,
          height: photo.height,
          byteCount: photo.byteCount + (scenario == _Scenario.length ? 1 : 0),
          sha256: scenario == _Scenario.hash ? '0' * 64 : photo.sha256,
          savedPosition: photo.savedPosition,
          draftPosition: photo.draftPosition,
          createdAt: photo.createdAt,
        );
      }
    }
    // Keep production ownership, filename, size and digest verification intact.
    late final Uint8List bytes;
    try {
      bytes = await super.read(photo);
    } catch (error) {
      events.add({
        'attempt': attempt,
        'state': 'verified-rejection',
        'type': error.runtimeType.toString(),
      });
      rethrow;
    }
    events.add({
      'attempt': attempt,
      'state': 'verified-success',
      'sha256': sha256.convert(bytes).toString(),
    });
    return bytes;
  }
}

Future<Map<String, Object?>> _rows(UiHarness h) async => {
  for (final table in [
    'diary_entries',
    'diary_photos',
    'quick_notes',
    'quick_note_photos',
    'goals',
    'check_ins',
    'identity_states',
  ])
    table: (await h.database.customSelect('SELECT * FROM $table').get())
        .map((row) => row.data)
        .toList(),
};

Map<String, String> _files(Directory root) => {
  for (final file in root.listSync(recursive: true).whereType<File>())
    file.path.substring(root.path.length + 1): sha256
        .convert(file.readAsBytesSync())
        .toString(),
};

Future<void> _wait(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue, reason: 'Bounded local read/image completion');
  await pumpWaiting(tester);
}

Finder _full() => find.byWidgetPredicate(
  (widget) => widget is JournalPhotoView && widget.full,
);
bool _decoded() => find
    .descendant(of: _full(), matching: find.byType(RawImage))
    .evaluate()
    .any((e) => (e.widget as RawImage).image != null);

List<double> _rect(Rect value) => [
  value.left,
  value.top,
  value.right,
  value.bottom,
];

Map<String, Object?> _textGeometry(WidgetTester tester, String value) {
  final label = find.text(value);
  final paragraph = tester.renderObject<RenderParagraph>(label);
  final origin = paragraph.localToGlobal(Offset.zero);
  final bounds = origin & paragraph.size;
  final glyphs = <List<double>>[];
  for (var i = 0; i < value.length; i++) {
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: i, extentOffset: i + 1),
    );
    expect(boxes, isNotEmpty, reason: '$value character $i has layout');
    for (final box in boxes) {
      final glyph = box.toRect().shift(origin);
      expect(glyph.width, greaterThan(0));
      expect(glyph.left, greaterThanOrEqualTo(bounds.left - 0.01));
      expect(glyph.right, lessThanOrEqualTo(bounds.right + 0.01));
      glyphs.add(_rect(glyph));
    }
  }
  return {
    'text': value,
    'paragraph': _rect(bounds),
    'glyphs': glyphs,
    'fontSize': paragraph.text.style?.fontSize,
    'scaled14': paragraph.textScaler.scale(14),
  };
}

Future<JournalSnapshot> _seed(
  WidgetTester tester,
  LocalJournalStore store,
  JournalSnapshot value,
  String text, {
  _ReadProbe? files,
  SanitizedRecordPhoto? image,
}) async {
  value = await store.writeDraft(
    value.entry.id,
    content: text,
    expectedDraftRevision: value.entry.draftRevision,
  );
  if (files != null && image != null) {
    final photo = (await tester.runAsync(() => files.write(image)))!;
    value = await store.addPhoto(
      value.entry.id,
      photo: photo,
      expectedDraftRevision: value.entry.draftRevision,
    );
  }
  value = await store.save(
    value.entry.id,
    operationId: const Uuid().v4(),
    expectedRevision: value.entry.revision,
    expectedDraftRevision: value.entry.draftRevision,
  );
  if (files == null) return value;
  value = store is LocalDiaryStore
      ? await store.beginDraft(LocalDate(2026, 10, 27))
      : await (store as LocalQuickNoteStore).beginDraft(id: value.entry.id);
  return store.writeDraft(
    value.entry.id,
    content: _draft,
    expectedDraftRevision: value.entry.draftRevision,
  );
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    if (captureDirectory.isNotEmpty) {
      expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(_tested), isTrue);
      expect(RegExp(r'^[a-f0-9]{40}$').hasMatch(_testSource), isTrue);
      expect(captureDirectory.startsWith('/tmp/xingyuan-ai2-r16-'), isTrue);
    }
    await loadDiaryCaptureFont();
    if (captureFont.isEmpty) return;
    final fontBytes = ByteData.sublistView(
      await File(captureFont).readAsBytes(),
    );
    for (final family in ['CupertinoSystemText', 'CupertinoSystemDisplay']) {
      await (FontLoader(family)..addFont(Future.value(fontBytes))).load();
    }
  });

  final cases = [
    for (final kind in JournalKind.values)
      (kind: kind, scenario: _Scenario.ordinary),
    for (final scenario in _Scenario.values.skip(1))
      (kind: JournalKind.diary, scenario: scenario),
  ];
  for (final sample in cases) {
    final kind = sample.kind;
    final scenario = sample.scenario;
    final label = '${scenario.name}-${kind.name}';
    testUiWidgets('R16 private photo $label', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final narrow = scenario == _Scenario.narrow;
      configure(
        tester,
        narrow ? const Size(320, 568) : const Size(390, 844),
        narrow ? 4 : 1,
        narrow ? Brightness.dark : Brightness.light,
      );
      final semantics = tester.ensureSemantics();
      final h = UiHarness()..clock.setDay(2026, 10, 27, hour: 15);
      final ai = SyntheticJournalAi();
      final picker = StubRecordPhotoPicker();
      final boundary = GlobalKey();
      final records = <Map<String, Object?>>[];
      final images = <Map<String, Object?>>[];
      final root = Directory.systemTemp.createTempSync(
        'xingyuan-ai2-r16-photos-',
      );
      debugPrint('R16_STAGE ${kind.name} root-created');
      final files = {
        for (final k in JournalKind.values)
          k: _ReadProbe(root, 'guest', k, failOnce: k == kind),
      };
      final probe = files[kind]!;
      probe.scenario = scenario;
      Map<String, Object?>? before;
      Map<String, String>? beforeFiles;
      var completed = false;
      Map<String, Object?>? identityAfter;
      TextEditingController? editor;
      final geometry = <Map<String, Object?>>[];
      final shouldCapture = [
        _Scenario.ordinary,
        _Scenario.narrow,
        _Scenario.decode,
      ].contains(scenario);

      Future<void> record(String state, {bool capture = false}) async {
        final rows = await _rows(h);
        final hashes = _files(root);
        expect(
          rows,
          identityAfter ?? before,
          reason: '$state preserves six tables and identity',
        );
        expect(hashes, beforeFiles, reason: '$state preserves photo bytes');
        final failureIcons = find.byWidgetPredicate(
          (w) => w is Icon && w.semanticLabel == '照片无法读取',
        );
        records.add({
          'state': state,
          'reads': probe.reads,
          'rows': rows,
          'files': hashes,
          'visibleFailureText': find.text('照片无法读取').evaluate().length,
          'semanticFailureIcons': failureIcons.evaluate().length,
          'visibleRetry': find.textContaining('重试').evaluate().length,
          'decodedFullImage': _decoded(),
          'editing':
              key('journal-text').evaluate().isEmpty &&
                  _full().evaluate().isEmpty
              ? null
              : {
                  'text': editor?.text,
                  'selection': [
                    editor?.selection.baseOffset,
                    editor?.selection.extentOffset,
                  ],
                  'composing': [
                    editor?.value.composing.start,
                    editor?.value.composing.end,
                  ],
                },
          'viewport': [
            tester.view.physicalSize.width,
            tester.view.physicalSize.height,
          ],
        });
        if (!capture || !shouldCapture || captureDirectory.isEmpty) return;
        await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List();
            expect(image.width, tester.view.physicalSize.width.toInt());
            expect(image.height, tester.view.physicalSize.height.toInt());
            final name = '$label-$state.png';
            await Directory(captureDirectory).create(recursive: true);
            expect(File('$captureDirectory/$name').existsSync(), isFalse);
            await File('$captureDirectory/$name').writeAsBytes(bytes);
            images.add({
              'file': name,
              'sha256': sha256.convert(bytes).toString(),
              'width': image.width,
              'height': image.height,
              'state': state,
            });
          } finally {
            image.dispose();
          }
        });
      }

      try {
        await h.mount(
          tester,
          journalAiService: ai,
          assistantCredentials: ConversationTestCredentials(),
          recordPhotoPicker: picker,
          journalPhotoFiles: files,
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        debugPrint('R16_STAGE ${kind.name} mounted');
        final day = h.clock.day;
        final goal = await h.repository.create(
          const GoalDraft(title: '合成照片对照目标', kind: GoalKind.habit),
        );
        await h.repository.setCompleted(goal, true, expectedDay: day);
        final diary = await h.container.read(diaryStoreProvider.future);
        final notes = await h.container.read(quickNoteStoreProvider.future);
        final targets = <JournalKind, JournalSnapshot>{};
        final synthetic = (await tester.runAsync(() async {
          if (scenario == _Scenario.decode) {
            // Valid integrity metadata for synthetic non-image bytes, bypassing
            // sanitization only to reach the existing decoder error branch.
            return SanitizedRecordPhoto(
              Uint8List.fromList(List.filled(128, 65)),
              120,
              80,
            );
          }
          final bitmap = img.Image(width: 120, height: 80);
          for (var y = 0; y < 80; y++) {
            for (var x = 0; x < 120; x++) {
              final left = x < 60;
              bitmap.setPixelRgb(
                x,
                y,
                left ? 230 : 30,
                y < 40 ? 180 : 70,
                left ? 40 : 210,
              );
            }
          }
          return sanitizeRecordPhoto(img.encodePng(bitmap));
        }))!;
        debugPrint('R16_STAGE ${kind.name} sanitized');
        await _seed(
          tester,
          diary,
          await diary.beginDraft(LocalDate(2026, 10, 26)),
          '合成：无关日记。',
        );
        await _seed(
          tester,
          notes,
          await notes.beginDraft(day: LocalDate(2026, 10, 26)),
          '合成：无关随手记。',
        );
        targets[JournalKind.diary] = await _seed(
          tester,
          diary,
          await diary.beginDraft(day),
          _saved,
          files: files[JournalKind.diary],
          image: synthetic,
        );
        targets[JournalKind.quickNote] = await _seed(
          tester,
          notes,
          await notes.beginDraft(day: day),
          _saved,
          files: files[JournalKind.quickNote],
          image: synthetic,
        );
        debugPrint('R16_STAGE ${kind.name} seeded');
        final target = targets[kind]!;
        final photo = target.draftPhotos.single;
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byTooltip('我的'));
        await tapVisible(
          tester,
          key(kind == JournalKind.diary ? 'my-diary' : 'my-quick-notes'),
        );
        await tapVisible(
          tester,
          key('journal-entry-${target.entry.id}'),
          settle: false,
        );
        await _wait(tester, () => key('journal-text').evaluate().isNotEmpty);
        debugPrint('R16_STAGE ${kind.name} editor-opened');
        final text = tester.widget<TextField>(key('journal-text')).controller!;
        editor = text;
        text.selection = const TextSelection(baseOffset: 3, extentOffset: 6);
        final editing = text.value;
        before = await _rows(h);
        beforeFiles = _files(root);
        expect(beforeFiles, hasLength(2));
        for (final entry in targets.entries) {
          final metadata = entry.value.draftPhotos.single;
          final file = File(
            '${files[entry.key]!.directory.path}/${metadata.filename}',
          );
          expect(file.lengthSync(), metadata.byteCount);
          expect(
            sha256.convert(file.readAsBytesSync()).toString(),
            metadata.sha256,
          );
        }
        expect(editing.text, _draft);
        final thumbnailBefore = tester.getSize(
          key('journal-photo-${photo.id}'),
        );
        expect(thumbnailBefore, const Size(92, 92));
        await tapVisible(
          tester,
          key('journal-photo-${photo.id}'),
          settle: false,
        );
        await _wait(
          tester,
          () => _full().evaluate().isNotEmpty && probe.reads == 1,
        );

        final shownPhoto = tester.widget<JournalPhotoView>(_full()).photo;
        final provider = journalPhotoBytesProvider((
          kind: kind,
          photo: shownPhoto,
        ));
        final otherKind = JournalKind.values.firstWhere((k) => k != kind);
        final otherQuery = journalPhotoBytesProvider((
          kind: otherKind,
          photo: targets[otherKind]!.draftPhotos.single,
        ));
        final otherSubscription = h.container.listen(otherQuery, (_, _) {});
        addTearDown(otherSubscription.close);
        await _wait(tester, () => h.container.read(otherQuery).hasValue);
        final otherBytes = h.container.read(otherQuery).requireValue;
        expect(files[otherKind]!.reads, 1);

        Future<void> feedback(String message, String state) async {
          expect(find.text(message), findsOneWidget);
          expect(find.byType(InteractiveViewer), findsNothing);
          expect(
            find.textContaining('SYNTHETIC temporary read failure'),
            findsNothing,
          );
          expect(find.textContaining(root.path), findsNothing);
          await record(state, capture: true);
          final scroll = find.descendant(
            of: _full(),
            matching: find.byType(SingleChildScrollView),
          );
          final viewport = tester.getRect(scroll);
          final initial = tester.getRect(find.text(message));
          if (!viewport.contains(initial.topLeft) ||
              !viewport.contains(initial.bottomRight)) {
            await tester.ensureVisible(find.text(message));
            await pumpWaiting(tester);
            await record('$state-message-scrolled', capture: true);
          }
          final evidence = _textGeometry(tester, message);
          for (final box in evidence['glyphs']! as List<List<double>>) {
            expect(box[0], greaterThanOrEqualTo(viewport.left - 0.01));
            expect(box[1], greaterThanOrEqualTo(viewport.top - 0.01));
            expect(box[2], lessThanOrEqualTo(viewport.right + 0.01));
            expect(box[3], lessThanOrEqualTo(viewport.bottom + 0.01));
          }
          geometry.add({
            'state': state,
            'viewport': _rect(viewport),
            'initial': _rect(initial),
            ...evidence,
          });
        }

        await feedback('正在读取照片', 'loading');
        probe.releaseFailure.complete();
        await _wait(tester, () => h.container.read(provider).hasError);
        await feedback('照片无法读取', 'read-failure');
        await tester.ensureVisible(find.text('重试'));
        await pumpWaiting(tester);
        expect(find.text('重试').hitTestable(), findsOneWidget);
        final action = find.ancestor(
          of: find.text('重试'),
          matching: find.byType(OutlinedButton),
        );
        final actionRect = tester.getRect(action);
        expect(actionRect.height, greaterThanOrEqualTo(44));
        expect(actionRect.width, greaterThanOrEqualTo(44));
        final actionSemantics = tester
            .getSemantics(find.text('重试'))
            .getSemanticsData();
        expect(actionSemantics.label, '重试');
        expect(actionSemantics.flagsCollection.isButton, isTrue);
        expect(actionSemantics.hasAction(ui.SemanticsAction.tap), isTrue);
        geometry.add({
          'state': 'retry-action',
          'rect': _rect(actionRect),
          'hit': true,
          'button': true,
          'tap': true,
          ..._textGeometry(tester, '重试'),
        });
        await record('retry-action', capture: narrow);
        final retry = tester.widget<OutlinedButton>(action).onPressed!;
        await tester.tap(find.text('重试'));
        for (var i = 0; i < 4; i++) {
          retry();
        }
        expect(h.container.read(provider).isLoading, isTrue);
        await _wait(tester, () => probe.reads == 2);
        await feedback('正在读取照片', 'retry-loading');
        expect(find.text('重试'), findsNothing);
        await tester.pump(const Duration(seconds: 2));
        expect(
          probe.reads,
          2,
          reason: 'No duplicate or automatic read while held',
        );

        if (scenario == _Scenario.back) {
          await tapVisible(tester, find.byType(BackButton), settle: false);
          await pumpWaiting(tester);
          expect(_full(), findsNothing);
          expect(text.value, editing);
          await record('pending-back');
          probe.releaseRetry.complete();
          await _wait(tester, () => h.container.read(provider).hasValue);
          expect(_full(), findsNothing);
          expect(text.value, editing);
          await record('back-completed');
        } else if (scenario == _Scenario.identity) {
          final held = h.container.listen(provider, (_, _) {});
          addTearDown(held.close);
          final identities = IdentityStore(h.database);
          final targetOwner = SyncIdentity.account(
            '55555555-5555-4555-8555-555555555555',
          );
          final transition = await identities.begin(targetOwner);
          identityAfter = await _rows(h);
          expect(
            {...identityAfter}..remove('identity_states'),
            {...before}..remove('identity_states'),
          );
          final previous = (before['identity_states']! as List).single as Map;
          expect((identityAfter['identity_states']! as List).single, {
            ...previous,
            'target_owner': targetOwner.owner,
            'generation': (previous['generation'] as int) + 1,
          });
          await _wait(
            tester,
            () => find.text('身份已变化或不可用。').evaluate().isNotEmpty,
          );
          expect(_full(), findsNothing);
          expect(key('journal-text'), findsNothing);
          probe.releaseRetry.complete();
          await _wait(
            tester,
            () =>
                !h.container.read(provider).isLoading &&
                h.container.read(provider).hasError,
          );
          expect(h.container.read(provider).error, isA<StaleIdentity>());
          expect(_decoded(), isFalse);
          await record('identity-rejected');
          await identities.finish(transition);
          identityAfter = await _rows(h);
          expect((identityAfter['identity_states']! as List).single, {
            ...previous,
            'owner': targetOwner.owner,
            'target_owner': null,
            'generation': (previous['generation'] as int) + 1,
          });
          expect(
            {...identityAfter}..remove('identity_states'),
            {...before}..remove('identity_states'),
          );
          await pumpWaiting(tester);
          expect(_full(), findsNothing);
          expect(key('journal-text'), findsNothing);
          await record('identity-changed');
        } else {
          probe.releaseRetry.complete();
          if (scenario == _Scenario.repeated ||
              [
                _Scenario.owner,
                _Scenario.path,
                _Scenario.length,
                _Scenario.hash,
              ].contains(scenario)) {
            await _wait(
              tester,
              () =>
                  !h.container.read(provider).isLoading &&
                  h.container.read(provider).hasError,
            );
            if (scenario != _Scenario.repeated) {
              expect(
                h.container.read(provider).error,
                isA<RecordPhotoException>(),
              );
              expect(probe.events.last['state'], 'verified-rejection');
            }
            await feedback('照片无法读取', 'retry-failed');
            await tester.pump(const Duration(seconds: 3));
            expect(probe.reads, 2, reason: 'Failure has no automatic retry');
            await record('no-auto-retry');
            await tapVisible(tester, find.text('重试'), settle: false);
          }
          if (scenario == _Scenario.decode) {
            await _wait(
              tester,
              () => find.text('照片无法显示').evaluate().isNotEmpty,
            );
            expect(h.container.read(provider).hasValue, isTrue);
            expect(find.text('重试'), findsNothing);
            expect(_decoded(), isFalse);
            await feedback('照片无法显示', 'decode-failed');
          } else {
            await _wait(tester, _decoded);
            await record('success-full', capture: true);
            final image = tester
                .widget<RawImage>(
                  find.descendant(of: _full(), matching: find.byType(RawImage)),
                )
                .image!;
            expect([image.width, image.height], [120, 80]);
            final viewer = tester.widget<InteractiveViewer>(
              find.byType(InteractiveViewer),
            );
            expect([viewer.minScale, viewer.maxScale], [1, 4]);
            expect(viewer.panEnabled && viewer.scaleEnabled, isTrue);
            if (scenario == _Scenario.ordinary &&
                kind == JournalKind.quickNote) {
              final center = tester.getCenter(find.byType(InteractiveViewer));
              final a = await tester.startGesture(
                center - const Offset(20, 0),
                pointer: 1,
              );
              final b = await tester.startGesture(
                center + const Offset(20, 0),
                pointer: 2,
              );
              await tester.pump();
              await a.moveTo(center - const Offset(45, 0));
              await b.moveTo(center + const Offset(45, 0));
              await tester.pump();
              await a.up();
              await b.up();
              await tester.pumpAndSettle();
              final transform = tester.widget<Transform>(
                find.descendant(
                  of: find.byType(InteractiveViewer),
                  matching: find.byType(Transform),
                ),
              );
              final scale = transform.transform.getMaxScaleOnAxis();
              expect(scale, greaterThan(1.1));
              expect(scale, lessThanOrEqualTo(4));
              geometry.add({'state': 'pinch-zoom', 'scale': scale});
              await record('zoomed-full', capture: true);
            }
          }
          expect(text.value, editing);
          final reads = probe.reads;
          await goBack(tester);
          expect(text.value, editing);
          expect(probe.reads, reads);
          final thumb = find.byWidgetPredicate(
            (w) => w is JournalPhotoView && !w.full && w.photo.id == photo.id,
          );
          await tester.ensureVisible(thumb);
          await tester.pumpAndSettle();
          expect(tester.getSize(thumb), thumbnailBefore);
          expect(
            key('journal-photo-${photo.id}').hitTestable(),
            findsOneWidget,
          );
          expect(find.text('重试'), findsNothing);
          final raw = find.descendant(
            of: thumb,
            matching: find.byType(RawImage),
          );
          expect(
            raw,
            scenario == _Scenario.decode ? findsNothing : findsOneWidget,
          );
          if (scenario != _Scenario.decode) {
            expect(tester.widget<RawImage>(raw).image, isNotNull);
          }
          await record('returned-thumbnail', capture: narrow);
        }
        expect(
          files[otherKind]!.reads,
          1,
          reason: 'Retry leaves the unrelated provider untouched',
        );
        expect(
          identical(h.container.read(otherQuery).requireValue, otherBytes),
          isTrue,
        );
        expect(ai.calls, isEmpty);
        expect(picker.calls, 0);
        expect(h.container.exists(assistantServiceProvider), isFalse);
        expect(h.container.exists(pairingControllerProvider), isFalse);
        expect(h.container.exists(chatControllerProvider), isFalse);
        expect(tester.takeException(), isNull);
        completed = true;
      } finally {
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
        if (captureDirectory.isNotEmpty) {
          await tester.runAsync(() async {
            await Directory(captureDirectory).create(recursive: true);
            expect(File('$captureDirectory/$label.json').existsSync(), isFalse);
            await File('$captureDirectory/$label.json').writeAsString(
              const JsonEncoder.withIndent('  ').convert({
                'tested': _tested,
                'testSource': _testSource,
                'source': _source,
                'sourceSha256': sha256
                    .convert(File(_source).readAsBytesSync())
                    .toString(),
                'font': captureFont,
                'fontSha256': captureFont.isEmpty
                    ? null
                    : sha256
                          .convert(File(captureFont).readAsBytesSync())
                          .toString(),
                'kind': kind.name,
                'scenario': scenario.name,
                'runtimeSha256': {
                  for (final path in [
                    'lib/features/journal/presentation/journal_photo_view.dart',
                    'lib/features/journal/journal_providers.dart',
                    'lib/shared/local_identity_boundary.dart',
                    'lib/features/journal/data/journal_photo_files.dart',
                    'lib/features/records/data/record_photo_files.dart',
                  ])
                    path: sha256
                        .convert(File(path).readAsBytesSync())
                        .toString(),
                },
                'root': root.path,
                'completed': completed,
                'readEvents': probe.events,
                'before': before,
                'beforeFiles': beforeFiles,
                'identityAfter': identityAfter,
                'geometry': geometry,
                'states': records,
                'images': images,
                'aiCalls': ai.calls.length,
                'pickerCalls': picker.calls,
                'platform': 'iOS-target widget',
                'keyboardInset': 0,
                'dpr': 1,
                'scale': narrow ? 4 : 1,
                'theme': narrow ? 'dark' : 'light',
              }),
            );
          });
        }
        debugPrint(
          'R16_RESULT $label completed=$completed reads=${probe.reads}',
        );
      }
    });
  }
}
