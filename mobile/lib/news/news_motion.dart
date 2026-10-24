import 'package:lumina_ui/lumina_ui.dart';

// Compatibility for existing feed callers; task cards share the same reveal.
typedef NewsSliverReveal = LuminaSliverReveal;

/// Refresh the visible feed without replacing its scroll and filter state.
class NewsRefreshScope extends InheritedWidget {
  const NewsRefreshScope({
    required this.generation,
    required super.child,
    super.key,
  });

  final int generation;

  static int of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<NewsRefreshScope>()
          ?.generation ??
      0;

  @override
  bool updateShouldNotify(NewsRefreshScope oldWidget) =>
      generation != oldWidget.generation;
}
