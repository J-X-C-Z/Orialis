import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:lumina_ui/lumina_ui.dart';

void main() => runApp(const LuminaShowcaseApp());

class LuminaShowcaseApp extends StatefulWidget {
  const LuminaShowcaseApp({super.key});

  @override
  State<LuminaShowcaseApp> createState() => _LuminaShowcaseAppState();
}

class _LuminaShowcaseAppState extends State<LuminaShowcaseApp> {
  bool dark = false;
  bool reducedMotion = false;
  bool highPerformance = true;
  double textScale = 1;
  LuminaCardPalette palette = LuminaCardPalette.mist;
  int segment = 0;
  bool completed = false;
  Locale locale = const Locale('en');
  final controller = TextEditingController(text: 'A little room to think.');

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = dark ? Brightness.dark : Brightness.light;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: LuminaLocalizations.supportedLocales,
      localizationsDelegates: const [
        LuminaLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: palette.colors(dark: dark).paper,
        useMaterial3: true,
      ),
      home: Builder(
          builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                  disableAnimations: reducedMotion,
                ),
                child: LuminaTheme(
                  brightness: brightness,
                  highPerformanceMode: highPerformance,
                  data: const LuminaThemeData(
                    fontScale: 1,
                    fontFamily: 'sans-serif',
                    spacingScale: 1,
                    radiusScale: 1,
                    motionScale: 1,
                  ),
                  child: _ShowcasePage(
                    dark: dark,
                    reducedMotion: reducedMotion,
                    highPerformance: highPerformance,
                    textScale: textScale,
                    palette: palette,
                    segment: segment,
                    completed: completed,
                    controller: controller,
                    locale: locale,
                    onLocale: (value) => setState(() => locale = value),
                    onDark: (value) => setState(() => dark = value),
                    onReducedMotion: (value) =>
                        setState(() => reducedMotion = value),
                    onHighPerformance: (value) =>
                        setState(() => highPerformance = value),
                    onTextScale: (value) => setState(() => textScale = value),
                    onPalette: (value) => setState(() => palette = value),
                    onSegment: (value) => setState(() => segment = value),
                    onCompleted: (value) => setState(() => completed = value),
                  ),
                ),
              )),
    );
  }
}

class _ShowcasePage extends StatelessWidget {
  const _ShowcasePage(
      {required this.dark,
      required this.reducedMotion,
      required this.highPerformance,
      required this.textScale,
      required this.palette,
      required this.segment,
      required this.completed,
      required this.controller,
      required this.locale,
      required this.onLocale,
      required this.onDark,
      required this.onReducedMotion,
      required this.onHighPerformance,
      required this.onTextScale,
      required this.onPalette,
      required this.onSegment,
      required this.onCompleted});

  final bool dark, reducedMotion, highPerformance, completed;
  final double textScale;
  final LuminaCardPalette palette;
  final int segment;
  final TextEditingController controller;
  final Locale locale;
  final ValueChanged<Locale> onLocale;
  final ValueChanged<bool> onDark,
      onReducedMotion,
      onHighPerformance,
      onCompleted;
  final ValueChanged<double> onTextScale;
  final ValueChanged<LuminaCardPalette> onPalette;
  final ValueChanged<int> onSegment;

