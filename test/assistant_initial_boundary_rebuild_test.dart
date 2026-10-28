import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:habit_checkin/features/assistant/data/local_conversation_store.dart';
import 'package:habit_checkin/features/assistant/presentation/assistant_identity_boundary.dart';
import 'package:habit_checkin/shared/local_identity_boundary.dart';

void main() {
  for (final kind in ['single', 'rebuilt', 'stable-mapping-control']) {
    testWidgets('AI1 unavailable assistant boundary $kind', (tester) async {
      final store = Completer<LocalConversationStore>();
      // The control reuses one mapped future, without changing product code.
      final stableRepository = kind == 'stable-mapping-control'
          ? store.future.then((value) => value.goals)
          : null;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              const child = Text('Synthetic private child');
              return stableRepository == null
                  ? AssistantIdentityBoundary(store: store.future, child: child)
                  : LocalIdentityBoundary(
                      repository: stableRepository,
                      child: child,
                    );
            },
          ),
        ),
      );
      store.completeError(StateError('AI1 synthetic unavailable store'));
      await tester.pumpAndSettle();
      expect(find.text('身份已变化或不可用。'), findsOneWidget);
      expect(find.text('Synthetic private child'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, '返回'), findsOneWidget);
      if (kind != 'single') {
        rebuild(() {});
        await tester.pumpAndSettle();
        expect(find.text('身份已变化或不可用。'), findsOneWidget);
        expect(find.text('Synthetic private child'), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
