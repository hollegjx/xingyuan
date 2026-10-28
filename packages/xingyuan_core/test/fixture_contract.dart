import 'dart:convert';
import 'dart:io';

import 'package:xingyuan_core/xingyuan_core.dart';

// Both runtimes execute these same JSON cases; no provider is involved.
List<Map<String, dynamic>> loadContractCases(String fixtureDirectory) {
  final baseline = jsonDecode(
    File('$fixtureDirectory/turn.json').readAsStringSync(),
  );
  final cases = jsonDecode(
    File('$fixtureDirectory/cases.json').readAsStringSync(),
  ) as List;
  return cases.map((entry) {
    final data = jsonDecode(jsonEncode(baseline)) as Map<String, dynamic>;
    for (final change in entry['changes'] as List) {
      final path = change['path'] as List;
      dynamic parent = data;
      for (final key in path.take(path.length - 1)) {
        parent = parent[key];
      }
      final key = path.last;
      if (change['remove'] == true) {
        (parent as Map).remove(key);
      } else {
        dynamic value = change.containsKey('value')
            ? change['value']
            : parent[key];
        if (change['repeat'] case final int repeat) {
          value = value is String
              ? value * repeat
              : [for (var i = 0; i < repeat; i++) ...(value as List)];
        }
        parent[key] = value;
      }
    }
    return <String, dynamic>{
      'id': entry['id'],
      'accept': entry['accept'],
      ...data,
    };
  }).toList();
}

bool acceptsContractCase(Map<String, dynamic> testCase) {
  try {
    final request = TurnRequest.fromJson(testCase['request']);
    final response = TurnResponse.fromJson(
      testCase['response'],
      request: request,
    );
    TurnRequest.fromJson(request.toJson());
    TurnResponse.fromJson(response.toJson(), request: request);
    return true;
  } on FormatException {
    return false;
  }
}
