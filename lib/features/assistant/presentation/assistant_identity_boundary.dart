import 'package:flutter/material.dart';

import '../../../shared/local_identity_boundary.dart';
import '../data/local_conversation_store.dart';

class AssistantIdentityBoundary extends StatefulWidget {
  const AssistantIdentityBoundary({
    required this.store,
    required this.child,
    this.onReopen,
    super.key,
  });

  final Future<LocalConversationStore> store;
  final Widget child;
  final VoidCallback? onReopen;

  @override
  State<AssistantIdentityBoundary> createState() =>
      _AssistantIdentityBoundaryState();
}

class _AssistantIdentityBoundaryState extends State<AssistantIdentityBoundary> {
  // Match the local boundary's original route lease and single subscription.
  late final _repository = widget.store.then((store) => store.goals);

  @override
  Widget build(BuildContext context) => LocalIdentityBoundary(
    repository: _repository,
    onReopen: widget.onReopen,
    child: widget.child,
  );
}
