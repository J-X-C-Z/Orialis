import 'package:flutter/material.dart';
import 'package:lumina_ui/lumina_ui.dart';

/// Interactive examples for the fixed 28-entry Material component inventory.
/// Each example owns only transient state; it can be embedded in any scroll view.
class LuminaCatalogShowcase extends StatefulWidget {
  const LuminaCatalogShowcase({super.key});

  static const categories = <String>[
    'common-buttons',
    'floating-action-button',
    'extended-floating-action-button',
    'icon-button',
    'segmented-button',
    'badge',
    'linear-progress',
    'snackbar',
    'alert-dialog',
    'bottom-sheet',
    'card',
    'divider',
    'list-tile',
    'app-bar',
    'bottom-app-bar',
    'navigation-bar',
    'navigation-drawer',
    'navigation-rail',
    'tab-bar',
    'checkbox',
    'chip',
    'date-picker',
    'menu',
    'radio',
    'slider',
    'switch',
    'time-picker',
    'text-field',
  ];

  @override
  State<LuminaCatalogShowcase> createState() => _LuminaCatalogShowcaseState();
}

class _LuminaCatalogShowcaseState extends State<LuminaCatalogShowcase> {
  int _actions = 0;
  int _destination = 0;
  Set<int> _segments = {0};
  bool _indeterminate = false;
  bool _checked = false;
  bool _switch = true;
  bool _chipSelected = true;
  bool _chipVisible = true;
  int? _radio = 0;
  double _value = .4;
  RangeValues _range = const RangeValues(.2, .8);
  DateTime _date = DateTime(2026, 10, 2);
  DateTime _time = DateTime(2026, 10, 2, 9, 30);
  String _feedback = '';
  String _menuFeedback = '';
  final _note = TextEditingController();
  final _disabledNote = TextEditingController(text: 'Lumina');

