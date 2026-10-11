import 'package:flutter/material.dart';

import 'db.dart';
import 'fx.dart';
import 'utils.dart';

// =====================================================================
//  ترتيب العقارات + البحث المتقدم
// =====================================================================

/// أنواع الترتيب المتاحة. «manual» = الترتيب اليدوي المحفوظ بالسحب والإفلات.
const kSortModes = <String, ({String label, IconData icon})>{
  'manual': (label: 'ترتيبي اليدوي (بالسحب)', icon: Icons.drag_indicator),
  'newest': (label: 'الأحدث إضافة', icon: Icons.fiber_new_outlined),
  'name': (label: 'الاسم (أ ← ي)', icon: Icons.sort_by_alpha),
  'rent_desc': (label: 'الإيجار: الأعلى أولاً', icon: Icons.trending_up),
  'rent_asc': (label: 'الإيجار: الأقل أولاً', icon: Icons.trending_down),
  'due': (label: 'الأقرب استحقاقاً', icon: Icons.event_outlined),
  'contract': (label: 'الأقرب انتهاء عقد', icon: Icons.description_outlined),
  'status': (label: 'الحالة (متأخر ← مؤجر ← شاغر)', icon: Icons.flag_outlined),
};

/// تطبيع النص العربي للبحث: أرقام هندية، همزات، تاء مربوطة، تشكيل
String normSearch(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final ch = String.fromCharCode(r);
    final k = ar.indexOf(ch);
    if (k >= 0) {
      b.write(k);
      continue;
    }
    switch (ch) {
      case 'أ':
      case 'إ':
      case 'آ':
        b.write('ا');
        break;
      case 'ة':
        b.write('ه');
        break;
      case 'ى':
        b.write('ي');
        break;
      default:
        b.write(ch);
    }
  }
  return b.toString().replaceAll(RegExp('[ً-ْـ]'), '');
}

/// كل ما يخص العقار في نص واحد (للبحث السريع الشامل)
String propSearchText(Map<String, dynamic> i) {
  final parts = <String>[];
  void add(dynamic v) {
    final t = (v ?? '').toString().trim();
    if (t.isNotEmpty) parts.add(t);
  }

  void money(dynamic v) {
    final n = num0(v);
    if (n != 0) add(plain(n));
  }

  void date(dynamic v) {
    final d = parseDue(v);
    if (d != null) {
      add(dateIso(d));
      add(fmtDate(d));
    }
  }

  add(i['id']);
  add(i['name']);
  add(i['tenant_name']);
  add(i['tenant_phone']);
  add(phoneForInput(i['tenant_phone']));
  add(i['alt_phone']);
  add(phoneForInput(i['alt_phone']));
  add(i['address']);
  add(i['location']);
  add(i['other_note']);
  add(i['status']);
  add(effStatus(i));
  money(i['rent_amount']);
  money(i['deposit_amount']);
  money(i['electricity']);
  money(i['water']);
  money(i['gas']);
  money(i['other_amount']);
  money(i['balance']);
  money(totalDue(i));
  date(i['due_date']);
  date(i['contract_start']);
  date(i['contract_end']);
  return normSearch(parts.join(' '));
}

/// كل كلمة مكتوبة يجب أن توجد في أي حقل من حقول العقار
bool propMatchesQuery(Map<String, dynamic> i, String query) {
  final tokens = normSearch(query)
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return true;
  final h = propSearchText(i);
  return tokens.every(h.contains);
}

/// معايير البحث المتقدم
class PropFilter {
  String? status; // مؤجر / شاغر / متأخرات
  String? due; // late / soon / ok / none
  String? contract; // expired / soon / active / none
  double? minRent, maxRent;
  bool withBalance = false;
  bool withUtilities = false;

  PropFilter();

  PropFilter copy() => PropFilter()
    ..status = status
    ..due = due
    ..contract = contract
    ..minRent = minRent
    ..maxRent = maxRent
    ..withBalance = withBalance
    ..withUtilities = withUtilities;

  int get count =>
      (status != null ? 1 : 0) +
      (due != null ? 1 : 0) +
      (contract != null ? 1 : 0) +
      (minRent != null ? 1 : 0) +
      (maxRent != null ? 1 : 0) +
      (withBalance ? 1 : 0) +
      (withUtilities ? 1 : 0);

  bool get isActive => count > 0;

