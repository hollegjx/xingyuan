import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../data/local/app_database.dart';
import '../../../shared/local_identity_boundary.dart';
import '../../../shared/presentation.dart';
import '../record_providers.dart';

class RecordPhotoView extends ConsumerWidget {
  const RecordPhotoView({
    required this.photo,
    this.full = false,
    this.size = 88,
    super.key,
  });

  final StoredRecordPhoto photo;
  final bool full;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = ref
        .watch(recordPhotoBytesProvider(photo))
        .when(
          loading: () => const SizedBox.expand(),
          error: (_, _) => const Center(
            child: Icon(CupertinoIcons.photo, semanticLabel: '照片无法读取'),
          ),
          data: (bytes) => Image.memory(
            bytes,
            fit: full ? BoxFit.contain : BoxFit.cover,
            gaplessPlayback: false,
            errorBuilder: (_, _, _) =>
                const Icon(CupertinoIcons.photo, semanticLabel: '照片无法显示'),
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
            label: '查看记录照片',
            button: true,
            child: InkWell(
              key: ValueKey('photo-${photo.id}'),
              onTap: () {
                final repository = ref
                    .read(dayRecordStoreProvider.future)
                    .then((store) => store.goals);
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LocalIdentityBoundary(
                      repository: repository,
                      child: Scaffold(
                        appBar: pageAppBar(context, '照片'),
                        body: SafeArea(
                          child: Center(
                            child: InteractiveViewer(
                              minScale: 1,
                              maxScale: 4,
                              child: RecordPhotoView(photo: photo, full: true),
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
}
