import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class JournalViewport extends StatelessWidget {
  const JournalViewport({required this.builder, super.key});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final rawInset = media.viewInsets.bottom;
    // Native keyboard transitions can report negative insets and inflated
    // padding together. Correct both before route content uses either value.
    final inset = rawInset.isFinite ? math.max(0.0, rawInset) : 0.0;
    return MediaQuery(
      data: media.copyWith(
        viewInsets: media.viewInsets.copyWith(bottom: inset),
        padding: media.padding.copyWith(
          bottom: math.max(0.0, media.viewPadding.bottom - inset),
        ),
      ),
      child: Builder(builder: builder),
    );
  }
}
