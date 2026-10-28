import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../domain/journal_entry.dart';
import '../journal_providers.dart';

class JournalPhotoView extends ConsumerWidget {
  const JournalPhotoView({
    required this.kind,
    required this.photo,
    this.full = false,
    this.size = 88,
    super.key,
  });

  final JournalKind kind;
  final JournalPhoto photo;
  final bool full;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = journalPhotoBytesProvider((kind: kind, photo: photo));
    final content = ref
        .watch(provider)
        .when(
          skipLoadingOnRefresh: false,
          loading: () => _status('正在读取照片', loading: true),
          error: (_, _) => _status(
            '照片无法读取',
            // Refresh synchronously so rapid taps see the pending read.
            retry: () =>
                ref.read(provider).isLoading ? null : ref.refresh(provider),
          ),
          data: (bytes) => Image.memory(
            bytes,
            fit: full ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: false,
            frameBuilder: (context, child, frame, synchronous) {
              if (frame == null) {
                return _status('正在读取照片', loading: true);
              }
              return full
                  ? InteractiveViewer(minScale: 1, maxScale: 4, child: child)
                  : child;
            },
            errorBuilder: (_, _, _) => _status('照片无法显示'),
          ),
        );
    if (full) return content;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: context.xy.cardSoft,
        child: SizedBox.square(
          dimension: size,
          child: Semantics(
            label: '查看私人照片',
            button: true,
            child: InkWell(
              key: ValueKey('journal-photo-${photo.id}'),
              onTap: () {
                final repository = ref.read(journalRepositoryProvider.future);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => LocalIdentityBoundary(
                      repository: repository,
                      child: Scaffold(
                        appBar: pageAppBar(context, '照片'),
                        body: SafeArea(
                          child: Center(
                            child: JournalPhotoView(
                              kind: kind,
                              photo: photo,
                              full: true,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
              child: content,
            ),
          ),
        ),
      ),
    );
  }

  Widget _status(String message, {bool loading = false, VoidCallback? retry}) {
    if (!full) {
      return Center(
        child: loading
            ? Semantics(
                label: message,
                child: const ExcludeSemantics(child: XyActivity()),
              )
            : Icon(CupertinoIcons.photo, semanticLabel: message),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Semantics(
              liveRegion: true,
              child: StatusPanel(
                message: message,
                loading: loading,
                icon: CupertinoIcons.photo,
                retry: retry,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
