class SystemWidgetDefinition {
  const SystemWidgetDefinition({
    required this.kind,
    required this.title,
    required this.size,
    required this.description,
  });

  final String kind;
  final String title;
  final String size;
  final String description;
}

class SystemWidgetGroup {
  const SystemWidgetGroup({
    required this.title,
    required this.description,
    required this.widgets,
  });

  final String title;
  final String description;
  final List<SystemWidgetDefinition> widgets;
}

const systemWidgetCatalog = <SystemWidgetGroup>[
  SystemWidgetGroup(
    title: '今日',
    description: '从快速一眼到完整安排，覆盖不同的桌面空间。',
    widgets: [
      SystemWidgetDefinition(
        kind: 'today_compact',
        title: '今日概览',
        size: '2×2',
        description: '今日日期、待办与日程的精简摘要',
      ),
      SystemWidgetDefinition(
        kind: 'today',
        title: '今日安排',
        size: '4×2',
        description: '默认尺寸，集中显示今日任务与日程',
      ),
      SystemWidgetDefinition(
        kind: 'today_expanded',
        title: '今日总览',
        size: '4×4',
        description: '为今日任务和日程保留更多内容空间',
      ),
    ],
  ),
  SystemWidgetGroup(
    title: '任务',
    description: '按桌面空间选择待办速览、列表或完整清单。',
    widgets: [
      SystemWidgetDefinition(
        kind: 'tasks_compact',
        title: '待办速览',
        size: '2×2',
        description: '待完成数量，放大后显示待办摘要',
      ),
      SystemWidgetDefinition(
        kind: 'tasks',
        title: '任务列表',
        size: '4×2',
        description: '按截止时间显示待办，区分逾期和无日期任务',
      ),
      SystemWidgetDefinition(
        kind: 'tasks_expanded',
        title: '任务清单',
        size: '4×4',
        description: '显示更多未完成任务，点击查看完整清单',
      ),
    ],
  ),
  SystemWidgetGroup(
    title: '日程',
    description: '查看接下来安排，或把多日日程铺在桌面。',
    widgets: [
      SystemWidgetDefinition(
        kind: 'agenda',
        title: '接下来日程',
        size: '4×2',
        description: '最近的日程时间与标题',
      ),
      SystemWidgetDefinition(
        kind: 'agenda_expanded',
        title: '日程列表',
        size: '4×4',
        description: '为即将到来的日程显示更多条目',
      ),
      SystemWidgetDefinition(
        kind: 'month',
        title: '月历',
        size: '4×4',
        description: '月视图与有日程的日期标记',
      ),
    ],
  ),
  SystemWidgetGroup(
    title: '快捷入口',
    description: '从桌面直达常用页面。',
    widgets: [
      SystemWidgetDefinition(
        kind: 'shortcuts_compact',
        title: '快捷入口',
        size: '2×1',
        description: '紧凑排列的常用页面入口',
      ),
      SystemWidgetDefinition(
        kind: 'shortcuts',
        title: '快捷入口',
        size: '4×1',
        description: '完整横向快捷入口',
      ),
    ],
  ),
];
