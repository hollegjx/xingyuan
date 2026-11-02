import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/assistant/data/device_credential_store.dart';
import 'package:habit_checkin/features/companion/companion_providers.dart';
import 'package:habit_checkin/features/companion/presentation/sharing_page.dart';
import 'package:habit_checkin/features/goals/domain/goal.dart';
import 'package:habit_checkin/features/goals/presentation/goal_management_page.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_list_page.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:habit_checkin/shared/ui/sparkle.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:xingyuan_core/xingyuan_core.dart';

import 'journal_diary_capture_test.dart' as pixels;
import 'support/sharing_fixtures.dart';
import 'support/ui_harness.dart';
import 'today_c49_test.dart' show viewport;

class _Credentials extends DeviceCredentialStore {
  @override
  Future<String?> read() async => 'a' * 43;
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await pixels.loadDiaryCaptureFont();
  });
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 3.5]) {
      testWidgets('C52 centered section ${brightness.name} ${scale}x', (
        tester,
      ) async {
        viewport(tester, brightness, scale);
        final boundary = GlobalKey();
        var taps = 0;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: buildXyTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(320, 568),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: SectionLabel(
                      '最近的分享',
                      trailing: TextButton(
                        key: const ValueKey('open-sharing'),
                        onPressed: () => taps++,
                        child: const Text('全部动态'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final section = find.byType(SectionLabel);
        final titleWrap = find.descendant(
          of: section,
          matching: find.byType(Wrap),
        );
        final action = find.byKey(const ValueKey('open-sharing'));
        if (scale == 1) {
          final row = tester.widget<Row>(
            find.descendant(of: section, matching: find.byType(Row)),
          );
          expect(row.crossAxisAlignment, CrossAxisAlignment.center);
          expect(
            tester.getCenter(titleWrap).dy,
            closeTo(tester.getCenter(action).dy, .01),
          );
        } else {
          expect(
            find.descendant(
              of: section,
              matching: find.byKey(const ValueKey('section-label-stacked')),
            ),
            findsOneWidget,
          );
          expect(
            tester.getRect(action).top,
            greaterThanOrEqualTo(tester.getRect(titleWrap).bottom),
          );
        }
        expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
        await tapVisible(tester, action);
        expect(taps, 1);
        if (pixels.captureFont.isNotEmpty) {
          await tester.ensureVisible(find.text('最近的分享'));
          await tester.pumpAndSettle();
          await pixels.capture(
            tester,
            boundary,
            'c52-${brightness.name}-$scale',
            const Size(320, 568),
            text: find.text('最近的分享'),
            expectedText: '最近的分享',
            firstLineOnly: true,
          );
        }
        expect(tester.takeException(), isNull);
      });
      testUiWidgets('C50 My footer and icons ${brightness.name} ${scale}x', (
        tester,
      ) async {
        viewport(tester, brightness, scale);
        final app = UiHarness();
        final boundary = GlobalKey();
        await app.mount(
          tester,
          wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
        );
        await tapVisible(tester, find.byTooltip('我的'));
        const privacy =
            '随手记和日记只存在这台手机上。用 AI 润色时只发送这一条；生成日记时发送当天的打卡和随手记文字。照片从不发送。';
        final group = tester
            .widgetList<XyGroup>(find.byType(XyGroup))
            .singleWhere(
              (group) => group.children.any(
                (child) => child.key == const ValueKey('my-goals'),
              ),
            );
        expect(group.header, '记录');
        expect(group.footer, privacy);
        expect(group.margin, const EdgeInsets.only(top: 8));
        expect(find.text('我的星愿'), findsNothing);
        expect(find.text(privacy), findsOneWidget);
        for (final key in ['my-goals', 'my-diary', 'my-quick-notes']) {
          final row = find.byKey(ValueKey(key));
          final iconTile = find.descendant(
            of: row,
            matching: find.byType(XyIconTile),
          );
          final tile = tester.widget<XyIconTile>(iconTile);
          expect(
            tile.color,
            Theme.of(tester.element(iconTile)).colorScheme.primary,
          );
          final icon = tester.widget<Icon>(
            find.descendant(of: iconTile, matching: find.byType(Icon)),
          );
          expect(icon.color, tile.color);
          expect(icon.size, 21);
          expect(tester.getSize(iconTile), const Size(30, 30));
        }
        if (pixels.captureFont.isNotEmpty) {
          await tester.ensureVisible(find.text('记录'));
          await tester.pumpAndSettle();
          await pixels.capture(
            tester,
            boundary,
            'c50-${brightness.name}-$scale-my',
            const Size(320, 568),
            text: find.text('记录'),
            expectedText: '记录',
          );
          await tester.ensureVisible(find.text(privacy));
          await tester.pumpAndSettle();
          await pixels.capture(
            tester,
            boundary,
            'c50-${brightness.name}-$scale-privacy',
            const Size(320, 568),
            text: find.text(privacy),
            expectedText: privacy,
            firstLineOnly: true,
          );
        }
        await tapVisible(tester, find.byKey(const ValueKey('my-goals')));
        expect(find.byType(GoalManagementPage), findsOneWidget);
        await goBack(tester);
        for (final entry in {
          'my-diary': JournalKind.diary,
          'my-quick-notes': JournalKind.quickNote,
        }.entries) {
          await tapVisible(tester, find.byKey(ValueKey(entry.key)));
          expect(
            tester.widget<JournalListPage>(find.byType(JournalListPage)).kind,
            entry.value,
          );
          await goBack(tester);
        }
        expect(await app.repository.loadGoals(), isEmpty);
        expect(app.permissions.requests, 0);
        expect(tester.takeException(), isNull);
      });

      for (final completed in [false, true]) {
        testUiWidgets(
          'C51 feed ${brightness.name} ${scale}x completed=$completed',
          (tester) async {
            viewport(tester, brightness, scale);
            final app = UiHarness();
            await app.repository.create(
              const GoalDraft(title: 'TEST private', kind: GoalKind.habit),
            );
            final service = TestSharingService();
            service.seed(
              (await app.database.select(app.database.goals).get())
                  .single
                  .globalId,
              partner: !completed,
              photos: [sharingId(6)],
            );
            service.sharedRecords.single['title'] = '测试分享';
            service.sharedRecords.single['text'] = '测试正文';
            service.sharedRecords.single['completed_at'] = completed
                ? sharingInstant
                : null;
            final record = SharedRecord.fromJson(service.sharedRecords.single);
            final boundary = GlobalKey();
            await app.mount(
              tester,
              assistantCredentials: _Credentials(),
              companionService: service,
              wrapApp: (child) => RepaintBoundary(key: boundary, child: child),
            );
            final errorHandler = FlutterError.onError;
            FlutterError.onError = (details) {
              debugPrint(details.toString());
              errorHandler?.call(details);
            };
            try {
              await openMenu(tester, '陪伴');
            } finally {
              FlutterError.onError = errorHandler;
            }
            expect(
              tester.takeException(),
              isNull,
              reason: 'C51 companion home before full sharing page',
            );
            await tapVisible(
              tester,
              find.byKey(const ValueKey('open-sharing')),
            );
            expect(
              tester.takeException(),
              isNull,
              reason: 'C51 full sharing page before compact card',
            );
            final controller = await app.container.read(
              sharingControllerProvider.future,
            );
            final showPhotos = ValueNotifier(false);
            addTearDown(showPhotos.dispose);
            var opens = 0;
            unawaited(
              Navigator.of(tester.element(find.byType(SharingPage))).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: SingleChildScrollView(
                      child: ValueListenableBuilder<bool>(
                        valueListenable: showPhotos,
                        builder: (_, value, _) => SharedRecordCard(
                          controller: controller,
                          record: record,
                          onOpen: () => opens++,
                          showPhotos: value,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'C51 compact photo-count card before opening photos',
            );
            final mark = find.byType(AuthorMark);
            expect(tester.widget<AuthorMark>(mark).size, 24);
            expect(tester.widget<AuthorMark>(mark).mine, completed);
            final title = find.text('测试分享');
            final body = find.text('测试正文');
            expect(
              tester.getRect(title).left - tester.getRect(mark).left,
              closeTo(34, .01),
            );
            expect(tester.getRect(body).left, tester.getRect(title).left);
            final reply = find.byKey(ValueKey('open-replies-${record.id}'));
            expect(tester.widget<IconButton>(reply).tooltip, '查看和回复');
            expect(
              tester.widget<IconButton>(reply).color,
              tester.element(reply).xy.faint,
            );
            expect(tester.getSize(reply).width, greaterThanOrEqualTo(44));
            expect(tester.getSize(reply).height, greaterThanOrEqualTo(44));
            expect(find.text('1 张照片'), findsOneWidget);
            final completion = find.textContaining('已完成 ·');
            expect(completion, completed ? findsOneWidget : findsNothing);
            final smallStars = tester
                .widgetList<StarMark>(find.byType(StarMark))
                .where((star) => star.size == 12);
            expect(smallStars.length, completed ? 1 : 0);
            if (completed) {
              expect(
                tester.widget<Text>(completion).style!.color,
                tester.element(completion).xy.muted,
              );
              expect(
                tester.getRect(completion).top,
                greaterThan(tester.getRect(find.text('1 张照片')).bottom),
              );
            }
            if (pixels.captureFont.isNotEmpty) {
              await tester.ensureVisible(title);
              await tester.pumpAndSettle();
              await pixels.capture(
                tester,
                boundary,
                'c51-${brightness.name}-$scale-$completed',
                const Size(320, 568),
                text: title,
                expectedText: '测试分享',
              );
            }
            await tapVisible(tester, reply);
            expect(opens, 1);
            final reads = service.photoReads.length;
            showPhotos.value = true;
            await tester.pumpAndSettle();
            expect(find.text('1 张照片'), findsNothing);
            expect(service.photoReads.length, greaterThan(reads));
            expect(service.sharedCommands, isEmpty);
            expect(
              await app.database.select(app.database.checkIns).get(),
              isEmpty,
            );
            expect(
              (await app.repository.loadGoals()).single.titleOn(app.clock.day),
              'TEST private',
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
