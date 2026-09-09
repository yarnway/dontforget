import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import 'dart:math';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(remindersProvider);
    
    int completed = reminders.where((r) => r.isCompleted).length;
    int pending = reminders.length - completed;
    
    int q1 = reminders.where((r) => r.quadrantLevel == 1).length;
    int q2 = reminders.where((r) => r.quadrantLevel == 2).length;
    int q3 = reminders.where((r) => r.quadrantLevel == 3).length;
    int q4 = reminders.where((r) => r.quadrantLevel == 4).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistics Dashboard'),
      ),
      body: reminders.isEmpty
          ? const Center(child: Text('No tasks yet. Create some to see statistics!'))
          : Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Task Completion', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatCard(context, 'Total', reminders.length.toString(), Colors.blue),
                      _buildStatCard(context, 'Completed', completed.toString(), Colors.green),
                      _buildStatCard(context, 'Pending', pending.toString(), Colors.orange),
                    ],
                  ),
                  const SizedBox(height: 48),
                  const Text('Quadrant Distribution', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 32),
                  SizedBox(
                    height: 200,
                    child: CustomPaint(
                      painter: _PieChartPainter(
                        values: [q1.toDouble(), q2.toDouble(), q3.toDouble(), q4.toDouble()],
                        colors: [Colors.red.shade400, Colors.orange.shade400, Colors.blue.shade400, Colors.green.shade400],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildLegendItem('Q1', Colors.red.shade400),
                      _buildLegendItem('Q2', Colors.orange.shade400),
                      _buildLegendItem('Q3', Colors.blue.shade400),
                      _buildLegendItem('Q4', Colors.green.shade400),
                    ],
                  )
                ],
              ),
            ),
    );
  }

  Widget _buildStatCard(BuildContext context, String title, String value, Color color) {
    return Container(
      width: 100,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 12, color: color.withOpacity(0.8))),
        ],
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Row(
        children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PieChartPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;

  _PieChartPainter({required this.values, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final double total = values.fold(0, (a, b) => a + b);
    if (total == 0) return;

    final Rect rect = Rect.fromLTWH(size.width / 2 - 100, 0, 200, 200);
    double startAngle = -pi / 2;

    for (int i = 0; i < values.length; i++) {
      final sweepAngle = (values[i] / total) * 2 * pi;
      final paint = Paint()
        ..color = colors[i]
        ..style = PaintingStyle.fill;
      
      canvas.drawArc(rect, startAngle, sweepAngle, true, paint);
      
      // Add a stroke to separate slices
      final strokePaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawArc(rect, startAngle, sweepAngle, true, strokePaint);

      startAngle += sweepAngle;
    }
    
    // Draw an inner circle for donut effect
    final Paint innerPaint = Paint()..color = Colors.white; // Or use canvas color
    // We just assume light theme for simplicity here, but usually we pass Theme.of(context).scaffoldBackgroundColor
    // Actually we can just set blend mode to clear
    innerPaint.blendMode = BlendMode.clear;
    canvas.drawCircle(Offset(size.width / 2, 100), 50, innerPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
