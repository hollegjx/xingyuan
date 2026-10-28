enum JournalKind {
  quickNote(1000, 'quick_note_photos'),
  diary(5000, 'diary_photos');

  const JournalKind(this.maxLength, this.photoFolder);
  final int maxLength;
  final String photoFolder;
}

class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.owner,
    required this.day,
    required this.zone,
    required this.content,
    required this.revision,
    required this.savedAt,
    required this.deletedAt,
    required this.lastOperationId,
    required this.lastOperationDraftRevision,
    required this.draftText,
    required this.draftRevision,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String owner;
  final String day;
  final String zone;
  final String content;
  final int revision;
  final int? savedAt;
  final int? deletedAt;
  final String? lastOperationId;
  final int? lastOperationDraftRevision;
  final String? draftText;
  final int draftRevision;
  final int createdAt;
  final int updatedAt;

  bool get isSaved => savedAt != null && deletedAt == null;
}

class JournalPhoto {
  const JournalPhoto({
    required this.id,
    required this.entryId,
    required this.owner,
    required this.filename,
    required this.width,
    required this.height,
    required this.byteCount,
    required this.sha256,
    required this.savedPosition,
    required this.draftPosition,
    required this.createdAt,
  });

  final String id;
  final String entryId;
  final String owner;
  final String filename;
  final int width;
  final int height;
  final int byteCount;
  final String sha256;
  final int? savedPosition;
  final int? draftPosition;
  final int createdAt;
}

class JournalSnapshot {
  JournalSnapshot(this.entry, Iterable<JournalPhoto> photos)
    : savedPhotos = List.unmodifiable(
        photos.where((p) => p.savedPosition != null).toList()
          ..sort((a, b) => a.savedPosition!.compareTo(b.savedPosition!)),
      ),
      draftPhotos = List.unmodifiable(
        photos.where((p) => p.draftPosition != null).toList()
          ..sort((a, b) => a.draftPosition!.compareTo(b.draftPosition!)),
      );

  final JournalEntry entry;
  final List<JournalPhoto> savedPhotos;
  final List<JournalPhoto> draftPhotos;

  bool get hasDraftChanges =>
      entry.draftText != null &&
      (entry.draftText != entry.content ||
          draftPhotos.map((p) => p.id).join(',') !=
              savedPhotos.map((p) => p.id).join(','));
}
