import 'package:flutter/material.dart';

import 'fx.dart';
import 'utils.dart';

/// بطاقة إعدادات الأصوات والاهتزاز (تُعرض داخل شاشة الإعدادات)
class FxSettingsCard extends StatefulWidget {
  const FxSettingsCard({super.key});

  @override
  State<FxSettingsCard> createState() => _FxSettingsCardState();
}

class _FxSettingsCardState extends State<FxSettingsCard> {
  DateTime _lastBuzz = DateTime.fromMillisecondsSinceEpoch(0);

  void _upd(VoidCallback f) {
    setState(f);
    FX.save();
  }

  String _levelText(double v) {
    final p = (v * 100).round();
    final w = v < 0.34 ? 'خفيف' : (v < 0.67 ? 'متوسط' : 'قوي');
    return '$p% ($w)';
  }

  Widget _testBtn(String label, IconData icon, Fx e) => OutlinedButton.icon(
        onPressed: () => FX.test(e),
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10)),
      );

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined),
            title: const Text('الأصوات التفاعلية'),
            subtitle: const Text('صوت عند السداد والحذف والتعديل والترتيب'),
            value: FX.soundOn,
            onChanged: (v) => _upd(() => FX.soundOn = v),
          ),
          if (FX.soundOn)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.volume_down, size: 20, color: Colors.black54),
                  Expanded(
                    child: Slider(
                      value: FX.volume,
                      min: 0.1,
                      max: 1,
                      divisions: 9,
                      label: '${(FX.volume * 100).round()}%',
                      onChanged: (v) => setState(() => FX.volume = v),
                      onChangeEnd: (v) {
                        FX.volume = v;
                        FX.save();
                        FX.test(Fx.pay);
                      },
                    ),
                  ),
                  const Icon(Icons.volume_up, size: 20, color: Colors.black54),
                ],
              ),
            ),
          const Divider(height: 1),
          SwitchListTile(
            secondary: const Icon(Icons.vibration),
            title: const Text('الاهتزاز (ردّ الفعل اللمسي)'),
            subtitle: const Text('اهتزاز عند السداد والحذف والتعديل والتحريك'),
            value: FX.vibOn,
            onChanged: (v) => _upd(() => FX.vibOn = v),
          ),
          if (FX.vibOn) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('شدة الاهتزاز',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text(_levelText(FX.vibLevel),
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: Theme.of(context).colorScheme.primary)),
                    ],
                  ),
                  Slider(
                    value: FX.vibLevel,
                    min: 0.05,
                    max: 1,
                    divisions: 19,
                    label: _levelText(FX.vibLevel),
                    // تفاعلي: يهتز الهاتف أثناء تحريك الشريط لتشعر بالشدة مباشرة
                    onChanged: (v) {
                      setState(() => FX.vibLevel = v);
                      final now = DateTime.now();
                      if (now.difference(_lastBuzz).inMilliseconds > 150) {
                        _lastBuzz = now;
                        FX.testVibe();
                      }
                    },
                    onChangeEnd: (v) {
                      FX.vibLevel = v;
                      FX.save();
                    },
                  ),
                ],
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.touch_app_outlined),
              title: const Text('اهتزاز خفيف عند التنقل والسحب'),
              subtitle: const Text('عند تغيير التبويبات وسحب العقارات للترتيب'),
              value: FX.vibOnMove,
              onChanged: (v) => _upd(() => FX.vibOnMove = v),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _testBtn('سداد', Icons.payments_outlined, Fx.pay),
                _testBtn('حذف', Icons.delete_outline, Fx.delete),
                _testBtn('تعديل', Icons.edit_outlined, Fx.edit),
                _testBtn('ترتيب', Icons.swap_vert, Fx.move),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
