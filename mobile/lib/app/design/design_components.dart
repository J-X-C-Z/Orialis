import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// The shared page frame used by every first-level mobile destination.
///
/// Pages provide only their content and actions; spacing, background, and
/// safe-area behavior stay consistent across the app.
class OrialisPageScaffold extends StatelessWidget {
  const OrialisPageScaffold({
    required this.title,
    required this.body,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.bottomActions,
    this.floatingActionButton,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.page,
      AppSpacing.pageTop,
      AppSpacing.page,
      AppSpacing.section,
    ),
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget body;
  final Widget? bottomActions;
  final Widget? floatingActionButton;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.paper,
      appBar: OrialisTopBar(
        title: title,
        subtitle: subtitle,
        leading: leading,
        actions: actions,
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = Padding(padding: padding, child: body);
            if (constraints.maxWidth < AppBreakpoints.desktop) {
              return content;
            }
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppLayout.contentMaxWidth,
                ),
                child: content,
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: bottomActions,
      floatingActionButton: floatingActionButton,
    );
  }
}

/// A quiet, text-led top bar with predictable action placement.
class OrialisTopBar extends StatelessWidget implements PreferredSizeWidget {
  const OrialisTopBar({
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? 64 : 76);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      toolbarHeight: preferredSize.height,
      leading: leading,
      titleSpacing: leading == null ? AppSpacing.page : 0,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
        ],
      ),
      actions: actions
          .map(
            (action) => Padding(
              padding: const EdgeInsets.only(right: AppSpacing.compact),
              child: action,
            ),
          )
          .toList(),
    );
  }
}

/// A consistent list row for tasks, schedules, conversations, and settings.
class OrialisListRow extends StatelessWidget {
  const OrialisListRow({
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.enabled = true,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final content = ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.item,
        vertical: AppSpacing.tight,
      ),
      minLeadingWidth: 0,
      horizontalTitleGap: AppSpacing.item,
      leading: leading,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: trailing,
      onTap: onTap,
    );
    return Card(
      color: selected ? AppColors.accentSoft : AppColors.surface,
      child: content,
    );
  }
}

/// Groups related content without forcing every page to invent card padding.
class OrialisSection extends StatelessWidget {
  const OrialisSection({
    required this.title,
    required this.child,
    this.trailing,
    this.padding = const EdgeInsets.all(AppSpacing.item),
    super.key,
  });

  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final trailingWidget = trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.item),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ...?(trailingWidget == null ? null : [trailingWidget]),
            ],
          ),
        ),
        Card(
          child: Padding(padding: padding, child: child),
        ),
      ],
    );
  }
}

/// A bottom action surface for the primary action of a detail or composer page.
class OrialisBottomActionBar extends StatelessWidget {
  const OrialisBottomActionBar({
    required this.primary,
    this.secondary,
    super.key,
  });

  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          AppSpacing.item,
          AppSpacing.page,
          AppSpacing.item,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.outline)),
        ),
        child: Row(
          children: [
            if (secondary != null) ...[
              Expanded(child: secondary!),
              const SizedBox(width: AppSpacing.controlGap),
            ],
            Expanded(child: primary),
          ],
        ),
      ),
    );
  }
}

class OrialisSectionHeader extends StatelessWidget {
  const OrialisSectionHeader({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.item),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class OrialisEmptyState extends StatelessWidget {
  const OrialisEmptyState({required this.text, this.card = true, super.key});

  final String text;
  final bool card;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(AppSpacing.emptyState),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
      ),
    );
    return card ? Card(child: content) : Center(child: content);
  }
}

class OrialisChatBubble extends StatelessWidget {
  const OrialisChatBubble({
    required this.isUser,
    required this.child,
    super.key,
  });

  final bool isUser;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth:
              MediaQuery.sizeOf(context).width >= AppBreakpoints.desktop
              ? AppChatMetrics.desktopBubbleMaxWidth
              : AppChatMetrics.bubbleMaxWidth,
        ),
        margin: const EdgeInsets.only(bottom: AppChatMetrics.bubbleBottomGap),
        padding: const EdgeInsets.symmetric(
          horizontal: AppChatMetrics.bubbleHorizontalPadding,
          vertical: AppChatMetrics.bubbleVerticalPadding,
        ),
        decoration: BoxDecoration(
          color: isUser ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: child,
      ),
    );
  }
}


/// Stable content surface used by Lumina's Solid material language.
class LuminaSolidSurface extends StatelessWidget {
  const LuminaSolidSurface({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = AppRadius.card,
    this.color = AppColors.surface,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: AppColors.outline),
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// Lightweight Flowing Glass control surface.
///
/// It intentionally avoids a full-screen backdrop blur. The translucent fill,
/// bright edge and shallow elevation retain Lumina's interaction hierarchy
/// while keeping desktop lists and sidebars inexpensive to render.
class LuminaGlassControl extends StatelessWidget {
  const LuminaGlassControl({
    required this.child,
    this.selected = false,
    this.padding = EdgeInsets.zero,
    this.radius = AppRadius.control,
    super.key,
  });

  final Widget child;
  final bool selected;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 160),
    curve: Curves.easeOutCubic,
    padding: padding,
    decoration: BoxDecoration(
      color: selected ? AppColors.glassSelected : AppColors.glass,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: selected ? AppColors.accentSoft : AppColors.glassBorder,
      ),
      boxShadow: selected
          ? const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 14,
                offset: Offset(0, 5),
              ),
            ]
          : const [],
    ),
    child: child,
  );
}
