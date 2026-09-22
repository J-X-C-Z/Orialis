part of 'design_components.dart';

class LuminaTextField extends StatefulWidget {
  const LuminaTextField({
    required this.controller,
    this.label,
    this.hint,
    this.hintText,
    this.maxLines = 1,
    this.minLines,
    this.obscureText = false,
    this.onChanged,
    this.keyboardType,
    this.autofocus = false,
    this.readOnly = false,
    this.enabled = true,
    this.onTap,
    this.onSubmitted,
    this.focusNode,
    this.maxLength,
    this.textInputAction,
    super.key,
  });
  final TextEditingController controller;
  final String? label, hint, hintText;
  final int? maxLines, minLines, maxLength;
  final bool obscureText, autofocus, readOnly, enabled;
  final ValueChanged<String>? onChanged, onSubmitted;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  @override
  State<LuminaTextField> createState() => _LuminaTextFieldState();
}

class _LuminaTextFieldState extends State<LuminaTextField> {
  late final FocusNode ownFocus = FocusNode();
  FocusNode get focus => widget.focusNode ?? ownFocus;
  @override
  void dispose() {
    ownFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: LuminaTheme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
        ],
        ListenableBuilder(
          listenable: Listenable.merge([focus, widget.controller]),
          builder: (context, _) => GestureDetector(
            onTap: widget.enabled
                ? () {
                    focus.requestFocus();
                    widget.onTap?.call();
                  }
                : null,
            child: AnimatedContainer(
              duration: MediaQuery.maybeOf(context)?.disableAnimations == true
                  ? Duration.zero
                  : LuminaMotion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: focus.hasFocus ? colors.accent : colors.outline,
                  width: focus.hasFocus ? 1.5 : 1,
                ),
              ),
              child: Stack(
                children: [
                  if (widget.controller.text.isEmpty)
                    IgnorePointer(
                      child: Text(
                        widget.hintText ?? widget.hint ?? '',
                        style: LuminaTheme.of(
                          context,
                        ).textTheme.bodyMedium.copyWith(color: colors.muted),
                      ),
                    ),
                  Semantics(
                    textField: true,
                    label: widget.label,
                    enabled: widget.enabled,
                    child: ExcludeFocus(
                      excluding: !widget.enabled,
                      child: IgnorePointer(
                        ignoring: !widget.enabled,
                        child: EditableText(
                          controller: widget.controller,
                          focusNode: focus,
                          style: LuminaTheme.of(context).textTheme.bodyMedium,
                          cursorColor: colors.accent,
                          backgroundCursorColor: colors.outline,
                          selectionColor: colors.accentSoft,
                          autofocus: widget.autofocus,
                          readOnly: widget.readOnly || !widget.enabled,
                          obscureText: widget.obscureText,
                          maxLines: widget.obscureText ? 1 : widget.maxLines,
                          minLines: widget.minLines,
                          keyboardType: widget.keyboardType,
                          textInputAction: widget.textInputAction,
                          onChanged: widget.onChanged,
                          onSubmitted: widget.onSubmitted,
                          inputFormatters: widget.maxLength == null
                              ? null
                              : [
                                  LengthLimitingTextInputFormatter(
                                    widget.maxLength,
                                  ),
                                ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class LuminaCheck extends StatelessWidget {
  const LuminaCheck({required this.value, required this.onChanged, super.key});
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => Semantics(
    checked: value,
    enabled: onChanged != null,
    child: LuminaIconButton(
      tooltip: value ? '取消选择' : '选择',
      onPressed: onChanged == null ? null : () => onChanged!(!value),
      icon: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: value ? LuminaTheme.of(context).colors.accentSoft : null,
          border: Border.all(color: LuminaTheme.of(context).colors.muted),
          borderRadius: BorderRadius.circular(7),
        ),
        child: value ? const LuminaIcon(LuminaIcons.check, size: 18) : null,
      ),
    ),
  );
}

class LuminaSwitch extends StatelessWidget {
  const LuminaSwitch({required this.value, required this.onChanged, super.key});
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      child: LuminaSurface(
        glass: true,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        padding: const EdgeInsets.all(8),
        radius: 24,
        child: AnimatedContainer(
          duration: MediaQuery.maybeOf(context)?.disableAnimations == true
              ? Duration.zero
              : LuminaMotion.standard,
          width: 42,
          height: 26,
          padding: const EdgeInsets.all(3),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: value ? colors.accent : colors.outline,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: colors.surface,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class LuminaSegmented<T> extends StatelessWidget {
  const LuminaSegmented({
    required this.items,
    required this.value,
    required this.onChanged,
    super.key,
  });
  final Map<T, String> items;
  final T value;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => LuminaSurface(
    glass: true,
    padding: const EdgeInsets.all(4),
    radius: 18,
    child: Row(
      children: items.entries
          .map(
            (e) => Expanded(
              child: Semantics(
                selected: e.key == value,
                child: LuminaSurface(
                  glass: e.key == value,
                  color: e.key == value
                      ? LuminaTheme.of(context).colors.accentSoft
                      : const Color(0x00000000),
                  onTap: () => onChanged(e.key),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 11,
                  ),
                  radius: 14,
                  child: Text(
                    e.value,
                    textAlign: TextAlign.center,
                    style: LuminaTheme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    ),
  );
}
