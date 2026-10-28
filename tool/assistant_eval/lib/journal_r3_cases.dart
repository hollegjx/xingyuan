import 'package:xingyuan_core/xingyuan_core.dart';

import 'cases.dart';
import 'journal_cases.dart';

// Separate from the existing ten-case live matrix. All material is synthetic.
List<JournalAiCase> journalR3Cases() {
  JournalAiCase chat(
    String id,
    String prompt,
    List<Map<String, Object?>> history,
    List<String> forbidden,
  ) => JournalAiCase(
    id,
    TurnRequest.fromJson({
      ...sample(
        id,
        prompt,
        date: '2026-10-26',
        history: history,
        autoMemory: false,
      ).request.toJson(),
      'diary_proposals': true,
    }),
    forbidden,
    deferDiaryDate: true,
  );

  return [
    JournalAiCase(
      'R3-MULTI',
      GenerateDiaryRequest.fromJson({
        'protocol': assistantProtocol,
        'request_id': 'R3-MULTI',
        'day': '2026-10-26',
        'entries': [
          {'title': '阅读', 'completed': true, 'text': '读完一章。'},
          {'title': '跑步', 'completed': false, 'text': ''},
        ],
        'notes': ['有一段没读懂，有点烦。', '下班买了两个面包。', '我想晚上散步，但现在还没决定。'],
      }),
      ['跑了五公里', '今天没有跑步', '晚上散步了', '和朋友吃了晚饭', '收获满满'],
    ),
    chat(
      'R3-CORRECTION',
      '把上面这段经历写成日记，日期我稍后自己选。',
      [
        {'role': 'user', 'text': '下午和小林在公园读完了两章，钥匙可能落在那里。'},
        {'role': 'assistant', 'text': '你提到了阅读，也还不确定钥匙在哪里。'},
        {'role': 'user', 'text': '更正：我一个人在图书馆，只读完一章；钥匙也许在家里，还没找到。'},
        {'role': 'assistant', 'text': '按这次更正整理，钥匙的去向仍未确定。'},
      ],
      ['我和小林', '我在公园', '读完了两章', '终于找到了钥匙', '收获满满'],
    ),
    chat(
      'R3-NEGATIVE',
      '把这段写成日记：下班后我翻了包和外套口袋，还是没找到钥匙，'
          '也许落在办公室了。我有点烦，还不知道怎么办。日期我稍后自己选。',
      [],
      ['终于找到了钥匙', '钥匙就在办公室', '一切都好起来了', '明天继续加油'],
    ),
  ];
}
