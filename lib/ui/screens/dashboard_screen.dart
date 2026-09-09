import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/providers.dart';
import '../../l10n/app_localizations.dart';
import '../../services/llm_service.dart';
import '../widgets/ai_background_effect.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  bool _isLoadingReport = false;
  String? _reviewReport;

  Future<void> _generateReport() async {
    final reminders = ref.read(remindersProvider);
    final settings = ref.read(settingsProvider);
    if (reminders.isEmpty) return;

    setState(() => _isLoadingReport = true);
    try {
      final report = await LLMService().generateReviewReport(
        reminders,
        settings,
        language: settings.language,
      );
      if (mounted) {
        setState(() {
          _reviewReport = report;
          _isLoadingReport = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingReport = false);
      }
    }
  }

  void _copyReport(BuildContext context, AppLocalizations l10n) {
    if (_reviewReport == null || _reviewReport!.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _reviewReport!));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text(l10n.get('reportCopied')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final reminders = ref.watch(remindersProvider);

    final int completed = reminders.where((r) => r.isCompleted).length;
    final int pending = reminders.length - completed;

    final int q1 = reminders.where((r) => r.quadrantLevel == 1).length;
    final int q2 = reminders.where((r) => r.quadrantLevel == 2).length;
    final int q3 = reminders.where((r) => r.quadrantLevel == 3).length;
    final int q4 = reminders.where((r) => r.quadrantLevel == 4).length;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n.get('dashboardTitle'),
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 18),
        ),
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
      body: AiBackgroundEffect(
        child: SafeArea(
          child: reminders.isEmpty
              ? Center(
                  child: Container(
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(8),
                      color: isDark ? Colors.black26 : Colors.white60,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bar_chart_rounded,
                          size: 48,
                          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.get('noTasksYet'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Section 1: Task Completion Wireframe Block
                      Text(
                        l10n.get('taskCompletion'),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _buildWireframeStatCard(
                              context,
                              l10n.get('total'),
                              reminders.length.toString(),
                              Colors.blue,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildWireframeStatCard(
                              context,
                              l10n.get('completed'),
                              completed.toString(),
                              Colors.green,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildWireframeStatCard(
                              context,
                              l10n.get('pending'),
                              pending.toString(),
                              Colors.orange,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // Section 2: Quadrant Distribution
                      Text(
                        l10n.get('quadrantDist'),
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 12),

                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          color: isDark ? Colors.black26 : Colors.white.withValues(alpha: 0.6),
                        ),
                        child: Column(
                          children: [
                            SizedBox(
                              height: 180,
                              child: CustomPaint(
                                painter: _PieChartPainter(
                                  values: [q1.toDouble(), q2.toDouble(), q3.toDouble(), q4.toDouble()],
                                  colors: [
                                    Colors.red.shade400,
                                    Colors.orange.shade400,
                                    Colors.blue.shade400,
                                    Colors.green.shade400,
                                  ],
                                  bgColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                _buildLegendItem(Icons.local_fire_department_rounded, l10n.get('cat1'), q1, Colors.red.shade400),
                                _buildLegendItem(Icons.star_rounded, l10n.get('cat2'), q2, Colors.orange.shade400),
                                _buildLegendItem(Icons.bolt_rounded, l10n.get('cat3'), q3, Colors.blue.shade400),
                                _buildLegendItem(Icons.coffee_rounded, l10n.get('cat4'), q4, Colors.green.shade400),
                              ],
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Section 3: AI Productivity Coach & Review
                      Row(
                        children: [
                          Icon(Icons.psychology_alt_rounded, size: 20, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            l10n.get('aiReviewTitle'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.get('aiReviewSubtitle'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
                        ),
                      ),
                      const SizedBox(height: 12),

                      _buildAiReviewCard(context, l10n, isDark),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildAiReviewCard(BuildContext context, AppLocalizations l10n, bool isDark) {
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.black26 : Colors.white.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.35),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isLoadingReport) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(strokeWidth: 2, color: primaryColor),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    l10n.get('generatingAiReview'),
                    style: TextStyle(fontSize: 13, color: primaryColor, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ] else if (_reviewReport == null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  Icon(Icons.auto_awesome, size: 36, color: primaryColor.withValues(alpha: 0.7)),
                  const SizedBox(height: 10),
                  Text(
                    l10n.get('aiReviewSubtitle'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                    icon: const Icon(Icons.bolt_rounded, size: 18),
                    label: Text(
                      l10n.get('generateAiReview'),
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    onPressed: _generateReport,
                  ),
                ],
              ),
            ),
          ] else ...[
            SelectableText(
              _reviewReport!,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 16),
            Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(l10n.get('regenerateAiReview'), style: const TextStyle(fontSize: 12)),
                  onPressed: _generateReport,
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: Text(l10n.get('copyReport'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  onPressed: () => _copyReport(context, l10n),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWireframeStatCard(
    BuildContext context,
    String title,
    String value,
    Color accentColor,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? Colors.black26 : Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: accentColor,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(IconData icon, String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.35), width: 1),
        borderRadius: BorderRadius.circular(6),
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

class _PieChartPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final Color bgColor;

  _PieChartPainter({
    required this.values,
    required this.colors,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double total = values.fold(0, (a, b) => a + b);
    if (total == 0) return;

    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = min(size.width, size.height) / 2 - 8;
    final innerRadius = outerRadius * 0.58;

    final Rect rect = Rect.fromCircle(center: center, radius: outerRadius);
    double startAngle = -pi / 2;

    for (int i = 0; i < values.length; i++) {
      if (values[i] <= 0) continue;
      final sweepAngle = (values[i] / total) * 2 * pi;
      final paint = Paint()
        ..color = colors[i]
        ..style = PaintingStyle.fill;

      canvas.drawArc(rect, startAngle, sweepAngle, true, paint);

      // Clean wireframe separator line
      final strokePaint = Paint()
        ..color = bgColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawArc(rect, startAngle, sweepAngle, true, strokePaint);

      startAngle += sweepAngle;
    }

    // Donut hole with background fill
    final innerPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, innerRadius, innerPaint);

    // Inner wireframe ring
    final ringPaint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(center, innerRadius, ringPaint);
  }

  @override
  bool shouldRepaint(covariant _PieChartPainter oldDelegate) => true;
}
