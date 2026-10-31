import 'package:lumina_ui/lumina_ui.dart';

/// Keep a page's controls on one line without shrinking large-text tap targets.
class OrialisCompactHeader extends StatelessWidget {
  const OrialisCompactHeader({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.hardEdge,
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}
