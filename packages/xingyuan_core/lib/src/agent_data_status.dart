const agentDataMessages = {
  'not_authorized': '没有读取你的日程，以下内容没有考虑已有安排',
  'failed': '日程读取失败，以下内容没有考虑已有安排',
  'truncated': '只读取了部分日程，可能有遗漏的冲突',
  'partial': '有安排缺少时间或时长，无法完整判断冲突',
};

List<String> agentDataBanners(Iterable<String> statuses) => [
  for (final key in agentDataMessages.keys)
    if (statuses.contains(key)) agentDataMessages[key]!,
];