  bool matches(Map<String, dynamic> i) {
    if (status != null && effStatus(i) != status) return false;
    if (due != null) {
      final d = daysUntilDue(i);
      final vacant = i['status'] == 'شاغر';
      switch (due) {
        case 'late':
          if (effStatus(i) != 'متأخرات') return false;
          break;
        case 'soon':
          if (vacant || d == null || d < 0 || d > soonDays) return false;
          break;
        case 'ok':
          if (d == null || d <= soonDays) return false;
          break;
        case 'none':
          if (d != null) return false;
          break;
      }
    }
    if (contract != null) {
      final n = contractDaysLeft(i);
      switch (contract) {
        case 'none':
          if (n != null) return false;
          break;
        case 'expired':
          if (n == null || n >= 0) return false;
          break;
        case 'soon':
          if (n == null || n < 0 || !contractNeedsAlert(i)) return false;
          break;
        case 'active':
          if (n == null || n < 0 || contractNeedsAlert(i)) return false;
          break;
      }
    }
    final rent = num0(i['rent_amount']);
    if (minRent != null && rent < minRent!) return false;
    if (maxRent != null && rent > maxRent!) return false;
    if (withBalance && num0(i['balance']) == 0) return false;
    if (withUtilities && utilitiesTotal(i) <= 0) return false;
    return true;
  }
}

