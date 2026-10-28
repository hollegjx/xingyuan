import '../../../shared/local_date.dart';
import 'goal.dart';

abstract interface class GoalRepository {
  Future<List<Goal>> loadGoals();
  Stream<List<Goal>> watchGoals();
  Future<int> create(GoalDraft draft);
  Future<void> edit(int id, GoalDraft draft);
  Future<void> setCompleted(
    int id,
    bool completed, {
    required LocalDate expectedDay,
  });
  Future<void> archive(int id);
}
