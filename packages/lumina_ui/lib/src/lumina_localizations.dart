import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Built-in chrome only. Applications own their content and translations.
class LuminaLocalizations {
  const LuminaLocalizations(this.locale);
  final Locale locale;
  bool get _zh => locale.languageCode == 'zh';
  static const delegate = _LuminaLocalizationsDelegate();
  static const supportedLocales = [Locale('zh'), Locale('en')];
  static LuminaLocalizations of(BuildContext context) =>
      Localizations.of<LuminaLocalizations>(context, LuminaLocalizations) ??
      const LuminaLocalizations(Locale('zh'));
  String get close => _zh ? '关闭' : 'Close';
  String get closeSheet => _zh ? '关闭面板' : 'Close sheet';
  String get selectDate => _zh ? '选择日期' : 'Select date';
  String get selectTime => _zh ? '选择时间' : 'Select time';
  String get confirm => _zh ? '确定' : 'Confirm';
  String get copy => _zh ? '复制' : 'Copy';
  String get loading => _zh ? '加载中' : 'Loading';
  String get select => _zh ? '选择' : 'Select';
  String get deselect => _zh ? '取消选择' : 'Deselect';
  String get collapsed => _zh ? '已收起' : 'Collapsed';
  String get saveFailed =>
      _zh ? '未能保存完成状态，请重试。' : 'Could not save. Please try again.';
  List<String> get weekdays => _zh
      ? const ['一', '二', '三', '四', '五', '六', '日']
      : const ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
}

class _LuminaLocalizationsDelegate
    extends LocalizationsDelegate<LuminaLocalizations> {
  const _LuminaLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) => ['zh', 'en'].contains(locale.languageCode);
  @override
  Future<LuminaLocalizations> load(Locale locale) =>
      SynchronousFuture(LuminaLocalizations(locale));
  @override
  bool shouldReload(_LuminaLocalizationsDelegate old) => false;
}
