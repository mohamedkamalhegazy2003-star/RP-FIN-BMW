import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import 'assistant.dart';
import 'auth.dart';
import 'contract.dart';
import 'db.dart';
import 'finance.dart';
import 'fx.dart';
import 'paper_picker.dart';
import 'pdf_export.dart';
import 'prop_tools.dart';
import 'property_detail.dart';
import 'property_form.dart';
import 'report_screen.dart';
import 'security.dart';
import 'smooth.dart';
import 'tenants_screen.dart';
import 'utils.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _payments = [];
  Map<int, Map<String, List<String>>> _atts = {};
  bool _alertsShown = false;
  String _query = '';
  String? _filter;
  PropFilter _adv = PropFilter();
  final TextEditingController _searchC = TextEditingController();
  String _sort = 'manual';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final savedSort = await DB.getSetting('prop_sort');
    if (savedSort != null && kSortModes.containsKey(savedSort)) _sort = savedSort;
    final data = await DB.all();
    final pays = await DB.payments();
    final atts = await DB.attachmentMap();
    if (!mounted) return;
    setState(() {
      _items = data;
      _payments = pays;
      _atts = atts;
      _loading = false;
    });
    if (!_alertsShown && (_alerts.isNotEmpty || _contractAlerts.isNotEmpty)) {
      _alertsShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAlerts();
      });
    }
  }

  List<Map<String, dynamic>> get _alerts => computeAlerts(_items);
  List<Map<String, dynamic>> get _contractAlerts => computeContractAlerts(_items);

  Future<void> _renew(Map<String, dynamic> item) async {
    final ok = await showRenewDialog(context, item);
    if (ok) await _load();
  }

  Future<void> _contractMessage(Map<String, dynamic> item) async {
    final saved = await showContractMessageDialog(context, item);
    if (saved) await _load();
  }

  Future<void> _whatsappContract(Map<String, dynamic> item) async {
    final t = item['tenant_name'];
    final n = item['name'];
    final e = contractEndOf(item);
    final left = contractDaysLeft(item) ?? 0;
    final endStr = e == null ? '' : fmtDate(e);
    final msg = left < 0
        ? 'أهلاً $t، نود إحاطتكم بأن عقد إيجار $n انتهى بتاريخ $endStr. برجاء التواصل معنا لتجديد العقد.'
        : 'أهلاً $t، نود تذكيركم بأن عقد إيجار $n ينتهي بتاريخ $endStr. برجاء التواصل معنا لتجديد العقد.';
    await launchWa(context, phoneOf(item), msg);
  }

  Widget _contractTile(BuildContext ctx, Map<String, dynamic> it) {
    final left = contractDaysLeft(it) ?? 0;
    final c = left < 0 ? const Color(0xFFC62828) : const Color(0xFFEF6C00);
    return ListTile(
      isThreeLine: true,
      leading: CircleAvatar(
        backgroundColor: c.withAlpha(30),
        child: Icon(Icons.description_outlined, color: c),
      ),
      title: Text('${it['tenant_name']} - ${it['name']}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
          '${left < 0 ? 'العقد منتهي' : 'العقد يقارب على الانتهاء'}\n${contractText(it)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'واتساب',
            icon: const Icon(Icons.chat, color: Color(0xFF2E7D32)),
            onPressed: () => _whatsappContract(it),
          ),
        ],
      ),
    );
  }

  Future<void> _openForm([Map<String, dynamic>? item]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PropertyFormScreen(property: item)),
    );
    if (saved == true) {
      FX.play(Fx.edit);
      await _load();
      if (mounted) toast(context, item == null ? 'تمت إضافة العقار' : 'تم تحديث العقار');
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PropertyDetailScreen(propertyId: item['id'] as int)),
    );
    await _load();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف العقار'),
        content: Text('هل تريد حذف "${item['name']}" نهائياً؟\n(سجل الإيصالات القديمة يبقى محفوظاً)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok == true && mounted && await biometricAuth(context, 'تأكيد حذف العقار')) {
      final id = item['id'] as int;
      final files = [...?_atts[id]?['id'], ...?_atts[id]?['contract']];
      await DB.delete(id);
      for (final f in files) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      FX.play(Fx.delete);
      await _load();
      if (mounted) toast(context, 'تم حذف العقار');
    }
  }

  Future<void> _whatsapp(Map<String, dynamic> item, String type) async {
    final a = fmt(totalDue(item));
    final t = item['tenant_name'];
    final n = item['name'];
    final d = parseDue(item['due_date']);
    final dueStr = d == null ? '' : ' (تاريخ الاستحقاق ${fmtDate(d)})';
    String msg;
    if (type == 'reminder') {
      msg = 'أهلاً $t، نود تذكيرك بقرب موعد سداد إيجار $n وقيمته الإجمالية $a$dueStr.';
    } else if (type == 'late') {
      msg = 'عزيزي $t، نود إحاطتكم بتأخر سداد مستحقات $n وقيمتها $a$dueStr. نرجو السداد في أقرب وقت.';
    } else {
      msg = 'شكراً لك $t على التزامك بسداد مستحقات $n.';
    }
    await launchWa(context, phoneOf(item), msg);
  }

  Future<void> _pay(Map<String, dynamic> item) async {
    final ok = await showPayDialog(context, item);
    if (ok) await _load();
  }

  List<Map<String, dynamic>> get _filtered {
    final l = _items.where((i) {
      if (_filter != null && effStatus(i) != _filter) return false;
      if (!_adv.matches(i)) return false;
      return propMatchesQuery(i, _query);
    }).toList();
    return sortProps(l, _sort);
  }

  Future<void> _openSort() async {
    final r = await showSortSheet(context, _sort, _items);
    if (r == null) return;
    FX.play(Fx.move);
    await DB.setSetting('prop_sort', r);
    _sort = r;
    await _load();
  }

  Future<void> _openAdvanced() async {
    final r = await showAdvancedSearch(context, _query, _adv);
    if (r == null) return;
    setState(() {
      _query = r.query;
      _adv = r.filter;
      _searchC.text = r.query;
    });
  }

  // ---------------- التنبيهات ----------------
  void _showAlerts() {
    final list = _alerts;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('التنبيهات (${list.length + _contractAlerts.length})',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              if (list.isEmpty && _contractAlerts.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('لا توجد تنبيهات حالياً'))
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length + _contractAlerts.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, k) {
                      if (k >= list.length) {
                        return _contractTile(ctx, _contractAlerts[k - list.length]);
                      }
                      final it = list[k];
                      final d = daysUntilDue(it);
                      final late = d == null || d < 0;
                      final c = late ? const Color(0xFFC62828) : const Color(0xFFEF6C00);
                      final dd = parseDue(it['due_date']);
                      String sub;
                      if (d == null || dd == null) {
                        sub = 'متأخر (لم يُحدد تاريخ استحقاق)';
                      } else if (d < 0) {
                        sub = 'متأخر منذ ${fmtDate(dd)} (${-d} يوم)';
                      } else if (d == 0) {
                        sub = 'يستحق اليوم';
                      } else {
                        sub = 'يستحق ${fmtDate(dd)} (بعد $d يوم)';
                      }
                      return ListTile(
                        isThreeLine: true,
                        leading: CircleAvatar(
                          backgroundColor: c.withAlpha(30),
                          child: Icon(late ? Icons.warning_amber_rounded : Icons.schedule,
                              color: c),
                        ),
                        title: Text('${it['tenant_name']} - ${it['name']}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('$sub\nالمستحق: ${fmt(totalDue(it))}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'واتساب',
                              icon: const Icon(Icons.chat, color: Color(0xFF2E7D32)),
                              onPressed: () => _whatsapp(it, late ? 'late' : 'reminder'),
                            ),
                            IconButton(
                              tooltip: 'تسجيل سداد',
                              icon: const Icon(Icons.payments_outlined),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _pay(it);
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['العقارات', 'المستأجرون', 'التقارير المالية'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab], style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'المساعد المالي',
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) =>
                        AssistantScreen(items: _items, pays: _payments))),
            icon: const Icon(Icons.auto_awesome),
          ),
          IconButton(
            tooltip: 'التنبيهات',
            onPressed: _showAlerts,
            icon: Badge(
              label: Text('${_alerts.length + _contractAlerts.length}'),
              isLabelVisible: _alerts.isNotEmpty || _contractAlerts.isNotEmpty,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            tooltip: 'الإعدادات',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, 0.02), end: Offset.zero)
                .animate(anim),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(_loading ? 'loading' : 'tab$_tab'),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : (_tab == 0
                  ? _propertiesTab()
                  : _tab == 1
                      ? TenantsTab(items: _items, onReload: _load)
                      : _reportsTab()),
        ),
      ),
      floatingActionButton: AnimatedScale(
        scale: _tab == 0 ? 1 : 0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutBack,
        child: FloatingActionButton.extended(
          onPressed: _tab == 0 ? () => _openForm() : null,
          icon: const Icon(Icons.add),
          label: const Text('إضافة عقار'),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          if (i != _tab) FX.play(Fx.tap);
          setState(() => _tab = i);
        },
        destinations: [
          NavigationDestination(
              icon: Icon(Icons.home_work_outlined),
              selectedIcon: Icon(Icons.home_work),
              label: 'العقارات'),
          NavigationDestination(
              icon: Badge(
                label: Text('${_alerts.length + _contractAlerts.length}'),
                isLabelVisible: _alerts.isNotEmpty || _contractAlerts.isNotEmpty,
                child: const Icon(Icons.people_outline),
              ),
              selectedIcon: const Icon(Icons.people),
              label: 'المستأجرون'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'التقارير'),
        ],
      ),
    );
  }

  // ---------------- العقارات ----------------
  Widget _propertiesTab() {
    final list = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchC,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  decoration: InputDecoration(
                    hintText: 'بحث سريع في كل بيانات العقارات',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _query = '';
                              _searchC.clear();
                            }),
                          ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                tooltip: 'بحث متقدم',
                onPressed: _openAdvanced,
                icon: Badge(
                  label: Text('${_adv.count}'),
                  isLabelVisible: _adv.isActive,
                  child: const Icon(Icons.tune),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'ترتيب العقارات',
                onPressed: _openSort,
                icon: const Icon(Icons.swap_vert),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ChoiceChip(
                  label: const Text('الكل'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
              ),
              for (final s in kStatuses)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    label: Text(s),
                    selected: _filter == s,
                    onSelected: (_) => setState(() => _filter = s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => FadeSlideIn(
                      key: ValueKey(list[i]['id']),
                      index: i,
                      child: _propertyCard(list[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    final has = _items.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(has ? Icons.search_off : Icons.apartment, size: 72, color: Colors.black26),
            const SizedBox(height: 12),
            Text(
              has ? 'لا توجد نتائج مطابقة' : 'لا توجد عقارات بعد\nاضغط "إضافة عقار" للبدء',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _propertyCard(Map<String, dynamic> item) {
    final color = statusColor(effStatus(item));
    final total = totalDue(item);
    final other = num0(item['other_amount']);
    final otherNote = (item['other_note'] ?? '').toString();
    final bal = num0(item['balance']);
    final atts = _atts[item['id'] as int];
    return AppCard(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: CircleAvatar(
            backgroundColor: color.withAlpha(30),
            child: Icon(propertyTypeIcon(item['ptype']), color: color),
          ),
          title: Text('${item['name'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                _statusChip(effStatus(item), color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${item['tenant_name'] ?? ''}',
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          trailing: Text(fmt(total),
              style: TextStyle(fontWeight: FontWeight.w800, color: color)),
          children: [
            _info(Icons.tag, 'كود العقار', '${item['id']}'),
            _info(Icons.location_on_outlined, 'الموقع', '${item['location'] ?? ''}'),
            _info(Icons.place_outlined, 'العنوان', '${item['address'] ?? ''}'),
            _info(Icons.phone_outlined, 'الهاتف', '${item['tenant_phone'] ?? ''}'),
            _info(Icons.phone_forwarded_outlined, 'هاتف بديل', '${item['alt_phone'] ?? ''}'),
            _info(Icons.event_outlined, 'الاستحقاق', dueText(item)),
            _info(Icons.description_outlined, 'انتهاء العقد', contractText(item)),
            _info(Icons.savings_outlined, 'التأمين', fmt(num0(item['deposit_amount']))),
            const Divider(height: 24),
            _info(Icons.payments_outlined, 'الإيجار', fmt(num0(item['rent_amount']))),
            _info(Icons.bolt_outlined, 'كهرباء', fmt(num0(item['electricity']))),
            _info(Icons.water_drop_outlined, 'مياه', fmt(num0(item['water']))),
            _info(Icons.local_fire_department_outlined, 'غاز', fmt(num0(item['gas']))),
            if (other > 0)
              _info(Icons.room_service_outlined,
                  otherNote.isEmpty ? 'خدمات أخرى' : 'خدمات ($otherNote)', fmt(other)),
            if (bal != 0)
              _info(Icons.account_balance_wallet_outlined,
                  bal > 0 ? 'رصيد سابق' : 'رصيد دائن', fmt(bal.abs())),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('إجمالي المستحق',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  Text(fmt(total),
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16, color: color)),
                ],
              ),
            ),
            if (atts != null) ...[
              _thumbs('صور البطاقة', atts['id'] ?? []),
              _thumbs('صور العقد', atts['contract'] ?? []),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _pay(item),
                icon: const Icon(Icons.payments),
                label: const Text('تسجيل سداد الإيجار'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _renew(item),
                icon: const Icon(Icons.autorenew),
                label: const Text('تجديد العقد'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _contractMessage(item),
                icon: const Icon(Icons.chat, color: Color(0xFF2E7D32)),
                label: const Text('رسالة بقيمة العقد الجديدة'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _openDetail(item),
                icon: const Icon(Icons.account_balance_outlined),
                label: const Text('الحساب والمدفوعات والمرافق'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _waButton('تذكير', Icons.notifications_active,
                      const Color(0xFFF9A825), () => _whatsapp(item, 'reminder')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('تأخير', Icons.warning_amber_rounded,
                      const Color(0xFFC62828), () => _whatsapp(item, 'late')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('شكر', Icons.favorite, const Color(0xFF2E7D32),
                      () => _whatsapp(item, 'thanks')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openForm(item),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('تعديل'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _delete(item),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('حذف'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String? s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: c.withAlpha(30), borderRadius: BorderRadius.circular(8)),
        child: Text(s ?? '',
            style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
      );

  Widget _info(IconData icon, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.black45),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: Colors.black54)),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _waButton(String label, IconData icon, Color c, VoidCallback onTap) =>
      FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: c,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );

  Widget _thumbs(String label, List<String> paths) {
    final ok = paths.where((e) => File(e).existsSync()).toList();
    if (ok.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label (${ok.length})', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ok.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => Dialog(
                    child: InteractiveViewer(child: Image.file(File(ok[i]))),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(ok[i]), width: 64, height: 64, fit: BoxFit.cover),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- التقارير المالية المجمعة ----------------
  Widget _reportsTab() {
    double rent = 0, utils = 0, deposit = 0, due = 0;
    var rented = 0, vacant = 0, late = 0;
    for (final i in _items) {
      rent += num0(i['rent_amount']);
      utils += utilitiesTotal(i);
      deposit += num0(i['deposit_amount']);
      final es = effStatus(i);
      if (es == 'متأخرات') {
        due += totalDue(i);
        late++;
      } else if (es == 'شاغر') {
        vacant++;
      } else {
        rented++;
      }
    }
    final key = intl.DateFormat('yyyy-MM').format(DateTime.now());
    double month = 0, allPaid = 0;
    for (final pm in _payments) {
      allPaid += num0(pm['amount']);
      if ((pm['paid_at'] ?? '').toString().startsWith(key)) month += num0(pm['amount']);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        FadeSlideIn(
          child: AppCard(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
          onTap: () {
            final l = _items.where((i) => num0(i['rent_amount']) > 0).toList()
              ..sort((a, b) =>
                  num0(b['rent_amount']).compareTo(num0(a['rent_amount'])));
            _showBreakdown('الإيجارات الشهرية', const Color(0xFF1B5E85), [
              for (final i in l)
                _BRow('${i['name'] ?? ''} - ${_who(i)}', effStatus(i),
                    fmt(num0(i['rent_amount'])),
                    icon: Icons.apartment)
            ], total: fmt(rent), empty: 'لا توجد إيجارات مسجلة');
          },
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                  colors: [Color(0xFF1B5E85), Color(0xFF2A8AB8)]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('إجمالي الإيجارات الشهرية',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Text(fmt(rent),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('${_items.length} عقار  •  مؤجر $rented  •  شاغر $vacant  •  متأخرات $late',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          ),
        )),
        const SizedBox(height: 12),
        FadeSlideIn(index: 1, child: Row(children: [
          _stat('المرافق والخدمات', fmt(utils), Icons.bolt, const Color(0xFFEF6C00),
              onTap: () {
            final l = _items.where((i) => utilitiesTotal(i) > 0).toList()
              ..sort((a, b) => utilitiesTotal(b).compareTo(utilitiesTotal(a)));
            _showBreakdown('المرافق والخدمات', const Color(0xFFEF6C00), [
              for (final i in l)
                _BRow(
                  '${i['name'] ?? ''} - ${_who(i)}',
                  [
                    if (num0(i['electricity']) > 0) 'كهرباء ${fmt(num0(i['electricity']))}',
                    if (num0(i['water']) > 0) 'مياه ${fmt(num0(i['water']))}',
                    if (num0(i['gas']) > 0) 'غاز ${fmt(num0(i['gas']))}',
                    if (num0(i['other_amount']) > 0)
                      '${(i['other_note'] ?? '').toString().isEmpty ? 'خدمات أخرى' : i['other_note']} ${fmt(num0(i['other_amount']))}',
                  ].join(' • '),
                  fmt(utilitiesTotal(i)),
                  icon: Icons.bolt,
                )
            ], total: fmt(utils), empty: 'لا توجد مرافق أو خدمات مستحقة');
          }),
          const SizedBox(width: 12),
          _stat('التأمينات', fmt(deposit), Icons.savings, const Color(0xFF00897B),
              onTap: () {
            final l = _items.where((i) => num0(i['deposit_amount']) > 0).toList()
              ..sort((a, b) =>
                  num0(b['deposit_amount']).compareTo(num0(a['deposit_amount'])));
            _showBreakdown('التأمينات', const Color(0xFF00897B), [
              for (final i in l)
                _BRow('${i['name'] ?? ''}', _who(i), fmt(num0(i['deposit_amount'])),
                    icon: Icons.savings)
            ], total: fmt(deposit), empty: 'لا توجد تأمينات مسجلة');
          }),
        ])),
        const SizedBox(height: 12),
        FadeSlideIn(index: 2, child: Row(children: [
          _stat('متأخرات مستحقة', fmt(due), Icons.warning_amber_rounded,
              const Color(0xFFC62828), onTap: () {
            final l = _items.where((i) => effStatus(i) == 'متأخرات').toList()
              ..sort((a, b) => totalDue(b).compareTo(totalDue(a)));
            _showBreakdown('المتأخرات المستحقة', const Color(0xFFC62828), [
              for (final i in l)
                _BRow('${i['name'] ?? ''} - ${_who(i)}', 'الاستحقاق: ${dueText(i)}',
                    fmt(totalDue(i)),
                    icon: Icons.warning_amber_rounded)
            ], total: fmt(due), empty: 'لا توجد متأخرات ✅');
          }),
          const SizedBox(width: 12),
          _stat('عقارات شاغرة', '$vacant', Icons.key, const Color(0xFF6A1B9A),
              onTap: () {
            final l = _items.where((i) => effStatus(i) == 'شاغر').toList();
            _showBreakdown('العقارات الشاغرة', const Color(0xFF6A1B9A), [
              for (final i in l)
                _BRow('${i['name'] ?? ''}', '${i['address'] ?? ''}'.trim(),
                    fmt(num0(i['rent_amount'])),
                    icon: Icons.key)
            ], total: '$vacant', empty: 'لا توجد عقارات شاغرة');
          }),
        ])),
        const SizedBox(height: 12),
        FadeSlideIn(index: 3, child: Row(children: [
          _stat('المحصّل هذا الشهر', fmt(month), Icons.account_balance_wallet,
              const Color(0xFF2E7D32), onTap: () {
            final l = _payments
                .where((pm) => (pm['paid_at'] ?? '').toString().startsWith(key))
                .toList();
            _showBreakdown('المحصّل هذا الشهر', const Color(0xFF2E7D32), [
              for (final pm in l)
                _BRow(
                    '${pm['property_name'] ?? ''} - ${pm['tenant_name'] ?? ''}',
                    'إيصال ${receiptNo(pm)} • ${kindLabel(pm['kind'])} • ${fmtDateStr(pm['paid_at'])}',
                    fmt(num0(pm['amount'])),
                    icon: Icons.receipt_long)
            ], total: fmt(month), empty: 'لا توجد مدفوعات هذا الشهر');
          }),
          const SizedBox(width: 12),
          _stat('إجمالي المحصّل', fmt(allPaid), Icons.savings_outlined,
              const Color(0xFF1B5E85), onTap: () {
            final sums = <String, double>{};
            final cnt = <String, int>{};
            for (final pm in _payments) {
              final k = '${pm['property_name'] ?? ''} - ${pm['tenant_name'] ?? ''}';
              sums[k] = (sums[k] ?? 0) + num0(pm['amount']);
              cnt[k] = (cnt[k] ?? 0) + 1;
            }
            final keys = sums.keys.toList()
              ..sort((a, b) => sums[b]!.compareTo(sums[a]!));
            _showBreakdown('إجمالي المحصّل لكل عقار', const Color(0xFF1B5E85), [
              for (final k in keys)
                _BRow(k, '${cnt[k]} دفعة', fmt(sums[k]!), icon: Icons.savings_outlined)
            ], total: fmt(allPaid), empty: 'لا توجد مدفوعات بعد');
          }),
        ])),
        const SizedBox(height: 16),
        FadeSlideIn(index: 4, child: FilledButton.icon(
          onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      ReportFilterScreen(props: _items, pays: _payments))),
          icon: const Icon(Icons.picture_as_pdf),
          label: const Text('التقرير الشامل (فلترة وتصدير PDF)'),
        )),
        const SizedBox(height: 24),
        const Text('سجل المدفوعات والإيصالات',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        if (_payments.isEmpty)
          const Text('لا توجد مدفوعات مسجلة بعد. سجّل سداداً من بطاقة العقار.',
              style: TextStyle(color: Colors.black54))
        else
          for (final pm in _payments.take(50))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  title: Text('${receiptNo(pm)} • ${pm['property_name']}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${pm['tenant_name']} • ${fmt(num0(pm['amount']))} • ${fmtDateStr(pm['paid_at'])}'),
                  trailing: IconButton.filledTonal(
                    onPressed: () => printReceiptAsk(context, pm),
                    icon: const Icon(Icons.picture_as_pdf),
                    tooltip: 'طباعة الإيصال',
                  ),
                ),
              ),
            ),
      ],
    );
  }

  Widget _stat(String title, String value, IconData icon, Color c,
          {VoidCallback? onTap}) =>
      Expanded(
        child: AppCard(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                    radius: 18,
                    backgroundColor: c.withAlpha(30),
                    child: Icon(icon, color: c, size: 20)),
                const SizedBox(height: 10),
                Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(value,
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800, color: c)),
                ),
              ],
            ),
          ),
          ),
        ),
      );

  // ---------------- تفاصيل كل رقم في التقارير ----------------
  /// نافذة تعرض مكوّنات الرقم: كل عقار/مستأجر وقيمته
  void _showBreakdown(String title, Color c, List<_BRow> rows,
      {String? total, String empty = 'لا توجد بيانات'}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                    if (total != null)
                      Text(total,
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800, color: c)),
                  ],
                ),
              ),
              if (rows.isEmpty)
                Padding(
                    padding: const EdgeInsets.all(24), child: Text(empty))
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, k) {
                      final r = rows[k];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: c.withAlpha(30),
                          child: Icon(r.icon ?? Icons.apartment, color: c, size: 20),
                        ),
                        title: Text(r.title,
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: r.sub.isEmpty ? null : Text(r.sub),
                        trailing: r.amount == null
                            ? null
                            : Text(r.amount!,
                                style: TextStyle(
                                    fontWeight: FontWeight.w800, color: c)),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  String _who(Map<String, dynamic> i) {
    final t = '${i['tenant_name'] ?? ''}'.trim();
    return t.isEmpty ? 'بدون مستأجر' : t;
  }
}

class _BRow {
  final String title;
  final String sub;
  final String? amount;
  final IconData? icon;
  _BRow(this.title, this.sub, this.amount, {this.icon});
}
