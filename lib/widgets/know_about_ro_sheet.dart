import 'package:flutter/material.dart';
import 'bouncing_widget.dart';

class KnowAboutRoSheet extends StatelessWidget {
  final VoidCallback onExploreSpares;

  const KnowAboutRoSheet({
    super.key,
    required this.onExploreSpares,
  });

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;

    return Container(
      constraints: BoxConstraints(
        maxHeight: screenHeight * 0.92,
        maxWidth: 540,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Drag Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 8),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFCBD5E1),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.school_rounded, size: 20, color: Color(0xFF0284C7)),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Know & Learn About RO',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A),
                                  letterSpacing: -0.3,
                                ),
                              ),
                              Text(
                                'Water TDS, filter lifespans & DIY care guide',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: const BoxDecoration(
                        color: Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Icon(Icons.close, size: 18, color: Color(0xFF475569)),
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1, color: Color(0xFFE2E8F0)),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 1. Water TDS Scale Guide
                  _buildSectionCard(
                    title: 'WATER TDS GUIDE (PPM)',
                    subtitle: 'Total Dissolved Solids in Drinking Water',
                    icon: Icons.speed_rounded,
                    child: Column(
                      children: [
                        _buildTdsBar('0 - 50 ppm', 'Micro-filtered / Demineralized', 'Needs Mineral Cartridge', const Color(0xFF0284C7)),
                        const SizedBox(height: 8),
                        _buildTdsBar('50 - 150 ppm', 'Ideal Drinking Water', 'Optimal Taste & Safe Minerals', const Color(0xFF16A34A)),
                        const SizedBox(height: 8),
                        _buildTdsBar('150 - 300 ppm', 'Good Quality Water', 'Acceptable for Daily Consumption', const Color(0xFFD97706)),
                        const SizedBox(height: 8),
                        _buildTdsBar('300+ ppm', 'Hard / High Mineral Content', 'RO Membrane Filtration Mandatory', const Color(0xFFDC2626)),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 2. Filter Replacement Cycles
                  _buildSectionCard(
                    title: 'WHEN TO REPLACE RO FILTERS?',
                    subtitle: 'Factory-recommended replacement timeline',
                    icon: Icons.autorenew_rounded,
                    child: Column(
                      children: [
                        _buildFilterRow('Spun Pre-Filter (5µ)', 'Every 3 - 6 Months', 'Catches sand, dust & mud before reaching pump'),
                        const Divider(height: 16, color: Color(0xFFF1F5F9)),
                        _buildFilterRow('Sediment + Carbon Kit', 'Every 6 - 9 Months', 'Removes chlorine, bad odour & volatile chemicals'),
                        const Divider(height: 16, color: Color(0xFFF1F5F9)),
                        _buildFilterRow('75/100 GPD RO Membrane', 'Every 12 - 24 Months', 'Purifies heavy metals, dissolved salts & pathogens'),
                        const Divider(height: 16, color: Color(0xFFF1F5F9)),
                        _buildFilterRow('Alkaline / Mineral Cartridge', 'Every 12 Months', 'Restores vital minerals (Ca, Mg, K) & balances pH 8.0'),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // 3. DIY Troubleshooting
                  _buildSectionCard(
                    title: 'DIY RO TROUBLESHOOTING',
                    subtitle: 'Common symptoms and quick solutions',
                    icon: Icons.build_circle_outlined,
                    child: Column(
                      children: [
                        _buildSymptomRow(
                          '💧 Water flow is very slow / tank not filling',
                          'Check if outer spun pre-filter is choked black or brown. If so, replace the 5-micron spun candle.',
                        ),
                        const Divider(height: 16, color: Color(0xFFF1F5F9)),
                        _buildSymptomRow(
                          '⚡ RO Purifier vibrates or makes humming noise',
                          'Caused by trapped air or worn booster pump rubber dampers. Bleed the air or inspect 24V pump head.',
                        ),
                        const Divider(height: 16, color: Color(0xFFF1F5F9)),
                        _buildSymptomRow(
                          '👅 Purified water tastes bitter or flat',
                          'Indicates post-carbon filter exhaustion or depleted alkaline minerals. Change post-carbon cartridge.',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Bottom CTA
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: BouncingWidget(
                onTap: () {
                  Navigator.pop(context);
                  onExploreSpares();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    'Explore Genuine Replacement Spares',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: const Color(0xFF0284C7)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF0F172A), letterSpacing: 0.5),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildTdsBar(String range, String status, String note, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  range,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: color),
                ),
                const SizedBox(height: 1),
                Text(
                  note,
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              status,
              style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow(String name, String period, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_outline_rounded, size: 16, color: Color(0xFF0284C7)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                    ),
                  ),
                  Text(
                    period,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF0284C7)),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSymptomRow(String symptom, String solution) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          symptom,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
        ),
        const SizedBox(height: 3),
        Text(
          solution,
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF64748B), height: 1.3),
        ),
      ],
    );
  }
}
