import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:habit_checkin/app/providers.dart';
import 'package:habit_checkin/shared/presentation.dart';
import 'package:habit_checkin/features/planning/data/local_planning_store.dart';
import 'package:habit_checkin/features/planning/domain/daily_plan.dart';

import 'planning_providers.dart';

class DailyPlanningPage extends ConsumerStatefulWidget {
  const DailyPlanningPage({super.key});
  @override
  ConsumerState<DailyPlanningPage> createState() => _DailyPlanningPageState();
}

class _DailyPlanningPageState extends ConsumerState<DailyPlanningPage> {
  final _intent = TextEditingController();
  final _minutes = TextEditingController(text: '30');
  final _preferences = TextEditingController();
  final _form = GlobalKey<FormState>();
  final _taskForm = GlobalKey<FormState>();
  final _edits = <_TaskEdit>[];
  LocalPlanningStore? _store;
  String _savedPreferences = '';
  DailyPlan? _plan;
  bool _loading = true;
  bool _generating = false;
  bool _preparing = false;
  bool _saving = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = await ref.read(planningStoreProvider.future);
      final preferences = await store.loadPreferences();
      final plan = await store.latestDraft();
      if (!mounted) return;
      setState(() {
        _store = store;
        _savedPreferences = preferences;
        _preferences.text = preferences;
        _loading = false;
        _error = null;
        _replacePlan(plan);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法读取规划数据，原有目标未被修改。';
        });
      }
    }
  }

  void _replacePlan(DailyPlan? plan) {
    final previous = List<_TaskEdit>.of(_edits);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final edit in previous) {
        edit.dispose();
      }
    });
    _edits.clear();
    _plan = plan;
    if (plan != null) {
      _edits.addAll(plan.tasks.map(_TaskEdit.new));
    }
  }

  void _showError(Object error) {
    if (mounted) {
      setState(() {
        _error = error is PlanningException
            ? error.message
            : '操作未完成，请重试。原有目标未被修改。';
      });
    }
  }

  Future<void> _savePreferences() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store!.savePreferences(_preferences.text);
      if (!mounted) return;
      setState(() {
        _savedPreferences = _preferences.text.trim();
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本机偏好已保存')));
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _generate() async {
    if (_generating ||
        _preparing ||
        _saving ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _preparing = true;
      _error = null;
    });
    final service = ref.read(planningServiceProvider);
    PlanningRequest request;
    try {
      final reading = await ref.read(environmentProvider.notifier).refresh();
      if (!mounted) return;
      request = PlanningRequest(
        day: reading.day,
        zone: reading.zone,
        intent: _intent.text,
        preferences: _savedPreferences,
        availableMinutes: int.parse(_minutes.text),
      );
    } catch (error) {
      _showError(error);
      if (mounted) {
        setState(() {
          _preparing = false;
        });
      }
      return;
    }
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认发送给 AI'),
        content: SingleChildScrollView(
          child: Text(
            '接收方：${service.destination}\n\n'
            '日期：${request.day.key}（${request.zone}）\n'
            '可用时间：${request.availableMinutes} 分钟\n\n'
            '本次需求：${request.intent}\n\n'
            '本机偏好：${request.preferences.isEmpty ? "无" : request.preferences}\n\n'
            '不发送已有目标、打卡或私人笔记。调用可能产生费用。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-planning-send'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('发送并生成'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (agreed != true) {
      setState(() {
        _preparing = false;
      });
      return;
    }
    final generation = ++_generation;
    final store = _store!;
    setState(() {
      _preparing = false;
      _generating = true;
      _error = null;
    });
    try {
      final tasks = await service.generate(request);
      if (!mounted || generation != _generation) return;
      final plan = await store.saveDraft(request, tasks);
      if (!mounted || generation != _generation) return;
      setState(() {
        _replacePlan(plan);
      });
    } catch (error) {
      if (generation == _generation) _showError(error);
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _generating = false;
        });
      }
    }
  }

  Future<void> _apply() async {
    if (_saving || !_taskForm.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final tasks = _edits
          .map(
            (edit) => PlanTask(
              title: edit.title.text,
              minutes: int.parse(edit.minutes.text),
            ),
          )
          .toList();
      final ids = await _store!.apply(_plan!.id, tasks);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已在本机创建 ${ids.length} 项今日目标')));
      Navigator.of(context).pop();
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    _intent.dispose();
    _minutes.dispose();
    _preferences.dispose();
    for (final edit in _edits) {
      edit.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(planningServiceProvider);
    final today = ref.watch(environmentProvider).value?.day;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: pageAppBar(context, '规划今天'),
        body: SafeArea(
          child: _loading
              ? const PageScroll(
                  children: [StatusPanel(message: '正在读取规划', loading: true)],
                )
              : _store == null
              ? PageScroll(
                  children: [StatusPanel(message: _error!, retry: _load)],
                )
              : PageScroll(
                  children: [
                    if (_error != null) ...[
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_plan == null) ...[
                      if (today != null) Text(dateLabel(today)),
                      const SizedBox(height: 16),
                      if (!service.available) ...[
                        const Text('AI 服务尚未连接'),
                        const SizedBox(height: 16),
                      ],
                      Form(
                        key: _form,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextFormField(
                              key: const ValueKey('planning-intent'),
                              controller: _intent,
                              minLines: 3,
                              maxLines: 6,
                              maxLength: 1000,
                              enabled: !_generating && !_saving,
                              decoration: const InputDecoration(
                                labelText: '今天想完成什么',
                              ),
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '请填写今天的想法'
                                  : null,
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              key: const ValueKey('planning-budget'),
                              controller: _minutes,
                              keyboardType: TextInputType.number,
                              enabled: !_generating && !_saving,
                              decoration: const InputDecoration(
                                labelText: '可用时间',
                                suffixText: '分钟',
                              ),
                              validator: (value) {
                                final minutes = int.tryParse(value ?? '');
                                return minutes == null ||
                                        minutes < 5 ||
                                        minutes > 240
                                    ? '请输入 5 至 240 分钟'
                                    : null;
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      ExpansionTile(
                        title: const Text('本机偏好'),
                        subtitle: Text(
                          _savedPreferences.isEmpty ? '未保存' : '已保存',
                        ),
                        tilePadding: EdgeInsets.zero,
                        children: [
                          TextField(
                            key: const ValueKey('planning-preferences'),
                            controller: _preferences,
                            minLines: 2,
                            maxLines: 5,
                            maxLength: 500,
                            enabled: !_generating && !_saving,
                            decoration: const InputDecoration(
                              labelText: '希望记住的偏好',
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: const ValueKey('save-planning-preferences'),
                              tooltip: '保存本机偏好',
                              icon: const Icon(Icons.save_outlined),
                              onPressed: _generating || _saving
                                  ? null
                                  : _savePreferences,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (_generating) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 12),
                        const Text('正在生成草稿…'),
                        TextButton(
                          onPressed: () => setState(() {
                            _generation++;
                            _generating = false;
                          }),
                          child: const Text('取消等待'),
                        ),
                      ] else
                        FilledButton.icon(
                          key: const ValueKey('generate-daily-plan'),
                          onPressed:
                              service.available && !_saving && !_preparing
                              ? _generate
                              : null,
                          icon: const Icon(Icons.auto_awesome_outlined),
                          label: const Text('生成草稿'),
                        ),
                    ] else
                      ..._preview(today?.key),
                  ],
                ),
        ),
      ),
    );
  }

  List<Widget> _preview(String? today) {
    final plan = _plan!;
    final expired = plan.day.key != today;
    final total = _edits.fold<int>(
      0,
      (sum, edit) => sum + (int.tryParse(edit.minutes.text) ?? 0),
    );
    return [
      Text('计划草稿', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text('${dateLabel(plan.day)} · $total / ${plan.budget} 分钟'),
      if (expired)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('日期已变化，这份草稿不能创建为今天的目标。'),
        ),
      const SizedBox(height: 20),
      Form(
        key: _taskForm,
        child: Column(
          children: [
            for (var index = 0; index < _edits.length; index++)
              Padding(
                key: ObjectKey(_edits[index]),
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text('任务 ${index + 1}')),
                            IconButton(
                              tooltip: '移除任务 ${index + 1}',
                              onPressed: _saving || _edits.length == 1
                                  ? null
                                  : () {
                                      final removed = _edits[index];
                                      setState(() {
                                        _edits.removeAt(index);
                                      });
                                      // Defer disposal until the old text fields unmount.
                                      WidgetsBinding.instance
                                          .addPostFrameCallback(
                                            (_) => removed.dispose(),
                                          );
                                    },
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                          ],
                        ),
                        TextFormField(
                          key: ValueKey('plan-task-title-$index'),
                          controller: _edits[index].title,
                          enabled: !_saving,
                          maxLength: 60,
                          minLines: 1,
                          maxLines: 3,
                          decoration: const InputDecoration(labelText: '目标名称'),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? '请填写目标名称'
                              : null,
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          key: ValueKey('plan-task-minutes-$index'),
                          controller: _edits[index].minutes,
                          enabled: !_saving,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: '预计时间',
                            suffixText: '分钟',
                          ),
                          validator: (value) {
                            final number = int.tryParse(value ?? '');
                            return number == null || number < 1 || number > 240
                                ? '请输入 1 至 240 分钟'
                                : null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        key: const ValueKey('apply-daily-plan'),
        onPressed: _saving || expired ? null : _apply,
        icon: const Icon(Icons.check_rounded),
        label: Text(_saving ? '正在保存' : '确认创建 ${_edits.length} 项目标'),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _saving
            ? null
            : () => setState(() {
                _replacePlan(null);
                _error = null;
              }),
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('重新规划'),
      ),
    ];
  }
}

class _TaskEdit {
  _TaskEdit(PlanTask task)
    : title = TextEditingController(text: task.title),
      minutes = TextEditingController(text: '${task.minutes}');
  final TextEditingController title;
  final TextEditingController minutes;
  void dispose() {
    title.dispose();
    minutes.dispose();
  }
}
