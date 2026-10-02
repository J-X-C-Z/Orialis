part of 'design_components.dart';

/// A fixed control above scrollable content. Apply [bodyBuilder]'s inset as
/// scroll padding so content can pass behind the control after scrolling.
class LuminaFloatingHeader extends StatelessWidget {
  const LuminaFloatingHeader({
    required this.header,
    required this.bodyBuilder,
    this.headerExtent,
    this.horizontalPadding = 20,
    super.key,
  });

  final Widget header;
  final Widget Function(BuildContext context, double topInset) bodyBuilder;
  final double? headerExtent;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final pageInset = LuminaPageHeaderInset.of(context);
    final extent =
        headerExtent ??
        math.max(
          64.0,
          MediaQuery.textScalerOf(context).scale(
                    LuminaTheme.of(context).textTheme.labelMedium.fontSize ??
                        14,
                  ) *
                  1.4 +
              38,
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        bodyBuilder(context, pageInset + extent + 24),
        Positioned(
          top: pageInset + 8,
          left: horizontalPadding,
          right: horizontalPadding,
          height: extent,
          child: header,
        ),
      ],
    );
  }
}

class LuminaDateNavigator extends StatelessWidget {
  const LuminaDateNavigator({
    required this.label,
    required this.previousLabel,
    required this.nextLabel,
    required this.onPrevious,
    required this.onNext,
    required this.onSelectDate,
    super.key,
  });
  final String label, previousLabel, nextLabel;
  final VoidCallback onPrevious, onNext, onSelectDate;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      LuminaIconButton(
        tooltip: previousLabel,
        icon: const LuminaIcon(LuminaIcons.back),
        onPressed: onPrevious,
      ),
      const SizedBox(width: 12),
      Expanded(
        child: LuminaButton(
          primary: false,
          onPressed: onSelectDate,
          child: Text(label, textAlign: TextAlign.center),
        ),
      ),
      const SizedBox(width: 12),
      LuminaIconButton(
        tooltip: nextLabel,
        icon: const LuminaIcon(LuminaIcons.chevronRight),
        onPressed: onNext,
      ),
    ],
  );
}

class LuminaTitledContentCard extends StatelessWidget {
  const LuminaTitledContentCard({
    required this.title,
    required this.children,
    required this.emptyText,
    super.key,
  });
  final String title, emptyText;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LuminaSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: LuminaTheme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 14),
        if (children.isEmpty)
          Text(
            emptyText,
            style: LuminaTheme.of(context).textTheme.bodySmall
                .copyWith(color: LuminaTheme.of(context).colors.muted),
          )
        else
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            children[i],
          ],
      ],
    ),
  );
}

/// A cheap, compact month-grid label; details belong in the selected-day card.
class LuminaCalendarSummary extends StatelessWidget {
  const LuminaCalendarSummary({
    required this.title,
    this.deadline = false,
    super.key,
  });
  final String title;
  final bool deadline;

  @override
  Widget build(BuildContext context) {
    final theme = LuminaTheme.of(context);
    return Semantics(
      label: '${deadline ? '截止任务' : '日程'}：$title',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colors.accentSoft,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Text(
            '${deadline ? '◇' : '·'} $title',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ),
      ),
    );
  }
}