/// يرتب نسخة من القائمة حسب النوع المختار («manual» يعني ترك ترتيب قاعدة البيانات)
List<Map<String, dynamic>> sortProps(
    List<Map<String, dynamic>> src, String mode) {
  final l = [...src];
  int nullLast(int? a, int? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  switch (mode) {
    case 'name':
      l.sort((a, b) => normSearch('${a['name'] ?? ''}')
          .compareTo(normSearch('${b['name'] ?? ''}')));
      break;
    case 'newest':
      l.sort((a, b) => (b['id'] as int).compareTo(a['id'] as int));
      break;
    case 'rent_desc':
      l.sort((a, b) => num0(b['rent_amount']).compareTo(num0(a['rent_amount'])));
      break;
    case 'rent_asc':
      l.sort((a, b) => num0(a['rent_amount']).compareTo(num0(b['rent_amount'])));
      break;
    case 'due':
      l.sort((a, b) => nullLast(daysUntilDue(a), daysUntilDue(b)));
      break;
    case 'contract':
      l.sort((a, b) => nullLast(contractDaysLeft(a), contractDaysLeft(b)));
      break;
    case 'status':
      const order = {'متأخرات': 0, 'مؤجر': 1, 'شاغر': 2};
      l.sort((a, b) =>
          (order[effStatus(a)] ?? 9).compareTo(order[effStatus(b)] ?? 9));
      break;
  }
  return l;
}

// ---------------------------------------------------------------------
//  نافذة اختيار الترتيب
// ---------------------------------------------------------------------
/// ترجع نوع الترتيب المختار، أو null إن أُغلقت. عند طلب الترتيب اليدوي بالسحب
/// تفتح شاشة السحب وتُرجع 'manual' إن حُفظ الترتيب.
Future<String?> showSortSheet(BuildContext context, String current,
    List<Map<String, dynamic>> items) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('ترتيب العقارات',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            for (final e in kSortModes.entries)
              ListTile(
                leading: Icon(e.value.icon),
                title: Text(e.value.label),
                trailing: current == e.key
                    ? Icon(Icons.check_circle,
                        color: Theme.of(ctx).colorScheme.primary)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: FilledButton.tonalIcon(
                onPressed: () async {
                  final saved = await Navigator.push<bool>(
                    ctx,
                    MaterialPageRoute(
                        builder: (_) => ReorderPropertiesScreen(items: items)),
                  );
                  if (ctx.mounted) {
                    Navigator.pop(ctx, saved == true ? 'manual' : null);
                  }
                },
                icon: const Icon(Icons.drag_handle),
                label: const Text('ترتيب العقارات بالسحب والإفلات'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// شاشة الترتيب اليدوي: اسحب العقار لأعلى أو لأسفل ثم احفظ
class ReorderPropertiesScreen extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  const ReorderPropertiesScreen({super.key, required this.items});

  @override
  State<ReorderPropertiesScreen> createState() =>
      _ReorderPropertiesScreenState();
}

class _ReorderPropertiesScreenState extends State<ReorderPropertiesScreen> {
  late List<Map<String, dynamic>> _list;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _list = [...widget.items];
  }

  Future<void> _save() async {
    await DB.saveOrder(_list.map((e) => e['id'] as int).toList());
    FX.play(Fx.edit);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ترتيب العقارات',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          TextButton.icon(
            onPressed: _changed ? _save : null,
            icon: const Icon(Icons.check),
            label: const Text('حفظ'),
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('اضغط مطولاً على مقبض الترتيب واسحب العقار إلى المكان الذي تريده، ثم اضغط «حفظ».',
                style: TextStyle(color: Colors.black54)),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              buildDefaultDragHandles: false,
              itemCount: _list.length,
              onReorderStart: (_) => FX.play(Fx.tap),
              onReorder: (o, n) {
                FX.play(Fx.move);
                setState(() {
                  if (n > o) n -= 1;
                  _list.insert(n, _list.removeAt(o));
                  _changed = true;
                });
              },
              itemBuilder: (_, k) {
                final it = _list[k];
                final color = statusColor(effStatus(it));
                return Padding(
                  key: ValueKey(it['id']),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: AppCard(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: color.withAlpha(30),
                        child: Icon(propertyTypeIcon(it['ptype']), color: color),
                      ),
                      title: Text('${it['name'] ?? ''}',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text('${it['tenant_name'] ?? ''}',
                          overflow: TextOverflow.ellipsis),
                      trailing: ReorderableDragStartListener(
                        index: k,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
//  البحث المتقدم
// ---------------------------------------------------------------------
class AdvancedSearchResult {
  final String query;
  final PropFilter filter;
  AdvancedSearchResult(this.query, this.filter);
}

Future<AdvancedSearchResult?> showAdvancedSearch(
    BuildContext context, String query, PropFilter filter) {
  return showModalBottomSheet<AdvancedSearchResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _AdvancedSearchSheet(query: query, filter: filter.copy()),
  );
}

class _AdvancedSearchSheet extends StatefulWidget {
  final String query;
  final PropFilter filter;
  const _AdvancedSearchSheet({required this.query, required this.filter});

  @override
  State<_AdvancedSearchSheet> createState() => _AdvancedSearchSheetState();
}

class _AdvancedSearchSheetState extends State<_AdvancedSearchSheet> {
  late final TextEditingController _q;
  late final TextEditingController _min;
  late final TextEditingController _max;
  late PropFilter _f;

  @override
  void initState() {
    super.initState();
    _f = widget.filter;
    _q = TextEditingController(text: widget.query);
    _min = TextEditingController(
        text: _f.minRent == null ? '' : plain(_f.minRent!));
    _max = TextEditingController(
        text: _f.maxRent == null ? '' : plain(_f.maxRent!));
  }

  @override
  void dispose() {
    _q.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.w800)),
      );

  /// مجموعة اختيارات (الضغط على المختار يلغيه)
  Widget _chips(Map<String, String> opts, String? value, void Function(String?) set) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final e in opts.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: value == e.key,
            onSelected: (s) => setState(() => set(s ? e.key : null)),
          ),
      ],
    );
  }

  void _apply() {
    _f.minRent = double.tryParse(_min.text.trim());
    _f.maxRent = double.tryParse(_max.text.trim());
    Navigator.pop(context, AdvancedSearchResult(_q.text.trim(), _f));
  }

  void _clear() {
    setState(() {
      _f = PropFilter();
      _q.clear();
      _min.clear();
      _max.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('بحث متقدم',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  TextButton(onPressed: _clear, child: const Text('مسح الكل')),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _q,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _apply(),
                        decoration: const InputDecoration(
                          labelText: 'كلمات البحث',
                          helperText:
                              'يبحث في كل شيء: الاسم، المستأجر، الهواتف، العنوان، الموقع، الملاحظات، الأرقام والتواريخ…',
                          helperMaxLines: 2,
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                      _title('الحالة'),
                      _chips({for (final s in kStatuses) s: s}, _f.status,
                          (v) => _f.status = v),
                      _title('موعد الإيجار'),
                      _chips(const {
                        'late': 'متأخر',
                        'soon': 'قريب الاستحقاق',
                        'ok': 'غير قريب',
                        'none': 'بدون تاريخ',
                      }, _f.due, (v) => _f.due = v),
                      _title('العقد'),
                      _chips(const {
                        'expired': 'منتهي',
                        'soon': 'ينتهي خلال شهرين',
                        'active': 'ساري',
                        'none': 'بدون عقد',
                      }, _f.contract, (v) => _f.contract = v),
                      _title('نطاق الإيجار الشهري'),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _min,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'من', isDense: true),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _max,
                              keyboardType: const TextInputType.numberWithOptions(
                                  decimal: true),
                              decoration: const InputDecoration(
                                  labelText: 'إلى', isDense: true),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      CheckboxListTile(
                        value: _f.withBalance,
                        onChanged: (v) => setState(() => _f.withBalance = v ?? false),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('عليه رصيد سابق / دائن'),
                      ),
                      CheckboxListTile(
                        value: _f.withUtilities,
                        onChanged: (v) =>
                            setState(() => _f.withUtilities = v ?? false),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('لديه مرافق أو خدمات مستحقة'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _apply,
                  icon: const Icon(Icons.search),
                  label: const Text('بحث'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
