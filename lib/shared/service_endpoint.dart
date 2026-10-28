import 'package:flutter/foundation.dart';

Uri? validateServiceEndpoint(
  Uri? endpoint, {
  bool allowInsecureLoopback = false,
}) {
  if (endpoint == null) return null;
  final local =
      !kReleaseMode &&
      allowInsecureLoopback &&
      endpoint.scheme == 'http' &&
      ['localhost', '127.0.0.1', '::1'].contains(endpoint.host);
  if ((!local && endpoint.scheme != 'https') ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment ||
      (endpoint.path.isNotEmpty && endpoint.path != '/')) {
    throw const FormatException('Service endpoint unavailable');
  }
  return endpoint;
}
