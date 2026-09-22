import '../../app/design/design_components.dart';

class ContentStack extends StatelessWidget {
  const ContentStack({required this.children, this.gap = 12, super.key});
  final List<Widget> children;
  final double gap;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i != 0) SizedBox(height: gap),
        children[i],
      ],
    ],
  );
}

class QuietLabel extends StatelessWidget {
  const QuietLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: LuminaTheme.of(context).textTheme.bodySmall);
}

class PageFailure extends StatelessWidget {
  const PageFailure({this.message = '暂时无法读取，请稍后重试。', super.key});
  final String message;
  @override
  Widget build(BuildContext context) => OrialisEmptyState(text: message);
}

Future<String?> chooseRecordAction(BuildContext context) =>
    showLuminaSheet<String>(
      context: context,
      builder: (context) => ContentStack(
        children: [
          Text('管理记录', style: LuminaTheme.of(context).textTheme.titleLarge),
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context, 'edit'),
            child: const Text('编辑'),
          ),
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context, 'delete'),
            child: const Text('删除'),
          ),
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );

Future<bool> confirmDelete(BuildContext context, String title) async =>
    await showLuminaDialog<bool>(
      context: context,
      builder: (context) => LuminaDialog(
        title: '删除记录？',
        content: Text('“$title”将从当前列表移除。'),
        actions: [
          LuminaButton(
            primary: false,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          LuminaButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ) ??
    false;

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String timeLabel(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
