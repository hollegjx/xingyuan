import 'package:flutter/material.dart';

import '../../../shared/presentation.dart';
import 'companion_home_view.dart';

/// The 陪伴 content as a standalone page, for entry points outside the tab.
class PairingPage extends StatelessWidget {
  const PairingPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: pageAppBar(context, '陪伴'),
    body: const SafeArea(child: CompanionHomeView()),
  );
}
