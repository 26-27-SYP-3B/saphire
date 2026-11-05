import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The logo, so both screens use the same asset and the same radius.
class SaphireLogo extends StatelessWidget {
  const SaphireLogo({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    // The lines in the SVG are thin; below ~120 px they become sub-pixel and look
    // blurry. For a small logo the stroke widths would have to be higher in the SVG.
    // The radius is the same as the one of the fields in app/theme.dart.
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SvgPicture.asset(
        'assets/saphire_logo.svg',
        height: size,
        semanticsLabel: 'Saphire',
      ),
    );
  }
}
