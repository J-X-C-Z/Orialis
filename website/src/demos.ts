type DemoKind = 'schedule' | 'news';

type SchedulePreset = {
  id: 'proposal' | 'walk';
  phrase: string;
  label: string;
  minutes: number;
  hour: number;
  minute: number;
};

const schedulePresets: SchedulePreset[] = [
  { id: 'proposal', phrase: '明天下午三点，留一小时准备提案', label: '准备提案', minutes: 60, hour: 15, minute: 0 },
  { id: 'walk', phrase: '明天下午五点，留半小时散步', label: '散步', minutes: 30, hour: 17, minute: 0 },
];

const newsExamples = [
  {
    title: '从信息洪流，回到值得读的一条',
    intro: '资讯体验的重点，是让人更快找到与自己有关的内容。',
    highlights: [
      '先呈现少量重点，让阅读从清晰的入口开始。',
      '保留来源路径，方便在需要时继续了解。',
      '把选择权交还给读者，摘要只是阅读的起点。',
    ],
  },
  {
    title: '代码的价值，不止一颗星标',
    intro: '发现项目时，除了热度，也可以留意它是否适合自己的下一步。',
    highlights: [
      '用简短重点降低初次了解一个项目的门槛。',
      '从概览继续前往原始页面，自己判断细节。',
      '把发现、阅读和稍后再看连成顺手的体验。',
    ],
  },
];

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function localDateTime(date: Date): string {
  const pad = (value: number) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function nextDayAt(hour: number, minute: number): Date {
  const date = new Date();
  date.setDate(date.getDate() + 1);
  date.setHours(hour, minute, 0, 0);
  return date;
}

function formatDateTime(value: string): string {
  const date = new Date(value);
  return new Intl.DateTimeFormat('zh-CN', {
    month: 'long', day: 'numeric', weekday: 'long', hour: 'numeric', minute: '2-digit', hour12: false,
  }).format(date);
}

function makeButton(label: string, className: string, action: () => void): HTMLButtonElement {
  const button = element('button', className, label);
  button.type = 'button';
  button.addEventListener('click', action);
  return button;
}

export function setupDemos(): { open(kind: DemoKind): void; close(): void } {
  const dialog = element('dialog', 'demo-dialog');
  dialog.setAttribute('aria-labelledby', 'demo-title');
  dialog.setAttribute('aria-describedby', 'demo-description');

  const panel = element('div', 'demo-panel');
  const header = element('header', 'demo-header');
  const headingGroup = element('div', 'demo-heading-group');
  const title = element('h2', 'demo-title', '安排你的下一小时');
  title.id = 'demo-title';
  title.tabIndex = -1;
  const description = element('p', 'demo-description', '交互演示，内容不会保存。');
  description.id = 'demo-description';
  headingGroup.append(title, description);
  let restoreFocus: HTMLElement | null = null;
  const closeButton = makeButton('关闭', 'demo-close', () => close());
  closeButton.setAttribute('aria-label', '关闭演示');
  header.append(headingGroup, closeButton);

  const content = element('main', 'demo-content');
  const live = element('p', 'demo-live');
  live.setAttribute('role', 'status');
  live.setAttribute('aria-live', 'polite');
  live.setAttribute('aria-atomic', 'true');
  panel.append(header, content, live);
  dialog.append(panel);
  document.body.append(dialog);

  function close(): void {
    if (dialog.open) dialog.close();
  }

  dialog.addEventListener('close', () => {
    const target = restoreFocus;
    restoreFocus = null;
    if (target?.isConnected) target.focus();
  });
  dialog.addEventListener('click', (event) => {
    if (event.target === dialog) close();
  });

  function open(kind: DemoKind): void {
    if (!dialog.open) restoreFocus = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    live.textContent = '';
    if (kind === 'schedule') {
      title.textContent = '安排你的下一小时';
      renderScheduleStart();
    } else {
      title.textContent = '看见值得的资讯';
      renderNewsStart();
    }
    if (!dialog.open) dialog.showModal();
    title.focus();
  }

  function focusContentHeading(): void {
    const heading = content.querySelector<HTMLElement>('.demo-section-title');
    if (!heading) return;
    heading.tabIndex = -1;
    heading.focus();
  }

  function renderScheduleStart(): void {
    content.replaceChildren();
    const eyebrow = element('p', 'demo-eyebrow', 'Orialis 日程');
    const intro = element('h3', 'demo-section-title', '把一句话，变成清楚的一小时。');
    const prompt = element('p', 'demo-copy', '选一个示例，可预览并调整时间。');
    const choices = element('div', 'demo-choices');
    let selected: SchedulePreset | null = null;
    const cards = schedulePresets.map((preset) => {
      const card = makeButton('', 'demo-choice', () => {
        selected = preset;
        for (const candidate of cards) {
          candidate.classList.remove('demo-choice--selected');
          candidate.setAttribute('aria-pressed', 'false');
        }
        card.classList.add('demo-choice--selected');
        card.setAttribute('aria-pressed', 'true');
        live.textContent = `已选择：${preset.phrase}`;
        generate.disabled = false;
      });
      card.setAttribute('aria-pressed', 'false');
      card.append(element('span', 'demo-choice-label', preset.label), element('span', 'demo-choice-phrase', preset.phrase));
      return card;
    });
    choices.append(...cards);
    let generate: HTMLButtonElement;
    generate = makeButton('生成日程', 'demo-button demo-button--primary', () => {
      if (selected) renderSchedulePreview(selected);
    });
    generate.disabled = true;
    const actions = element('div', 'demo-actions');
    actions.append(generate);
    content.append(eyebrow, intro, prompt, choices, actions);
    focusContentHeading();
  }

  function renderSchedulePreview(preset: SchedulePreset): void {
    content.replaceChildren();
    const start = nextDayAt(preset.hour, preset.minute);
    const end = new Date(start.getTime() + preset.minutes * 60_000);
    const preview = element('article', 'demo-preview');
    preview.append(
      element('p', 'demo-eyebrow', '日程预览'),
      element('h3', 'demo-section-title', preset.label),
      element('p', 'demo-copy', preset.phrase),
    );
    const timeSummary = element('p', 'demo-time-summary', `${formatDateTime(localDateTime(start))} — ${new Intl.DateTimeFormat('zh-CN', { hour: 'numeric', minute: '2-digit', hour12: false }).format(end)}`);
    timeSummary.dataset.role = 'time-summary';
    preview.append(timeSummary);

    const form = element('div', 'demo-time-fields');
    const startLabel = element('label', 'demo-field');
    startLabel.append(element('span', undefined, '开始时间'));
    const startInput = element('input', 'demo-datetime');
    startInput.type = 'datetime-local';
    startInput.value = localDateTime(start);
    startInput.setAttribute('aria-label', '开始时间');
    startLabel.append(startInput);
    const endLabel = element('label', 'demo-field');
    endLabel.append(element('span', undefined, '结束时间'));
    const endInput = element('input', 'demo-datetime');
    endInput.type = 'datetime-local';
    endInput.value = localDateTime(end);
    endInput.setAttribute('aria-label', '结束时间');
    endLabel.append(endInput);
    form.append(startLabel, endLabel);
    const validation = element('p', 'demo-validation');
    validation.setAttribute('aria-live', 'polite');
    function validate(): boolean {
      const startMs = new Date(startInput.value).getTime();
      const endMs = new Date(endInput.value).getTime();
      const valid = Boolean(startInput.value && endInput.value && startInput.validity.valid && endInput.validity.valid && Number.isFinite(startMs) && Number.isFinite(endMs) && endMs > startMs);
      validation.textContent = valid ? '' : '请填写有效时间，并确保结束时间晚于开始时间。';
      validation.classList.toggle('demo-validation--visible', !valid);
      confirm.disabled = !valid;
      timeSummary.textContent = valid
        ? `${formatDateTime(startInput.value)} — ${new Intl.DateTimeFormat('zh-CN', { hour: 'numeric', minute: '2-digit', hour12: false }).format(new Date(endInput.value))}`
        : '时间待确认';
      return valid;
    }
    startInput.addEventListener('input', validate);
    endInput.addEventListener('input', validate);

    const edit = makeButton('调整时间', 'demo-button demo-button--secondary', () => {
      startInput.focus();
      live.textContent = '可修改开始和结束时间，结束时间必须晚于开始时间。';
    });
    const confirm = makeButton('确认安排', 'demo-button demo-button--primary', () => {
      if (!validate()) return;
      renderScheduleSuccess(preset, startInput.value, endInput.value);
    });
    const retry = makeButton('再试一次', 'demo-button demo-button--text', renderScheduleStart);
    const actions = element('div', 'demo-actions demo-actions--split');
    actions.append(retry, edit, confirm);
    content.append(preview, form, validation, actions);
    validate();
    focusContentHeading();
  }

  function renderScheduleSuccess(preset: SchedulePreset, start: string, end: string): void {
    content.replaceChildren();
    content.append(
      element('p', 'demo-eyebrow', '本次演示完成'),
      element('div', 'demo-success-mark', '✓'),
      element('h3', 'demo-section-title', '安排好了。'),
      element('p', 'demo-copy', `「${preset.label}」 · ${formatDateTime(start)} 至 ${new Intl.DateTimeFormat('zh-CN', { hour: 'numeric', minute: '2-digit', hour12: false }).format(new Date(end))}`),
      element('p', 'demo-note', '这只是页面内的体验预览，没有写入日历或账户。'),
    );
    content.append(makeButton('再试一次', 'demo-button demo-button--primary', renderScheduleStart));
    live.textContent = '演示完成。没有保存到账户。';
    focusContentHeading();
  }

  function renderNewsStart(): void {
    content.replaceChildren();
    content.append(
      element('p', 'demo-eyebrow', '资讯 · 示例内容'),
      element('h3', 'demo-section-title', '让值得读的内容，先浮现出来。'),
      element('p', 'demo-copy', '选择一条体验重点摘要与参考入口。以下标题与重点是产品体验示例，不是真实新闻。'),
    );
    const choices = element('div', 'demo-choices demo-choices--news');
    for (const [index, news] of newsExamples.entries()) {
      choices.append(makeButton(news.title, 'demo-choice demo-choice--news', () => renderNewsDetail(index)));
    }
    content.append(choices);
    focusContentHeading();
  }

  function renderNewsDetail(index: number): void {
    const item = newsExamples[index];
    if (!item) return;
    content.replaceChildren();
    content.append(
      element('p', 'demo-eyebrow', '资讯 · 示例内容'),
      element('h3', 'demo-section-title', item.title),
      element('p', 'demo-copy', item.intro),
    );
    const highlights = element('ol', 'demo-highlights');
    for (const highlight of item.highlights) highlights.append(element('li', 'demo-highlight', highlight));
    const sources = element('details', 'demo-sources');
    sources.append(element('summary', undefined, '展开参考入口'));
    sources.append(element('p', 'demo-note', '以下是延伸阅读入口，不是这条示例内容的新闻来源。'));
    const links = element('ul', 'demo-source-list');
    const mdn = element('a', undefined, 'MDN · WebGL 2 API');
    mdn.href = 'https://developer.mozilla.org/en-US/docs/Web/API/WebGL2RenderingContext';
    mdn.target = '_blank';
    mdn.rel = 'noopener noreferrer';
    const trending = element('a', undefined, 'GitHub · Trending');
    trending.href = 'https://githot.dev/';
    trending.target = '_blank';
    trending.rel = 'noopener noreferrer';
    const mdnItem = element('li');
    mdnItem.append(mdn);
    const trendingItem = element('li');
    trendingItem.append(trending);
    links.append(mdnItem, trendingItem);
    sources.append(links);
    content.append(highlights, sources);
    const actions = element('div', 'demo-actions');
    actions.append(makeButton('再试一次', 'demo-button demo-button--primary', renderNewsStart));
    content.append(actions);
    live.textContent = `${item.title}，三条重点已展开。`;
    focusContentHeading();
  }

  return { open, close };
}
