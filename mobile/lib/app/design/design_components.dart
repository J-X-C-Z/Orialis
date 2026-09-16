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
        child: Padding(padding: padding, child: body),
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
        constraints: const BoxConstraints(
          maxWidth: AppChatMetrics.bubbleMaxWidth,
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
