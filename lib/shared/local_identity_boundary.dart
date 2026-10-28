import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/local/local_goal_repository.dart';
import 'presentation.dart';

class LocalIdentityBoundary extends StatefulWidget {
  const LocalIdentityBoundary({
    required this.repository,
    required this.child,
    this.onReopen,
    super.key,
  });

  final Future<LocalGoalRepository> repository;
  final Widget child;
  final VoidCallback? onReopen;

  @override
  State<LocalIdentityBoundary> createState() => _LocalIdentityBoundaryState();
}

class _LocalIdentityBoundaryState extends State<LocalIdentityBoundary> {
  // A route stays bound to its original lease, even after switching back.
  late final _current = widget.repository.asStream().asyncExpand((goals) {
    final lease = goals.identityLease;
    return goals.db
        .select(goals.db.identityStates)
        .watchSingle()
        .map(
          (state) =>
              lease != null &&
              state.owner == lease.identity.owner &&
              state.generation == lease.generation &&
              state.targetOwner == null,
        );
  });
  bool _invalidated = false;

  void _invalidate(BuildContext context) {
    if (_invalidated) return;
    _invalidated = true;
    final route = ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || route == null || !route.isActive) return;
      navigator?.popUntil(
        (candidate) => candidate == route || candidate.isFirst,
      );
    });
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<bool>(
    stream: _current,
    builder: (context, state) {
      if (state.hasError || state.data == false) _invalidate(context);
      if (!_invalidated && state.data == true) return widget.child;
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          child: PageScroll(
            children: [
              StatusPanel(
                message: _invalidated ? '身份已变化或不可用。' : '正在核对当前身份',
                loading: !_invalidated,
              ),
              if (_invalidated)
                OutlinedButton.icon(
                  onPressed:
                      widget.onReopen ?? () => Navigator.of(context).maybePop(),
                  icon: Icon(
                    widget.onReopen == null
                        ? CupertinoIcons.back
                        : CupertinoIcons.arrow_clockwise,
                  ),
                  label: Text(widget.onReopen == null ? '返回' : '重新打开'),
                ),
            ],
          ),
        ),
      );
    },
  );
}
