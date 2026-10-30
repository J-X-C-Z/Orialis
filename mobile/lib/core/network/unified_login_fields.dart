import 'dart:async';

import 'package:flutter/services.dart' show TextInputAction;
import 'package:lumina_ui/lumina_ui.dart';

import 'unified_login.dart';

Future<bool> confirmUnifiedLoginConsent(
  BuildContext context,
  UnifiedLoginConsent consent,
  UnifiedLogin login,
) async {
  if (!context.mounted) return false;
  return await showLuminaDialog<bool>(
        context: context,
        builder: (dialogContext) {
          final route = ModalRoute.of(dialogContext);
          unawaited(
            login.stopped.then((_) {
              if (dialogContext.mounted && route?.isCurrent == true) {
                Navigator.of(dialogContext).pop(false);
              }
            }),
          );
          return LuminaDialog(
            title: '授权 ${consent.description}',
            content: SingleChildScrollView(
              child: Text(
                [
                  '使用统一账号登录并关联已有 Orialis 账号。',
                  '权限：${consent.scopes.map((s) => s == 'openid' ? '账号标识' : '已有账号关联').join('、')}',
                  if (consent.claims.isNotEmpty)
                    '账号信息：${consent.claims.map((claim) => const {'legacy_military_id': '原有学习账号编号', 'sub': '统一账号标识', 'name': '显示名称', 'preferred_username': '用户名', 'email': '邮箱'}[claim] ?? claim).join('、')}',
                  if (consent.audience.isNotEmpty)
                    '授权对象：${consent.audience.join('、')}',
                ].join('\n\n'),
              ),
            ),
            actions: [
              LuminaButton(
                primary: false,
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              LuminaButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('同意并登录'),
              ),
            ],
          );
        },
      ) ==
      true;
}

class UnifiedLoginFields extends StatefulWidget {
  const UnifiedLoginFields({
    required this.onSubmit,
    required this.busy,
    this.needsTotp = false,
    super.key,
  });
  final Future<void> Function(String username, String password, String? totp)
  onSubmit;
  final bool busy;
  final bool needsTotp;

  @override
  State<UnifiedLoginFields> createState() => _UnifiedLoginFieldsState();
}

class _UnifiedLoginFieldsState extends State<UnifiedLoginFields> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _totp = TextEditingController();

  void _submit() {
    if (!widget.busy) {
      widget.onSubmit(
        _username.text,
        _password.text,
        widget.needsTotp ? _totp.text : null,
      );
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _totp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LuminaTextField(
        key: const ValueKey('unified-username'),
        controller: _username,
        label: '统一账号',
        enabled: !widget.busy,
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 12),
      LuminaTextField(
        key: const ValueKey('unified-password'),
        controller: _password,
        label: '统一账号密码',
        obscureText: true,
        enabled: !widget.busy,
        textInputAction: widget.needsTotp
            ? TextInputAction.next
            : TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      if (widget.needsTotp) ...[
        const SizedBox(height: 12),
        LuminaTextField(
          key: const ValueKey('unified-totp'),
          controller: _totp,
          label: '动态验证码',
          keyboardType: TextInputType.number,
          enabled: !widget.busy,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
      ],
      const SizedBox(height: 12),
      Text(
        '登录即授权 Orialis 读取统一账号标识并关联已有账号。',
        style: LuminaTheme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      LuminaButton(
        onPressed: widget.busy ? null : _submit,
        child: Text(widget.busy ? '正在登录' : '使用统一账号登录'),
      ),
    ],
  );
}
