/// Gateway commands verified against the installed Hermes command registry and
/// gateway handlers (2026-09-26). CLI-only commands deliberately do not appear.
class HermesShortcut {
  const HermesShortcut(
    this.title,
    this.command,
    this.description, {
    this.editable = false,
  });

  final String title;
  final String command;
  final String description;
  final bool editable;
}

const hermesShortcuts = [
  HermesShortcut('查看状态', '/status', '查看当前模型与上下文使用情况'),
  HermesShortcut('可用模型', '/model', '列出模型；切换时使用下一项填写模型名称'),
  HermesShortcut('切换模型', '/model ', '填写模型名称；默认只影响当前 Hermes 会话', editable: true),
  HermesShortcut('压缩上下文', '/compress', '压缩较长的对话，可继续保留重点'),
  HermesShortcut('恢复会话', '/resume', '列出可恢复的 Hermes 会话'),
  HermesShortcut(
    'Hermes 会话标题',
    '/title ',
    '填写 Hermes 上下文名称，不改变 App 会话名称',
    editable: true,
  ),
  HermesShortcut('指令帮助', '/help', '查看当前 Hermes 支持的指令'),
];
