import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/app/theme.dart';
import 'package:habit_checkin/features/journal/domain/journal_entry.dart';
import 'package:habit_checkin/features/journal/presentation/journal_list_page.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import 'journal_diary_capture_test.dart'
    show capture, captureDirectory, loadDiaryCaptureFont;
import 'journal_writing_space_test.dart' show configure;

const _summary = '合成：保存的摘要。';
const _source = 'test/journal_metadata_breakpoint_test.dart';

JournalSnapshot _snapshot() => JournalSnapshot(
  JournalEntry(
    id: 'synthetic-r14',
    owner: 'synthetic',
    day: '2026-10-26',
    zone: 'Asia/Shanghai',
    content: _summary,
    revision: 1,
    savedAt: 1,
    deletedAt: null,
    lastOperationId: 'synthetic-save',
    lastOperationDraftRevision: 1,
    draftText: '合成：未保存草稿。',
    draftRevision: 2,
    createdAt: DateTime.utc(2026, 10, 26, 10, 40).microsecondsSinceEpoch,
    updatedAt: 2,
  ),
  const [],
);

RenderParagraph _paragraph(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)),
    );

// A nonuniform scaler catches heuristics based on an unrelated reference size.
class _FieldScaler extends TextScaler {
  const _FieldScaler(this.factor);
  final double factor;
  @override
  double get textScaleFactor => 1;
  @override
  double scale(double fontSize) => fontSize * (fontSize == 14 ? 1 : factor);
}

void main() {
  setUpAll(() async {
    tzdata.initializeTimeZones();
    await loadDiaryCaptureFont();
    expect(
      captureDirectory.isEmpty ||
          captureDirectory.startsWith('/tmp/xingyuan-ai2-r14-'),
      isTrue,
    );
  });
  for (final kind in JournalKind.values) {
    testWidgets('R14 ${kind.name} actual-font breakpoint both sides', (
      tester,
    ) async {
      const size = Size(320, 568);
      configure(tester, size, 1, Brightness.light);
      final boundary = GlobalKey();
      final snapshot = _snapshot();
      final fields = kind == JournalKind.diary ? ['26', '周一'] : ['18:40'];
      final leadWidth = kind == JournalKind.diary ? 40.0 : 44.0;
      Future<void> mount(TextScaler scaler) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: buildXyTheme(Brightness.light),
            home: MediaQuery(
              data: MediaQueryData(size: size, textScaler: scaler),
              child: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: JournalPreviewTile(kind: kind, snapshot: snapshot),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount(TextScaler.noScaling);
      double longest = 0;
      for (final field in fields) {
        final paragraph = _paragraph(tester, field);
        final painter = TextPainter(
          text: paragraph.text,
          textDirection: paragraph.textDirection,
          textScaler: TextScaler.noScaling,
          locale: paragraph.locale,
        )..layout();
        if (painter.width > longest) longest = painter.width;
        painter.dispose();
      }
      final threshold = leadWidth / longest;
      final evidence = <Map<String, Object?>>[];
      for (final above in [false, true]) {
        final factor = threshold + (above ? .01 : -.01);
        await mount(_FieldScaler(factor));
        final summary = tester.getRect(find.text(_summary));
        final tile = tester.getRect(find.byType(JournalPreviewTile));
        final geometry = <Map<String, Object?>>[];
        for (final field in fields) {
          final paragraph = _paragraph(tester, field);
          final origin = paragraph.localToGlobal(Offset.zero);
          final bounds = origin & paragraph.size;
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: field.length),
          );
          expect(boxes, isNotEmpty);
          expect(boxes.map((box) => box.top).toSet(), hasLength(1));
          expect(paragraph.didExceedMaxLines, isFalse);
          for (final box in boxes) {
            expect(box.left, greaterThanOrEqualTo(-.01));
            expect(box.right, lessThanOrEqualTo(paragraph.size.width + .01));
          }
          expect(bounds.overlaps(summary), isFalse);
          if (above) {
            expect(bounds.bottom, lessThanOrEqualTo(summary.top));
            expect(summary.left, closeTo(tile.left + 16, .01));
          } else {
            expect(bounds.right, lessThanOrEqualTo(summary.left));
            expect(summary.left, closeTo(tile.left + 16 + leadWidth + 10, .01));
          }
          final style = (paragraph.text as TextSpan).style!;
          geometry.add({
            'field': field,
            'rect': [bounds.left, bounds.top, bounds.right, bounds.bottom],
            'fontSize': style.fontSize,
            'scaledFontSize': paragraph.textScaler.scale(style.fontSize!),
          });
          await capture(
            tester,
            boundary,
            '${kind.name}-${above ? 'above' : 'below'}-$field',
            size,
            text: find.text(field),
            expectedText: field,
          );
        }
        expect(find.text('草稿'), findsOneWidget);
        expect(find.byType(JournalPreviewTile).hitTestable(), findsOneWidget);
        final context = tester.element(find.byType(JournalPreviewTile));
        expect(
          journalPreviewDividerIndent(context, kind, [snapshot]),
          above ? 16 : 16 + leadWidth + 10,
        );
        expect(tester.takeException(), isNull);
        evidence.add({'above': above, 'factor': factor, 'geometry': geometry});
      }
      if (captureDirectory.isNotEmpty) {
        await tester.runAsync(() async {
          await File('$captureDirectory/${kind.name}-breakpoint.json')
              .writeAsString(
                const JsonEncoder.withIndent('  ').convert({
                  'product': const String.fromEnvironment('R14_PRODUCT_SOURCE'),
                  'test': const String.fromEnvironment('R14_TEST_SOURCE'),
                  'sourceSha256': sha256
                      .convert(File(_source).readAsBytesSync())
                      .toString(),
                  'threshold': threshold,
                  'events': evidence,
                }),
              );
        });
      }
      debugPrint(
        'R14_BREAKPOINT ${kind.name} threshold=$threshold both sides passed',
      );
    });
  }
}