  @override
  Widget build(BuildContext context) {
    final colors = LuminaTheme.of(context).colors;
    final text = LuminaTheme.of(context).textTheme;
    String tr(String en, String zh) => locale.languageCode == 'zh' ? zh : en;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 48),
                  sliver: SliverList.list(children: [
                    Text(tr('LUMINA UI / FIELD NOTES', 'LUMINA UI / 设计手记'),
                        style: text.labelSmall.copyWith(letterSpacing: 1.6)),
                    const SizedBox(height: 12),
                    Text(tr('Quietly capable.', '安静，自有力量。'),
                        style: text.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                        tr('A tactile component study in soft materials, clear hierarchy, and calm motion.',
                            '以柔和材质、清晰层次与从容动效，探索细腻的界面体验。'),
                        style: text.bodyMedium),
                    const SizedBox(height: 24),
                    _section(
                        context,
                        tr('Color families', '色彩家族'),
                        tr('Six tonal palettes, each tuned for both light and dark surfaces.',
                            '六组色调，为明暗界面分别细致调校。')),
                    Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: LuminaCardPalette.values
                            .map((item) => ChoiceChip(
                                  label: Text(item.name[0].toUpperCase() +
                                      item.name.substring(1)),
                                  selected: palette == item,
                                  onSelected: (_) => onPalette(item),
                                ))
                            .toList()),
                    const SizedBox(height: 18),
                    LuminaPalette(
                        palette: palette,
                        child: LuminaSurface(
                          depth: LuminaSurfaceDepth.raised,
                          shoulder: true,
                          shoulderTitle: tr('A considered surface', '经过斟酌的表面'),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    tr('Light catches the edge, then settles.',
                                        '光线掠过边缘，轻轻停驻。'),
                                    style: text.titleSmall),
                                const SizedBox(height: 8),
                                Text(
                                    tr('Raised, recessed, and glass materials inherit the selected tint as one coherent family.',
                                        '凸起、内嵌与玻璃材质共享所选色调，构成统一的色彩家族。'),
                                    style: text.bodyMedium),
                                const SizedBox(height: 18),
                                Row(children: [
                                  Expanded(
                                      child: LuminaSurface(
                                          depth: LuminaSurfaceDepth.recessed,
                                          radius: 18,
                                          child: Text(
                                              tr('Recessed detail', '内嵌细节'),
                                              style: text.bodySmall))),
                                  const SizedBox(width: 12),
                                  LuminaButton(
                                      onPressed: () => showLuminaToast(
                                          context, 'Surface acknowledged'),
                                      child: Text(tr('Try a button', '试试按钮'))),
                                ]),
                              ]),
                        )),
                    const SizedBox(height: 28),
                    _section(
                        context,
                        tr('Controls', '交互控件'),
                        tr('Compact controls with direct, familiar feedback.',
                            '简洁控件，带来直觉而熟悉的反馈。')),
                    LuminaSegmented<int>(
                        items: locale.languageCode == 'zh'
                            ? const {0: '今天', 1: '即将', 2: '完成'}
                            : const {0: 'Today', 1: 'Upcoming', 2: 'Done'},
                        value: segment,
                        onChanged: onSegment),
                    const SizedBox(height: 16),
                    LuminaTextField(
                        controller: controller,
                        label: tr('A small note', '随手记下'),
                        hint: tr('Write something…', '写点什么…')),
                    const SizedBox(height: 16),
                    LuminaSlidingSelection(
                        index: segment,
                        count: 3,
                        onDragEnd: onSegment,
                        child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: const [
                              Text('01'),
                              Text('02'),
                              Text('03')
                            ])),
                    const SizedBox(height: 26),
                    _section(
                        context,
                        tr('Expandable card', '可折叠卡片'),
                        tr('Tap the title to fold the contents while preserving their state.',
                            '轻点标题即可收起内容，同时保留内部状态。')),
                    LuminaCollapsibleCard(
                        storageId: 'showcase-example',
                        title: tr('A slower kind of progress', '慢一点，也在前进'),
                        summary: tr('Three small steps, kept in view.',
                            '三个小步骤，进度一目了然。'),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  tr('Notice what has already moved forward.',
                                      '看看已经向前迈出的每一步。'),
                                  style: text.bodyMedium),
                              const SizedBox(height: 12),
                              LuminaProgress(value: completed ? 1 : .62),
                              const SizedBox(height: 12),
                              LuminaButton(
                                  onPressed: () => onCompleted(!completed),
                                  child: Text(completed
                                      ? tr('Reset progress', '重置进度')
                                      : tr('Complete this step', '完成此步骤'))),
                            ])),
                    const SizedBox(height: 26),
                    _section(
                        context,
                        tr('Completion', '完成反馈'),
                        tr('Completion feedback stays local to this example.',
                            '完成状态仅保存在此示例中。')),
                    LuminaCompletionList(
                      empty: LuminaSurface(
                          child: Text(tr('Everything is complete.', '全部完成。'),
                              style: text.bodyMedium)),
                      children: completed
                          ? const []
                          : [
                              LuminaSurface(
                                  key: const ValueKey('completion-row'),
                                  child: Row(children: [
                                    Expanded(
                                        child: Text(
                                            tr('Review the first draft',
                                                '检查初稿'),
                                            style: text.bodyMedium)),
                                    LuminaButton(
                                        onPressed: () => onCompleted(true),
                                        child: Text(tr('Complete', '完成'))),
                                  ])),
                            ],
                    ),
                    const SizedBox(height: 26),
                    _section(
                        context,
                        tr('Preferences', '偏好设置'),
                        tr('Preview accessibility and rendering choices.',
                            '预览无障碍与渲染选项。')),
                    Row(children: [
                      Expanded(
                          child: Text(
                              locale.languageCode == 'zh' ? '语言' : 'Language',
                              style: text.bodyMedium)),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'en', label: Text('EN')),
                          ButtonSegment(value: 'zh', label: Text('中文')),
                        ],
                        selected: {locale.languageCode},
                        onSelectionChanged: (values) =>
                            onLocale(Locale(values.first)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    _toggle(
                        context, tr('Dark appearance', '深色外观'), dark, onDark),
                    _toggle(context, tr('Reduced motion', '减少动态效果'),
                        reducedMotion, onReducedMotion),
                    _toggle(context, tr('High performance', '高性能模式'),
                        highPerformance, onHighPerformance),
                    Row(children: [
                      Expanded(
                          child: Text(tr('Text size', '文字大小'),
                              style: text.bodyMedium)),
                      Text('${(textScale * 100).round()}%',
                          style: text.bodySmall),
                      const SizedBox(width: 8),
                      SizedBox(
                          width: 180,
                          child: LuminaValueSlider(
                              value: textScale,
                              min: .85,
                              max: 1.35,
                              divisions: 5,
                              onChanged: onTextScale)),
                    ]),
                    const SizedBox(height: 18),
                    LuminaButton(
                        onPressed: () => showLuminaSheet<void>(
                            context: context,
                            builder: (context) => Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(tr('A little more space', '留一点空间'),
                                          style: LuminaTheme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      const SizedBox(height: 10),
                                      Text(
                                          tr('Sheets keep the same palette and typography as the page beneath.',
                                              '底部面板延续页面的色彩与字体。'),
                                          style: LuminaTheme.of(context)
                                              .textTheme
                                              .bodyMedium),
                                      const SizedBox(height: 18),
                                      LuminaButton(
                                          onPressed: () =>
                                              Navigator.of(context).pop(),
                                          child:
                                              Text(tr('That’s lovely', '很好'))),
                                    ])),
                        child: Text(tr('Open a bottom sheet', '打开底部面板'))),
                    const SizedBox(height: 28),
                    LuminaSelectableText(
                        tr('Select this sentence to preview the package selection controls. The showcase has no backend and stores no personal data.',
                            '选中这段文字，预览组件包的文本选择控件。此展示应用没有后端，也不会保存个人数据。'),
                        style: text.bodySmall),
                    const SizedBox(height: 24),
                    Text(
                        tr('LUMINA · A SMALL STUDY IN CLARITY',
                            'LUMINA · 清晰之美'),
                        style: text.labelSmall
                            .copyWith(color: colors.muted, letterSpacing: 1.1)),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, String subtitle) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: LuminaTheme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(subtitle, style: LuminaTheme.of(context).textTheme.bodySmall),
        ]),
      );

  Widget _toggle(BuildContext context, String label, bool value,
          ValueChanged<bool> onChanged) =>
      LuminaSurface(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Expanded(
                child: Text(label,
                    style: LuminaTheme.of(context).textTheme.bodyMedium)),
            LuminaSwitch(value: value, onChanged: onChanged),
          ]));
}
