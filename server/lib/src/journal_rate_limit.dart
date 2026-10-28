class JournalRateLimit {
  JournalRateLimit({int Function()? elapsedMilliseconds}) {
    final watch = Stopwatch()..start();
    _now = elapsedMilliseconds ?? (() => watch.elapsedMilliseconds);
  }

  late final int Function() _now;
  final Map<(String, String), _Window> _windows = {};

  bool reserve(String device, String route) {
    final now = _now();
    _windows.removeWhere(
      (_, value) => value.active == 0 && now - value.start >= 60000,
    );
    final window = _windows.putIfAbsent((device, route), () => _Window(now));
    if (window.active != 0) return false;
    if (now - window.start >= 60000) {
      window.start = now;
      window.count = 0;
    }
    if (window.count >= 12) return false;
    window.count++;
    window.active++;
    return true;
  }

  void release(String device, String route) {
    final window = _windows[(device, route)];
    if (window != null && window.active > 0) window.active--;
  }
}

class _Window {
  _Window(this.start);
  int start;
  int count = 0;
  int active = 0;
}
