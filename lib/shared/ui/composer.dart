import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// The rounded field inside a [XyComposer].
InputDecoration composerDecoration(
  BuildContext context, {
  required String hint,
  String? errorText,
}) {
  final xy = context.xy;
  final edge = OutlineInputBorder(
    borderRadius: BorderRadius.circular(20),
    borderSide: BorderSide(color: xy.line, width: 0.5),
  );
  return InputDecoration(
    hintText: hint,
    errorText: errorText,
    counterText: '',
    isDense: true,
    fillColor: xy.card,
    contentPadding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
    border: edge,
    enabledBorder: edge,
    disabledBorder: edge,
    focusedBorder: edge,
  );
}

/// The circular iMessage-style send arrow. The key stays on the
/// [IconButton] so callers and tests can read its state.
Widget sendButton(
  BuildContext context, {
  required VoidCallback? onPressed,
  String tooltip = '发送消息',
  Key? key,
}) => IconButton.filled(
  key: key,
  tooltip: tooltip,
  onPressed: onPressed,
  style: IconButton.styleFrom(
    minimumSize: const Size(36, 36),
    fixedSize: const Size(36, 36),
    padding: EdgeInsets.zero,
    disabledBackgroundColor: context.xy.fill,
  ),
  icon: const Icon(CupertinoIcons.arrow_up, size: 20),
);

/// A message bar pinned under a conversation: notices, an optional
/// attachment preview, then tools, a growing field and the send button.
class XyComposer extends StatelessWidget {
  const XyComposer({
    required this.field,
    required this.send,
    this.maxHeight = 240,
    this.notices = const [],
    this.attachment,
    this.leading = const [],
    super.key,
  });

  final double maxHeight;
  final List<Widget> notices;
  final Widget? attachment;
  final List<Widget> leading;
  final Widget field;
  final Widget send;

  @override
  Widget build(BuildContext context) {
    final xy = context.xy;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: xy.bar,
        border: Border(top: BorderSide(color: xy.line, width: 0.5)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: math.max(120, maxHeight)),
        child: SingleChildScrollView(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(4, 7, 8, 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final notice in notices)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 2, 0, 6),
                  child: notice,
                ),
              if (attachment case final attachment?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(56, 8, 0, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: attachment,
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ...leading,
                  SizedBox(width: leading.isEmpty ? 8 : 2),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: math.max(48, maxHeight - 14),
                      ),
                      child: field,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: send,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
