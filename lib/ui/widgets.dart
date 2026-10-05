import 'package:flutter/material.dart';

import '../core/zones.dart';

/// Zone shown by colour and number together, so colour is never the only cue.
class ZoneBadge extends StatelessWidget {
  const ZoneBadge(this.zone, {super.key, this.big = false});
  final int zone;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final c = zoneColors[zone.clamp(0, 5)];
    return Container(
      padding: EdgeInsets.symmetric(horizontal: big ? 16 : 8, vertical: big ? 6 : 2),
      decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(big ? 12 : 8)),
      child: Text(
        zone == 0 ? 'Z0' : 'Z$zone',
        style: TextStyle(
          color: Colors.black,
          fontWeight: FontWeight.w800,
          fontSize: big ? 28 : 14,
        ),
      ),
    );
  }
}

class BigStat extends StatelessWidget {
  const BigStat({super.key, required this.label, required this.value, this.unit, this.size = 34});
  final String label;
  final String value;
  final String? unit;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: t.labelSmall?.copyWith(letterSpacing: 1.1)),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, fontFeatures: const [
                  FontFeature.tabularFigures(),
                ])),
            if (unit != null) ...[
              const SizedBox(width: 4),
              Text(unit!, style: t.bodyMedium),
            ],
          ],
        ),
      ],
    );
  }
}

/// "How we calculate this" next to every estimated number.
class HowButton extends StatelessWidget {
  const HowButton({super.key, required this.title, required this.text});
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.info_outline, size: 18),
        tooltip: 'How we calculate this',
        onPressed: () => showHow(context, title, text),
      );
}

void showHow(BuildContext context, String title, String text) {
  showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(text)),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
    ),
  );
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, required this.child, this.trailing});
  final String? title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(child: Text(title!, style: Theme.of(context).textTheme.titleMedium)),
                    if (trailing != null) trailing!,
                  ]),
                ),
              child,
            ],
          ),
        ),
      );
}

/// A ready / warning / failure line for the device test.
class CheckLine extends StatelessWidget {
  const CheckLine({super.key, required this.label, required this.state, this.detail});
  final String label;

  /// pass | warn | fail | running | pending
  final String state;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final icon = switch (state) {
      'pass' => const Icon(Icons.check_circle, color: Colors.green),
      'warn' => const Icon(Icons.warning_amber_rounded, color: Colors.amber),
      'fail' => const Icon(Icons.cancel, color: Colors.redAccent),
      'running' => const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
      _ => const Icon(Icons.radio_button_unchecked),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: icon,
      title: Text(label),
      subtitle: detail == null ? null : Text(detail!),
    );
  }
}

Future<int?> askInt(BuildContext context, String title, {int? initial, String? hint, String? suffix}) async {
  final c = TextEditingController(text: initial?.toString() ?? '');
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: hint, suffixText: suffix),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())), child: const Text('OK')),
      ],
    ),
  );
}

Future<double?> askDouble(BuildContext context, String title, {double? initial, String? suffix}) async {
  final c = TextEditingController(text: initial?.toString() ?? '');
  return showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(suffixText: suffix),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim().replaceAll(',', '.'))),
            child: const Text('OK')),
      ],
    ),
  );
}

/// Parses "mm:ss" or "h:mm:ss" to a duration.
Duration? parseClock(String s) {
  final parts = s.trim().split(':').map(int.tryParse).toList();
  if (parts.isEmpty || parts.any((p) => p == null)) return null;
  final p = parts.cast<int>();
  return switch (p.length) {
    1 => Duration(minutes: p[0]),
    2 => Duration(minutes: p[0], seconds: p[1]),
    3 => Duration(hours: p[0], minutes: p[1], seconds: p[2]),
    _ => null,
  };
}

void snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
