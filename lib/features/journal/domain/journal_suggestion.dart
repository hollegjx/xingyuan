import 'package:characters/characters.dart';

import 'journal_entry.dart';

String? journalSuggestionError(
  String suggestion, {
  required JournalKind kind,
  String original = '',
  bool append = false,
}) {
  if (suggestion.trim().isEmpty) return '请填写正文后再继续。';
  if (suggestion.characters.length > kind.maxLength) {
    return '正文最多 ${kind.maxLength} 字，请精简后重试。';
  }
  if (append &&
      original.isNotEmpty &&
      '$original\n\n$suggestion'.characters.length > kind.maxLength) {
    return '追加后超过 ${kind.maxLength} 字，请精简新正文或选择替换。';
  }
  return null;
}
