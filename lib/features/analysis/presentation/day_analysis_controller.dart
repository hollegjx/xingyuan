import 'package:flutter/foundation.dart';

import '../../../data/local/app_database.dart';
import '../../assistant/data/assistant_service.dart';
import '../../goals/domain/goal.dart';
import '../data/local_day_analysis_store.dart';

String dayAnalysisFailureMessage(String? code) => switch (code) {
  'interrupted' => '上次分析已中断，可手动重试。模型调用可能已经发生。',
  'cancelled' => '已取消等待，模型调用可能已经发生。',
  'discarded' => '身份、凭证或授权已变化，结果未保存。',
  'consent' => '请先开启今日分析并确认发送范围。',
  'credential' => '访问凭证不可用，请在 AI 设置中检查。',
  'unconfigured' => 'AI 服务尚未连接。',
  'tooLarge' => '当天内容超过发送上限，未发送；原记录完整保留。',
  'request' => '请求格式不正确，请更新 App 后重试。',
  'invalidResponse' => '分析结果不符合要求，可以重试。',
  'busy' => '已有分析进行中，请稍候。',
  'timeout' => '分析超时，可手动重试；重试可能再次调用模型。',
  'network' => '网络连接失败，可手动重试；重试可能再次调用模型。',
  'unavailable' => '分析服务暂时不可用，可以重试。',
  _ => '未能完成分析，原有记录未被修改。',
};

class DayAnalysisController extends ChangeNotifier {
  DayAnalysisController({required this.store, required this.service});
  final LocalDayAnalysisStore store;
  final DayAnalysisService service;
  StoredDayAnalysisSettings? settings;
  List<StoredDayAnalysis> results = const [];
  String? error;
  bool busy = false;
  bool _disposed = false;
  AssistantCancellation? _cancellation;
  DayAnalysisAttempt? _attempt;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    await store.recoverInterrupted();
    await refresh();
  }

  Future<void> refresh() async {
    settings = await store.settings();
    results = await store.list();
    _notify();
  }

  Future<void> consent() async {
    await store.consent();
    await refresh();
  }

  Future<void> setEnabled(bool enabled) async {
    if (!enabled) _cancellation?.cancel();
    await store.setEnabled(enabled);
    await refresh();
  }

  Future<void> analyze({String? retryOf}) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    final cancellation = AssistantCancellation();
    _cancellation = cancellation;
    _notify();
    try {
      if (!service.configured) {
        throw const AssistantFailure(AssistantFailureKind.unconfigured);
      }
      final attempt = await store.begin(retryOf: retryOf);
      _attempt = attempt;
      await refresh();
      final result = await service.analyzeDay(
        attempt.request,
        access: AssistantAccess(
          consentVersion: assistantConsentVersion,
          isCurrent: () => store.authorized(attempt.consentedAt),
        ),
        cancellation: cancellation,
      );
      if (cancellation.isCancelled || _disposed) {
        throw const AssistantFailure(AssistantFailureKind.cancelled);
      }
      if (!await store.finish(attempt, result)) {
        throw const AssistantFailure(AssistantFailureKind.discarded);
      }
    } catch (failure) {
      final code = failure is AssistantFailure
          ? failure.kind.name
          : failure is FormatException
          ? 'tooLarge'
          : 'storage';
      error = failure is GoalRuleException
          ? failure.message
          : dayAnalysisFailureMessage(code);
      if (_attempt case final attempt?) {
        try {
          await store.fail(
            attempt.row.id,
            code,
            cancelled: cancellation.isCancelled || code == 'discarded',
          );
        } catch (_) {
          // A stale identity cannot mutate its previous owner's pending row.
        }
      }
    } finally {
      _cancellation = null;
      _attempt = null;
      busy = false;
      if (!_disposed) {
        try {
          await refresh();
        } catch (_) {
          results = const [];
        }
        _notify();
      }
    }
  }

  Future<void> cancel({bool configurationChanged = false}) async {
    _cancellation?.cancel();
    if (_attempt case final attempt?) {
      await store.fail(
        attempt.row.id,
        configurationChanged ? 'discarded' : 'cancelled',
        cancelled: true,
      );
      await refresh();
    }
  }

  Future<void> remove(String id) async {
    if (_attempt?.row.id == id) await cancel();
    await store.remove(id);
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancellation?.cancel();
    super.dispose();
  }
}