  String tr(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  @override
  void dispose() {
    _note.dispose();
    _disabledNote.dispose();
    super.dispose();
  }

  void _act() => setState(() => _actions++);

  @override
  Widget build(BuildContext context) {
    final text = LuminaTheme.of(context).textTheme;
    final destinations = [
      NavigationDestination(
          icon: const Icon(Icons.today_outlined), label: tr('Today', '今日')),
      NavigationDestination(
          icon: const Icon(Icons.folder_outlined), label: tr('Files', '文件')),
      NavigationDestination(
          icon: const Icon(Icons.spa_outlined), label: tr('Quiet', '安静')),
    ];
    final names = [tr('Today', '今日'), tr('Files', '文件'), tr('Quiet', '安静')];
    return Column(
      key: const ValueKey('lumina-catalog'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('The component collection', '完整控件集'), style: text.titleLarge),
        const SizedBox(height: 6),
        Text(
            tr('28 categories. Try their selected, disabled, and interactive states.',
                '28 类控件，试试选中、禁用与交互状态。'),
            style: text.bodySmall),
        const SizedBox(height: 22),
        _group(tr('Actions', '操作')),
        _entry(
            'common-buttons',
            tr('Common buttons', '常用按钮'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final variant in LuminaButtonVariant.values)
                    LuminaMaterialButton(
                      variant: variant,
                      onPressed: _act,
                      child: Text(_buttonName(variant)),
                    ),
                  LuminaButton(onPressed: _act, child: Text(tr('Glass', '玻璃'))),
                  LuminaMaterialButton(
                      onPressed: null, child: Text(tr('Disabled', '已禁用'))),
                ]),
                const SizedBox(height: 10),
                Text(tr('Actions taken: $_actions', '已操作：$_actions 次'),
                    key: const ValueKey('action-count'), style: text.bodySmall),
              ],
            )),
        _entry(
            'floating-action-button',
            tr('Floating action button', '悬浮按钮'),
            HeroMode(
                enabled: false,
                child: Wrap(spacing: 12, runSpacing: 12, children: [
                  LuminaFloatingActionButton(
                      onPressed: _act,
                      icon: const Icon(Icons.add),
                      tooltip: tr('Add item', '添加项目')),
                  LuminaFloatingActionButton(
                      onPressed: null,
                      icon: const Icon(Icons.add),
                      tooltip: tr('Add unavailable', '暂不可添加')),
                ]))),
        _entry(
            'extended-floating-action-button',
            tr('Extended floating action button', '扩展悬浮按钮'),
            HeroMode(
                enabled: false,
                child: LuminaFloatingActionButton(
                    onPressed: _act,
                    icon: const Icon(Icons.edit_outlined),
                    label: Text(tr('Compose', '新建笔记'))))),
        _entry(
            'icon-button',
            tr('Icon button', '图标按钮'),
            Wrap(spacing: 12, children: [
              LuminaIconButton(
                  onPressed: _act,
                  icon: const Icon(Icons.favorite_outline),
                  tooltip: tr('Save favorite', '收藏')),
              LuminaIconButton(
                  onPressed: null,
                  icon: const Icon(Icons.favorite_outline),
                  tooltip: tr('Favorite unavailable', '暂不可收藏')),
            ])),
        _entry(
            'segmented-button',
            tr('Segmented buttons', '分段按钮'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LuminaMultiSegmented<int>(
                  segments: [
                    ButtonSegment(value: 0, label: Text(tr('Read', '阅读'))),
                    ButtonSegment(value: 1, label: Text(tr('Write', '写作'))),
                    ButtonSegment(
                        value: 2,
                        label: Text(tr('Rest', '休息')),
                        enabled: false),
                  ],
                  selected: _segments,
                  onSelectionChanged: (value) =>
                      setState(() => _segments = value),
                ),
                const SizedBox(height: 8),
                Text(
                    tr('${_segments.length} selected',
                        '已选择 ${_segments.length} 项'),
                    key: const ValueKey('segment-count'),
                    style: text.bodySmall),
              ],
            )),
        _group(tr('Communication', '状态反馈')),
        _entry(
            'badge',
            tr('Badge', '徽标'),
            Wrap(spacing: 28, runSpacing: 12, children: [
              LuminaBadge(
                  label: '$_actions',
                  child: const Icon(Icons.notifications_outlined)),
              const LuminaBadge(child: Icon(Icons.mail_outline)),
            ])),
        _entry(
            'linear-progress',
            tr('Linear progress', '线性进度'),
            Column(children: [
              LuminaLinearProgress(value: _value),
              const SizedBox(height: 12),
              TickerMode(
                  enabled: _indeterminate, child: const LuminaLinearProgress()),
              const SizedBox(height: 10),
              Text(tr('Determinate and indeterminate', '确定进度与不确定进度'),
                  style: text.bodySmall),
              const SizedBox(height: 8),
              LuminaButton(
                  onPressed: () =>
                      setState(() => _indeterminate = !_indeterminate),
                  child: Text(_indeterminate
                      ? tr('Pause progress', '暂停进度')
                      : tr('Animate progress', '播放进度'))),
            ])),
        _entry(
            'snackbar',
            tr('Message', '消息提示'),
            LuminaButton(
                key: const ValueKey('catalog-message'),
                onPressed: () => showLuminaMessage(
                    context, tr('A small step, saved.', '一个小步骤，已保存。')),
                child: Text(tr('Show message', '显示消息')))),
        _group(tr('Containment', '内容容器')),
        _entry(
            'alert-dialog',
            tr('Alert dialog', '对话框'),
            LuminaButton(
                key: const ValueKey('catalog-dialog'),
                onPressed: _showDialog,
                child: Text(tr('Review a change', '检查更改')))),
        _entry(
            'bottom-sheet',
            tr('Bottom sheet', '底部面板'),
            LuminaButton(
                key: const ValueKey('catalog-sheet'),
                onPressed: _showSheet,
                child: Text(tr('Open collection sheet', '打开合集面板')))),
        if (_feedback.isNotEmpty) ...[
          Semantics(
              liveRegion: true,
              child: Text(_feedback,
                  key: const ValueKey('catalog-feedback'),
                  style: text.bodySmall)),
          const SizedBox(height: 16),
        ],
        _entry(
            'card',
            tr('Cards', '卡片'),
            Column(children: [
              for (final depth in LuminaSurfaceDepth.values) ...[
                LuminaSurface(
                    depth: depth,
                    child: Text(_depthName(depth), style: text.bodyMedium)),
                const SizedBox(height: 8),
              ],
            ])),
        _entry(
            'divider',
            tr('Dividers', '分隔线'),
            Column(children: [
              const LuminaDivider(),
              const SizedBox(height: 8),
              const LuminaEngravedDivider(),
              const SizedBox(height: 8),
              SizedBox(
                  height: 32,
                  child: Row(children: [
                    Expanded(
                        child: Text(tr('Before', '之前'),
                            textAlign: TextAlign.center)),
                    const LuminaDivider(vertical: true),
                    Expanded(
                        child: Text(tr('After', '之后'),
                            textAlign: TextAlign.center)),
                  ])),
            ])),
        _entry(
            'list-tile',
            tr('List rows', '列表行'),
            Column(children: [
              LuminaListTile(
                  title: Text(tr('Open a field note', '打开手记')),
                  subtitle: Text(tr('Tap to increment the badge', '轻点增加徽标数字')),
                  leading: const Icon(Icons.description_outlined),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _act),
              const SizedBox(height: 8),
              LuminaListRow(
                  title: tr('Selected note', '已选笔记'),
                  selected: true,
                  onTap: _act),
              const SizedBox(height: 8),
              LuminaListRow(
                  title: tr('Unavailable note', '暂不可用的笔记'),
                  enabled: false,
                  onTap: _act),
            ])),
        _group(tr('Navigation', '导航')),
        _entry(
            'app-bar',
            tr('Top bar', '顶部栏'),
            LuminaTopBar(
              title: tr('Notes', '笔记'),
              leading: LuminaIconButton(
                  onPressed: _act,
                  icon: const Icon(Icons.menu),
                  tooltip: tr('Menu action', '菜单操作')),
              actions: [
                LuminaIconButton(
                    onPressed: _act,
                    icon: const Icon(Icons.search),
                    tooltip: tr('Search action', '搜索操作'))
              ],
            )),
        _entry(
            'bottom-app-bar',
            tr('Bottom app bar', '底部操作栏'),
            LuminaBottomAppBar(
              child: Row(children: [
                LuminaIconButton(
                    onPressed: _act,
                    icon: const Icon(Icons.menu),
                    tooltip: tr('Browse action', '浏览操作')),
                const Spacer(),
                LuminaIconButton(
                    onPressed: _act,
                    icon: const Icon(Icons.add),
                    tooltip: tr('Create action', '创建操作')),
              ]),
            )),
        _entry(
            'navigation-bar',
            tr('Navigation bar', '导航栏'),
            LuminaNavigationBar(
              destinations: destinations,
              selectedIndex: _destination,
              onDestinationSelected: _selectDestination,
            )),
        Text(
            tr('Current destination: ${names[_destination]}',
                '当前位置：${names[_destination]}'),
            key: const ValueKey('navigation-state'),
            style: text.bodySmall),
        const SizedBox(height: 16),
        _entry(
            'navigation-drawer',
            tr('Navigation drawer', '导航抽屉'),
            SizedBox(
              height: 252,
              child: LuminaNavigationDrawer(
                selectedIndex: _destination,
                onDestinationSelected: _selectDestination,
                children: [
                  for (var i = 0; i < names.length; i++)
                    NavigationDrawerDestination(
                        icon: destinations[i].icon, label: Text(names[i])),
                  NavigationDrawerDestination(
                      icon: const Icon(Icons.lock_outline),
                      label: Text(tr('Locked', '已锁定')),
                      enabled: false),
                ],
              ),
            )),
        _entry(
            'navigation-rail',
            tr('Navigation rail', '侧栏导航'),
            SizedBox(
              height: 242,
              child: Row(children: [
                LuminaNavigationRail(
                  destinations: [
                    for (var i = 0; i < names.length; i++)
                      NavigationRailDestination(
                          icon: destinations[i].icon, label: Text(names[i])),
                  ],
                  selectedIndex: _destination,
                  onDestinationSelected: _selectDestination,
                ),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                        tr('All navigation previews share the same selection.',
                            '三个导航示例共享选中状态。'),
                        style: text.bodySmall)),
              ]),
            )),
        _entry(
            'tab-bar',
            tr('Tabs', '标签页'),
            DefaultTabController(
              length: 3,
              child: Column(
                children: [
                  LuminaTabs(tabs: [for (final name in names) Tab(text: name)]),
                  const SizedBox(height: 10),
                  SizedBox(
                      height: 96,
                      child: TabBarView(children: [
                        for (var i = 0; i < names.length; i++)
                          Center(
                              child: Text(
                                  tr('${names[i]} collection', '${names[i]}合集'),
                                  style: text.bodyMedium)),
                      ])),
                ],
              ),
            )),
        _group(tr('Selection', '选择')),
        _entry(
            'checkbox',
            tr('Checkbox', '复选控件'),
            Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  LuminaCheck(
                      key: const ValueKey('catalog-check'),
                      value: _checked,
                      onChanged: (value) => setState(() => _checked = value)),
                  Text(_checked ? tr('Checked', '已勾选') : tr('Unchecked', '未勾选'),
                      key: const ValueKey('check-state')),
                  const LuminaCheck(value: true, onChanged: null),
                ])),
        _entry(
            'chip',
            tr('Chips', '标签'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              LuminaChip(
                  key: const ValueKey('catalog-chip'),
                  label: Text(tr('Focus', '专注')),
                  selected: _chipSelected,
                  onSelected: (value) => setState(() => _chipSelected = value)),
              LuminaChip(label: Text(tr('Unavailable', '暂不可用'))),
              if (_chipVisible)
                LuminaChip(
                    label: Text(tr('Removable', '可移除')),
                    onDeleted: () => setState(() => _chipVisible = false))
              else
                LuminaButton(
                    onPressed: () => setState(() => _chipVisible = true),
                    child: Text(tr('Restore chip', '恢复标签'))),
            ])),
        _entry(
            'date-picker',
            tr('Date picker', '日期选择'),
            LuminaButton(
                key: const ValueKey('catalog-date'),
                onPressed: _pickDate,
                child: Text(tr(
                    'Date: ${_date.year}/${_date.month}/${_date.day}',
                    '日期：${_date.year}/${_date.month}/${_date.day}')))),
        _entry(
            'menu',
            tr('Menu', '菜单'),
            LuminaMenuAnchor(
              menuChildren: [
                LuminaMenuItem(
                    onPressed: () => setState(
                        () => _menuFeedback = tr('Note duplicated.', '已复制笔记。')),
                    child: Text(tr('Duplicate note', '复制笔记'))),
                LuminaMenuItem(
                    onPressed: () => setState(
                        () => _menuFeedback = tr('Note archived.', '已归档笔记。')),
                    child: Text(tr('Archive note', '归档笔记'))),
                LuminaMenuItem(
                    onPressed: null,
                    child: Text(tr('Share unavailable', '暂不可分享'))),
              ],
              builder: (context, controller, child) => LuminaButton(
                key: const ValueKey('catalog-menu'),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                child: Text(tr('Note options', '笔记选项')),
              ),
            )),
        if (_menuFeedback.isNotEmpty) ...[
          Semantics(
              liveRegion: true,
              child: Text(_menuFeedback, style: text.bodySmall)),
          const SizedBox(height: 16),
        ],
        _entry(
            'radio',
            tr('Radio choices', '单项选择'),
            LuminaRadioGroup<int>(
                groupValue: _radio,
                onChanged: (value) => setState(() => _radio = value),
                child: Wrap(spacing: 12, runSpacing: 8, children: [
                  for (var i = 0; i < 3; i++)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      LuminaRadio<int>(
                          key: ValueKey('catalog-radio-$i'),
                          value: i,
                          groupValue: _radio,
                          onChanged: i == 2
                              ? null
                              : (value) => setState(() => _radio = value)),
                      Text([
                        tr('Daily', '每天'),
                        tr('Weekly', '每周'),
                        tr('Locked', '已锁定')
                      ][i]),
                    ]),
                ]))),
        _entry(
            'slider',
            tr('Sliders', '滑块'),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                    tr('Value: ${(_value * 100).round()}%',
                        '数值：${(_value * 100).round()}%'),
                    key: const ValueKey('slider-state'),
                    style: text.bodySmall),
                LuminaValueSlider(
                    key: const ValueKey('catalog-discrete'),
                    value: _value,
                    divisions: 10,
                    onChanged: (value) => setState(() => _value = value)),
                LuminaContinuousSlider(
                    key: const ValueKey('catalog-continuous'),
                    value: _value,
                    onChanged: (value) => setState(() => _value = value)),
                LuminaRangeSlider(
                    key: const ValueKey('catalog-range'),
                    values: _range,
                    onChanged: (value) => setState(() => _range = value)),
                Text(
                    tr('Range: ${(_range.start * 100).round()}–${(_range.end * 100).round()}%',
                        '区间：${(_range.start * 100).round()}–${(_range.end * 100).round()}%'),
                    style: text.bodySmall),
                const LuminaContinuousSlider(value: .6, onChanged: null),
              ],
            )),
        _entry(
            'switch',
            tr('Switches', '开关'),
            Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  LuminaSwitch(
                      key: const ValueKey('catalog-switch'),
                      value: _switch,
                      onChanged: (value) => setState(() => _switch = value)),
                  Text(_switch ? tr('On', '开启') : tr('Off', '关闭'),
                      key: const ValueKey('switch-state')),
                  const LuminaSwitch(value: true, onChanged: null),
                ])),
        _entry(
            'time-picker',
            tr('Time picker', '时间选择'),
            LuminaButton(
                key: const ValueKey('catalog-time'),
                onPressed: _pickTime,
                child:
                    Text(tr('Time: ${_clock(_time)}', '时间：${_clock(_time)}')))),
        _group(tr('Text input', '文字输入')),
        _entry(
            'text-field',
            tr('Text fields', '文本框'),
            Column(children: [
              LuminaTextField(
                  key: const ValueKey('catalog-input'),
                  controller: _note,
                  label: tr('Collection note', '合集笔记'),
                  hint: tr('Write a thought…', '记下一点想法…'),
                  maxLength: 80,
                  onChanged: (_) => setState(() {})),
              const SizedBox(height: 8),
              Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                      tr('${_note.text.length}/80 characters',
                          '${_note.text.length}/80 字符'),
                      key: const ValueKey('input-count'),
                      style: text.bodySmall)),
              const SizedBox(height: 12),
              LuminaTextField(
                  controller: _disabledNote,
                  label: tr('Disabled input', '已禁用的输入框'),
                  enabled: false),
            ])),
      ],
    );
  }

  void _selectDestination(int value) => setState(() => _destination = value);

  String _clock(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  String _buttonName(LuminaButtonVariant variant) => switch (variant) {
        LuminaButtonVariant.filled => tr('Filled', '实色'),
        LuminaButtonVariant.tonal => tr('Tonal', '柔色'),
        LuminaButtonVariant.elevated => tr('Elevated', '凸起'),
        LuminaButtonVariant.outlined => tr('Outlined', '描边'),
        LuminaButtonVariant.text => tr('Text', '文字'),
      };

  String _depthName(LuminaSurfaceDepth depth) => switch (depth) {
        LuminaSurfaceDepth.normal => tr('A calm surface', '平静表面'),
        LuminaSurfaceDepth.raised => tr('A raised surface', '凸起表面'),
        LuminaSurfaceDepth.recessed => tr('A recessed surface', '内嵌表面'),
      };

  Widget _group(String title) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 16),
        child:
            Text(title, style: LuminaTheme.of(context).textTheme.titleMedium),
      );

  Widget _entry(String id, String title, Widget child) => Padding(
        key: ValueKey('catalog-category-$id'),
        padding: const EdgeInsets.only(bottom: 20),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: LuminaTheme.of(context).textTheme.labelMedium),
          const SizedBox(height: 10),
          Align(alignment: AlignmentDirectional.centerStart, child: child),
        ]),
      );

  Future<void> _showDialog() async {
    final accepted = await showLuminaDialog<bool>(
      context: context,
      builder: (dialogContext) => LuminaDialog(
        title: tr('Keep this change?', '保留这次更改？'),
        content: Text(
            tr('This preview keeps all changes in memory.', '所有更改仅保留在此示例中。')),
        actions: [
          LuminaButton(
              primary: false,
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(tr('Cancel', '取消'))),
          LuminaButton(
              key: const ValueKey('catalog-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(tr('Keep change', '保留更改'))),
        ],
      ),
    );
    if (mounted && accepted != null) {
      setState(() => _feedback = accepted
          ? tr('Change kept.', '已保留更改。')
          : tr('Change cancelled.', '已取消更改。'));
    }
  }

  Future<void> _showSheet() async {
    await showLuminaSheet<void>(
      context: context,
      builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('A collection of small ideas', '收集一点小想法'),
                style: LuminaTheme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Text(tr('The sheet inherits the same Lumina material and type.',
                '面板延续相同的 Lumina 材质与字体。')),
            const SizedBox(height: 18),
            LuminaButton(
                key: const ValueKey('catalog-close-sheet'),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: Text(tr('Close collection', '关闭合集'))),
          ]),
    );
  }

  Future<void> _pickDate() async {
    final value = await showLuminaDatePicker(
        context: context,
        initialDate: _date,
        firstDate: DateTime(2026),
        lastDate: DateTime(2027, 12, 31));
    if (mounted && value != null) setState(() => _date = value);
  }

  Future<void> _pickTime() async {
    final value =
        await showLuminaTimePicker(context: context, initialTime: _time);
    if (mounted && value != null) setState(() => _time = value);
  }
}
