import 'package:flutter/material.dart';

import '../../../shared/widgets/saphire_logo.dart';

/// Placeholder until the home screen is built: empty page, logo at the top left.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Align(
          alignment: Alignment.topLeft,
          child: SaphireLogo(size: 64),
        ),
      ),
    );
  }
}
