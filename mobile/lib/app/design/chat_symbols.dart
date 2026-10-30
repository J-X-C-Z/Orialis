import 'package:flutter_svg/flutter_svg.dart';
import 'package:lumina_ui/lumina_ui.dart' hide LuminaCardMemory;

enum ChatSymbolKind {
  thinking,
  search,
  working,
  success,
  error,
  attachment,
  summary,
  chart,
  code,
  send,
  copy,
  info,
}

ChatSymbolKind? chatSymbolForEmoji(String emoji) =>
    switch (emoji.replaceAll('\uFE0F', '')) {
      '🤔' || '🧐' || '🧠' || '💭' => ChatSymbolKind.thinking,
      '🔍' || '🔎' || '🕵' => ChatSymbolKind.search,
      '⚙' ||
      '🔧' ||
      '🛠' ||
      '⏳' ||
      '⌛' ||
      '🔄' ||
      '⏰' ||
      '🕒' ||
      '🕐' => ChatSymbolKind.working,
      '✅' || '✔' || '☑' || '🎉' => ChatSymbolKind.success,
      '❌' || '✖' || '⛔' || '🚫' || '⚠' => ChatSymbolKind.error,
      '📎' || '🖇' || '📁' || '📄' || '🖼' => ChatSymbolKind.attachment,
      '📝' || '📑' || '📜' || '🗒' || '📚' || '📖' => ChatSymbolKind.summary,
      '📊' || '📈' || '📉' => ChatSymbolKind.chart,
      '💻' || '🧑‍💻' || '👨‍💻' || '👩‍💻' => ChatSymbolKind.code,
      '📤' || '📨' || '🚀' || '➡' || '➤' => ChatSymbolKind.send,
      '📋' || '🗐' => ChatSymbolKind.copy,
      'ℹ' || '💡' || '❔' || '❓' => ChatSymbolKind.info,
      _ => null,
    };

class ChatSymbol extends StatefulWidget {
  const ChatSymbol(
    this.kind, {
    this.size = 24,
    this.animated = false,
    this.color,
    this.semanticLabel,
    super.key,
  });

  final ChatSymbolKind kind;
  final double size;
  final bool animated;
  final Color? color;
  final String? semanticLabel;

  @override
  State<ChatSymbol> createState() => _ChatSymbolState();
}

class _ChatSymbolState extends State<ChatSymbol>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _phase = AnimationController(vsync: this);
  bool _foreground = true;

  bool get _loops => switch (widget.kind) {
    ChatSymbolKind.thinking ||
    ChatSymbolKind.search ||
    ChatSymbolKind.working => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ChatSymbol oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind ||
        oldWidget.animated != widget.animated) {
      _syncAnimation();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncAnimation();
  }

  void _syncAnimation() {
    final enabled =
        widget.animated &&
        _foreground &&
        TickerMode.valuesOf(context).enabled &&
        !LuminaTheme.motionReducedOf(context);
    if (!enabled) {
      _phase.stop();
      if (_loops) _phase.value = 0;
      return;
    }
    if (!_loops && widget.kind != ChatSymbolKind.success) {
      _phase.stop();
      _phase.value = 0;
      return;
    }
    if (_loops) {
      final duration = switch (widget.kind) {
        ChatSymbolKind.thinking => LuminaMotion.standard * 8,
        ChatSymbolKind.search => LuminaMotion.fluid * 5,
        _ => LuminaMotion.standard * 8,
      };
      if (!_phase.isAnimating || _phase.duration != duration) {
        _phase.duration = duration;
        _phase.repeat(reverse: true);
      }
    } else if (_phase.value < 1) {
      _phase.duration = LuminaMotion.fast;
      _phase.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _phase.dispose();
    super.dispose();
  }

  Color _symbolColor(LuminaColors colors) => colors.ink.withValues(alpha: .65);

  Widget _icon(Color color) => SvgPicture.asset(
    'assets/chat_symbols/${widget.kind.name}.svg',
    width: widget.size,
    height: widget.size,
    fit: BoxFit.contain,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? _symbolColor(LuminaTheme.of(context).colors);
    Widget icon = _icon(color);
    if (widget.animated && !LuminaTheme.motionReducedOf(context)) {
      icon = AnimatedBuilder(
        animation: _phase,
        child: icon,
        builder: (context, child) {
          // A single smooth opacity pulse keeps the glyph anchored and legible.
          final t = Curves.easeInOut.transform(_phase.value);
          return Opacity(opacity: .65 + .35 * t, child: child);
        },
      );
    }
    if (widget.semanticLabel case final label?) {
      icon = Semantics(
        label: label,
        image: true,
        child: ExcludeSemantics(child: icon),
      );
    } else {
      icon = ExcludeSemantics(child: icon);
    }
    return RepaintBoundary(
      child: SizedBox.square(dimension: widget.size, child: icon),
    );
  }
}
