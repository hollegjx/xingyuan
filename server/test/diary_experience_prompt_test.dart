import 'package:test/test.dart';

import 'package:xingyuan_server/src/prompts.dart';

void main() {
  test(
    'both diary paths specify personal voice without an invented ending',
    () {
      for (final prompt in [generateDiarySystemPrompt, chatDiarySystemPrompt]) {
        expect(prompt, contains('保留用户原话里的具体细节和语气'));
        expect(prompt, contains('不强加开场白、总结或升华'));
        expect(prompt, contains('素材短就写短'));
        expect(prompt, contains('没有说出的情绪不替用户补上'));
      }
    },
  );

  test(
    'chat date uncertainty uses the local picker without another interview',
    () {
      expect(chatDiarySystemPrompt, contains('date=null，交给本机日期选择'));
      expect(chatDiarySystemPrompt, contains('只问一个最必要的问题'));
      expect(chatDiarySystemPrompt, isNot(contains('date=null，询问目标日期')));
      expect(chatDiarySystemPrompt, contains('不得把建议说成已保存'));
      expect(chatDiarySystemPrompt, contains('不使用记忆、已有安排、完成统计或其他会话'));
    },
  );
}
