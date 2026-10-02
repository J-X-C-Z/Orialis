import './style.css';
import { createHalo } from './halo.js';
import { setupDemos } from './demos';

// Three throwaway compositions answer one question: how does a vast AI become
// quiet companionship? Compare with ?variant=A, B or C on /prototype/.
type Variant = 'A' | 'B' | 'C';
type Chapter = 'origin' | 'ribbon' | 'schedule' | 'news' | 'everyday';
const names: Record<Variant, string> = { A: '循光旅程', B: '星系漫游', C: '日常来信' };
const chapters: Chapter[] = ['origin', 'ribbon', 'schedule', 'news', 'everyday'];
const stops: Record<Chapter, number> = { origin: 0, ribbon: .215, schedule: .395, news: .63, everyday: 1 };
const labels: Record<Chapter, string> = { origin: '初见', ribbon: '循光', schedule: '日程', news: '资讯', everyday: '身边' };
const params = new URLSearchParams(location.search);
let variant: Variant = (['A', 'B', 'C'].includes(params.get('variant') ?? '') ? params.get('variant') : 'A') as Variant;
const systemMotion = matchMedia('(prefers-reduced-motion: reduce)');
let userReduced = false;
let reduced = systemMotion.matches;
const date = new Date(); date.setDate(date.getDate() + 1);
const tomorrow = new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric' }).format(date);
const weekday = new Intl.DateTimeFormat('zh-CN', { weekday: 'long' }).format(date);

const glyphs: Record<string, string> = {
  arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  down: '<path d="M12 4v16m-6-6 6 6 6-6"/>',
  chevron: '<path d="m9 5 7 7-7 7"/>',
  calendar: '<rect x="4" y="6" width="16" height="15" rx="4"/><path d="M8 3v5m8-5v5M4 11h16m-11 5h2m3 0h2"/>',
  sparkle: '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  news: '<rect x="4" y="3" width="16" height="18" rx="4"/><path d="M8 7h8M8 11h5M8 15h8M8 18h5"/>',
  layers: '<path d="m3 8 9-5 9 5-9 5-9-5Zm0 5 9 5 9-5M3 18l9 5 9-5"/>',
  moon: '<path d="M20 14A8 8 0 0 1 10 4a8 8 0 1 0 10 10Z"/>',
};
const icon = (name: string, cls = '') => `<svg class="icon ${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${glyphs[name]}</svg>`;

document.querySelector<HTMLDivElement>('#app')!.innerHTML = `
  <a class="skip-link" href="#schedule" data-go="schedule">跳到产品介绍</a>
  <div class="world" aria-hidden="true">
    <div class="world-base"></div>
    <canvas id="halo" aria-hidden="true"></canvas>
    <div class="halo-fallback"><i></i><i></i><i></i></div>
    <div class="world-vignette"></div>
    <div class="morning"></div>
    <div class="world-dust"></div>
  </div>
  <header class="header">
    <a class="brand" href="#origin" data-go="origin" aria-label="Orialis 首页"><span class="brand-mark"><i></i></span><span>Orialis</span></a>
    <nav class="top-nav" aria-label="产品导航"><a href="#schedule" data-go="schedule">日程</a><a href="#news" data-go="news">资讯</a><a href="#everyday" data-go="everyday">关于 Orialis</a></nav>
    <button class="motion-toggle" aria-pressed="false">${icon('moon')}<span>减少动态</span></button>
  </header>
  <main class="journey" aria-label="Orialis 光之旅">
    <section class="chapter chapter-origin" id="origin" aria-labelledby="origin-title">
      <div class="hero-intro"><span class="fine-line"></span><span>有些强大，自然而然。</span></div>
      <h1 id="origin-title">Orialis</h1>
      <div class="hero-foot"><p>你的时间，你的视野。<br><span>都在自己的轨道上。</span></p><a class="begin-link" href="#ribbon" data-go="ribbon"><span>循光而行</span><span class="circle-arrow">${icon('down')}</span></a></div>
      <div class="atlas-map" aria-label="选择想探索的星系">
        <a class="map-destination map-schedule" href="#schedule" data-go="schedule"><span class="map-orb ice">${icon('calendar')}</span><span><b>日程</b><small>给时间，一点秩序</small></span></a>
        <a class="map-destination map-news" href="#news" data-go="news"><span class="map-orb lilac">${icon('news')}</span><span><b>资讯</b><small>让值得的，被看见</small></span></a>
        <a class="map-destination map-life" href="#everyday" data-go="everyday"><span class="map-orb sun">${icon('sparkle')}</span><span><b>每一天</b><small>光在身边，日子从容</small></span></a>
      </div>
      <p class="editorial-note">从浩瀚的可能，<br>回到眼前的生活。</p>
    </section>
    <section class="chapter chapter-ribbon" id="ribbon" aria-labelledby="ribbon-title">
      <div class="ribbon-copy"><span class="chapter-kicker">一束光，两种可能</span><h2 id="ribbon-title">沿着光，<br>找到你的节奏。</h2><p>把想做的事安放好，<br>把值得的消息留下来。</p></div>
      <div class="ribbon-destinations"><a href="#schedule" data-go="schedule">${icon('calendar')}<span>日程</span></a><span class="connecting-line"></span><a href="#news" data-go="news">${icon('news')}<span>资讯</span></a></div>
    </section>
    <section class="chapter chapter-schedule" id="schedule" aria-labelledby="schedule-title">
      <div class="chapter-copy"><span class="chapter-kicker"><span class="little-orb ice"></span>Orialis 日程</span><h2 id="schedule-title">给时间，<br>一点秩序。</h2><p>一句话，安放一个计划。<br>日程、任务与项目，各归其位。<br>把注意力留给正在做的事。</p><button class="action" data-demo="schedule"><span>试着安排一天</span>${icon('arrow')}</button><small class="demo-caption">站内交互演示</small></div>
      <div class="product-stage schedule-stage" aria-label="日程界面示意">
        <div class="satellite-trace"></div>
        <div class="product-board schedule-board">
          <div class="board-heading"><span class="board-symbol">${icon('calendar')}</span><div><span class="board-overline">明天 · ${weekday}</span><h3>${tomorrow}</h3></div><span class="board-more">···</span></div>
          <div class="board-rail"><span>14:00</span><span>15:00</span><span>16:00</span><span>17:00</span></div>
          <div class="docking-outline"><span>让计划，自然落位</span></div>
          <div class="flight-card schedule-event" data-flight="schedule" data-flight-index="0"><span class="event-line"></span><div class="event-top"><span>15:00 — 16:00</span>${icon('sparkle')}</div><h4>为下一个想法，<br>留一点时间。</h4><span class="card-meta">准备提案 <i></i> 专注 60 分钟</span><span class="event-check">${icon('check')}</span></div>
          <div class="flight-card schedule-note" data-flight="schedule" data-flight-index="1"><span class="inset-icon">${icon('check')}</span><div><b>整理今天的灵感</b><small>一件件，慢慢完成</small></div><span class="check-ring"></span></div>
          <div class="flight-card schedule-pebble" data-flight="schedule" data-flight-index="2">${icon('moon')}<span>留白，也是安排。</span></div>
        </div>
        <div class="orbit-chip"><span class="little-orb ice"></span><span>事情有序，思绪自由。</span></div>
      </div>
    </section>
    <section class="chapter chapter-news" id="news" aria-labelledby="news-title">
      <div class="chapter-copy"><span class="chapter-kicker"><span class="little-orb lilac"></span>Orialis 资讯</span><h2 id="news-title">让值得的，<br>被看见。</h2><p>从 AI 动向，到开源世界。<br>看见重点，也能追溯来源。<br>信息很多，你可以从容一点。</p><button class="action" data-demo="news"><span>探索一条资讯</span>${icon('arrow')}</button><small class="demo-caption">示例内容，可展开重点与来源</small></div>
      <div class="product-stage news-stage" aria-label="资讯界面示意">
        <div class="satellite-trace lilac-trace"></div>
        <div class="product-board news-board">
          <div class="news-heading"><span>值得关注</span><span class="sample-tag">示例</span></div>
          <div class="flight-card news-sheet news-sheet-back" data-flight="news" data-flight-index="2"><span class="sheet-source">Projects</span><b>让进展，<br>有迹可循。</b><div class="sheet-lines"><i></i><i></i><i></i></div></div>
          <div class="flight-card news-sheet news-sheet-mid" data-flight="news" data-flight-index="1"><span class="sheet-source">GitHub</span><b>发现代码背后<br>的新可能。</b><span class="code-sigil">{ }</span></div>
          <div class="flight-card news-sheet news-sheet-front" data-flight="news" data-flight-index="0"><span class="sheet-source"><span class="tiny-spark">✦</span> AI Hot <span class="sheet-source-time">精选视野</span></span><h4>每天都有新消息。<br>留下与你有关的。</h4><div class="abstract-signal" aria-hidden="true"><i></i><i></i><i></i><i></i><span></span></div><div class="sheet-bottom"><span>重点，清晰呈现</span><button class="source-pill" data-demo="news">重点与来源 ${icon('arrow')}</button></div></div>
        </div>
        <div class="orbit-chip"><span class="little-orb lilac"></span><span>少一点噪声，多一点视野。</span></div>
      </div>
    </section>
    <section class="chapter chapter-everyday" id="everyday" aria-labelledby="everyday-title">
      <div class="everyday-copy"><span class="chapter-kicker">所有可能，回到日常</span><h2 id="everyday-title">光在身边，<br>日子从容。</h2><p>强大的 AI，自然围绕着你。</p></div>
      <div class="quiet-stage">
        <div class="quiet-orbit" aria-hidden="true"><i></i><span></span></div>
        <div class="quiet-card"><div class="quiet-heading"><span>你的一天</span><span>${icon('sparkle')} 刚刚好</span></div><div class="quiet-row"><span class="quiet-time">15:00</span><div><b>准备提案</b><small>给下一个想法，一小时</small></div><span class="quiet-dot blue"></span></div><div class="quiet-divider"></div><div class="quiet-row"><span class="quiet-icon">${icon('news')}</span><div><b>一条值得读的资讯</b><small>等你有空，再慢慢看</small></div><span class="quiet-dot violet"></span></div><span class="quiet-demo">日常场景示意</span></div>
      </div>
      <div class="ending-actions"><button data-demo="schedule">体验日程 ${icon('arrow')}</button><button data-demo="news">探索资讯 ${icon('arrow')}</button></div>
      <footer class="ending-footer"><span>Orialis</span><p>自然，围绕着你。</p><a href="#origin" data-go="origin">再循光走一遍</a></footer>
    </section>
  </main>
  <nav class="journey-nav" aria-label="旅程章节">${chapters.map((c, i) => `<a href="#${c}" data-go="${c}" aria-label="${labels[c]}"><i></i><span>${labels[c]}</span><small>${String(i + 1).padStart(2, '0')}</small></a>`).join('')}</nav>
  <div class="journey-status" aria-hidden="true"><span id="chapter-current">初见</span><span class="status-line"><i></i></span><span id="chapter-total">05</span></div>
  <div class="scroll-reminder" aria-hidden="true">滚动，光会带路 ${icon('down')}</div>
  ${import.meta.env.DEV ? `<aside class="prototype-switcher" aria-label="原型方案对比"><span class="prototype-tag">原型</span><button data-switch="-1" aria-label="上一个方案">${icon('chevron')}</button><span id="variant-label"></span><button data-switch="1" aria-label="下一个方案">${icon('chevron')}</button><div class="variant-dots">${(['A', 'B', 'C'] as Variant[]).map(v => `<button data-variant="${v}" aria-label="方案${v}：${names[v]}">${v}</button>`).join('')}</div></aside>` : ''}
`;

const body = document.body;
const journey = document.querySelector<HTMLElement>('.journey')!;
const sections = chapters.map(c => document.getElementById(c)!);
const canvas = document.querySelector<HTMLCanvasElement>('#halo')!;
const halo = createHalo(canvas);
body.classList.toggle('no-webgl', !halo);
let rendererUnavailable = !halo;
canvas.addEventListener('webglcontextlost', () => {
  rendererUnavailable = true;
  body.classList.add('no-webgl');
});
const demos = setupDemos();
document.querySelectorAll<HTMLButtonElement>('[data-demo]').forEach(button => {
  button.addEventListener('click', () => demos.open(button.dataset.demo as 'schedule' | 'news'));
});

const clamp = (n: number, a = 0, b = 1) => Math.min(b, Math.max(a, n));
const mix = (a: number, b: number, t: number) => a + (b - a) * t;
const smooth = (a: number, b: number, n: number) => { const t = clamp((n - a) / (b - a)); return t * t * (3 - 2 * t); };
const easeOut = (t: number) => 1 - (1 - clamp(t)) ** 3;
let range = 1;
let progress = 0;
let liveProgress = 0;
let previousTime = 0;
let elapsed = 0;
let haloTime = 5.3;
let lastPaint = 0;
let frameId = 0;
let dirty = true;
let activeChapter: Chapter = 'origin';
let pointer = { x: 0, y: 0 };
let pointerLive = { x: 0, y: 0 };
let camera = { yaw: .13, pitch: .07, distance: 15, offsetX: 0, offsetY: 0, light: 0 };
let settledFrames = 0;
let frameWindowStart = 0;
let frameWindowCount = 0;
let adaptiveQuality = 1;
const narrow = () => innerWidth < 760;
const isFlow = () => variant === 'C' || reduced;

function measure() {
  range = Math.max(1, journey.scrollHeight - innerHeight);
  dirty = true;
}
function readProgress() {
  if (!isFlow()) return clamp(scrollY / range);
  const points = sections.map(s => Math.max(0, s.offsetTop - innerHeight * .13));
  const values = chapters.map(c => stops[c]);
  for (let i = points.length - 1; i >= 0; i--) {
    if (scrollY >= points[i]) {
      if (i === points.length - 1) return 1;
      return mix(values[i], values[i + 1], clamp((scrollY - points[i]) / (points[i + 1] - points[i])));
    }
  }
  return 0;
}

function go(chapter: Chapter) {
  if (!chapters.includes(chapter)) return;
  const y = isFlow() ? Math.max(0, document.getElementById(chapter)!.offsetTop - 72) : stops[chapter] * range;
  const url = new URL(location.href); url.hash = chapter;
  history.replaceState(null, '', url);
  window.scrollTo({ top: y, behavior: reduced ? 'instant' : 'smooth' });
  dirty = true;
}
document.querySelectorAll<HTMLAnchorElement>('[data-go]').forEach(a => a.addEventListener('click', event => {
  event.preventDefault(); go(a.dataset.go as Chapter);
}));

function setVariant(next: Variant, reset = true) {
  variant = next;
  body.dataset.variant = variant;
  const url = new URL(location.href); url.searchParams.set('variant', variant);
  if (reset) url.hash = 'origin';
  history.replaceState(null, '', url);
  document.querySelector('#variant-label')?.replaceChildren(`${variant} · ${names[variant]}`);
  document.querySelectorAll<HTMLButtonElement>('[data-variant]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.variant === variant)));
  measure();
  if (reset) { scrollTo({ top: 0, behavior: 'instant' }); progress = liveProgress = 0; elapsed = 0; }
  dirty = true;
}
function cycle(direction: number) {
  const variants: Variant[] = ['A', 'B', 'C'];
  setVariant(variants[(variants.indexOf(variant) + direction + 3) % 3]);
}
document.querySelectorAll<HTMLButtonElement>('[data-switch]').forEach(b => b.addEventListener('click', () => cycle(Number(b.dataset.switch))));
document.querySelectorAll<HTMLButtonElement>('[data-variant]').forEach(b => b.addEventListener('click', () => setVariant(b.dataset.variant as Variant)));
if (import.meta.env.DEV) window.addEventListener('keydown', e => {
  if (document.querySelector('dialog[open]') || (e.target instanceof Element && e.target.closest('input,textarea,select,[contenteditable="true"]'))) return;
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); cycle(e.key === 'ArrowLeft' ? -1 : 1); }
});

function setReduced() {
  const chapter = activeChapter;
  reduced = systemMotion.matches || userReduced;
  body.classList.toggle('reduced', reduced);
  const button = document.querySelector<HTMLButtonElement>('.motion-toggle')!;
  button.setAttribute('aria-pressed', String(reduced));
  button.querySelector('span')!.textContent = reduced ? '静谧模式' : '减少动态';
  button.title = systemMotion.matches ? '跟随系统减少动态效果设置' : '切换静谧阅读模式';
  measure();
  requestAnimationFrame(() => { if (elapsed > .5) go(chapter); });
}
document.querySelector('.motion-toggle')!.addEventListener('click', () => {
  if (systemMotion.matches) return;
  userReduced = !userReduced; setReduced();
});
systemMotion.addEventListener('change', setReduced);

type Spring = { x: number; v: number };
type Flight = { el: HTMLElement; group: string; index: number; spring: Spring };
const flights: Flight[] = [...document.querySelectorAll<HTMLElement>('[data-flight]')].map(el => ({ el, group: el.dataset.flight!, index: Number(el.dataset.flightIndex), spring: { x: 0, v: 0 } }));
function springStep(s: Spring, target: number, dt: number) {
  let remaining = dt;
  while (remaining > 0) {
    const h = Math.min(remaining, 1 / 120);
    s.v += ((target - s.x) * 180 - s.v * 22) * h;
    s.x += s.v * h;
    remaining -= h;
  }
  if (Math.abs(target - s.x) < .0001 && Math.abs(s.v) < .0001) { s.x = target; s.v = 0; }
}
function updateFlights(p: number, dt: number) {
  for (const f of flights) {
    const base = f.group === 'schedule' ? .283 : .527;
    const target = reduced ? 1 : easeOut((p - base - f.index * .015) / .072);
    if (reduced) { f.spring.x = 1; f.spring.v = 0; } else springStep(f.spring, target, dt);
    const a = 1 - f.spring.x;
    const sign = f.index % 2 ? -1 : 1;
    const spread = narrow() ? 320 : 640;
    const dx = a * sign * (spread + f.index * 110);
    const dy = -a * (190 + f.index * 55) - Math.sin(clamp(f.spring.x) * Math.PI) * (60 + f.index * 20);
    const z = a * (280 + f.index * 90);
    const yaw = a * sign * (55 + f.index * 8);
    const roll = a * sign * (24 + f.index * 9);
    const wave = reduced ? 0 : Math.sin(haloTime * .8 + f.index * 2) * 2.5 * clamp(a);
    f.el.style.transform = `translate3d(${dx.toFixed(2)}px,${(dy + wave).toFixed(2)}px,${z.toFixed(2)}px) rotateX(${(a * -25).toFixed(2)}deg) rotateY(${yaw.toFixed(2)}deg) rotateZ(${roll.toFixed(2)}deg) scale(${(1 + a * .12).toFixed(4)})`;
    f.el.style.opacity = String(clamp((f.spring.x + .1) * 2.4));
    f.el.dataset.docked = String(Math.abs(a) < .008);
  }
}

function setChapter(p: number) {
  const index = p < .16 ? 0 : p < .29 ? 1 : p < .51 ? 2 : p < .77 ? 3 : 4;
  const next = chapters[index];
  if (next !== activeChapter || dirty) {
    activeChapter = next; body.dataset.chapter = next;
    document.querySelector('#chapter-current')!.textContent = labels[next];
    document.querySelectorAll('.journey-nav a').forEach((el, i) => {
      if (i === index) el.setAttribute('aria-current', 'step'); else el.removeAttribute('aria-current');
    });
    document.querySelectorAll('.top-nav a').forEach(el => {
      if ((el as HTMLElement).dataset.go === next) el.setAttribute('aria-current', 'page'); else el.removeAttribute('aria-current');
    });
  }
  body.classList.toggle('light-ui', p > .84);
  const show = [
    1 - smooth(.09, .165, p),
    smooth(.13, .185, p) * (1 - smooth(.26, .3, p)),
    smooth(.275, .325, p) * (1 - smooth(.47, .525, p)),
    smooth(.51, .565, p) * (1 - smooth(.725, .78, p)),
    smooth(.78, .87, p),
  ];
  sections.forEach((s, i) => {
    const opacity = isFlow() ? 1 : show[i];
    s.style.opacity = String(opacity);
    s.style.visibility = opacity > .005 ? 'visible' : 'hidden';
    s.inert = !isFlow() && opacity < .62;
    if (s.inert) s.setAttribute('aria-hidden', 'true'); else s.removeAttribute('aria-hidden');
    s.style.setProperty('--chapter-lift', isFlow() ? '0px' : `${(1 - opacity) * (i === 0 ? -30 : 34)}px`);
  });
  body.style.setProperty('--journey', String(p));
  body.style.setProperty('--calm', String(smooth(.755, .92, p)));
  body.style.setProperty('--title-recede', String(1 + smooth(0, .13, p) * .17));
}

type CameraKey = { p: number; yaw: number; pitch: number; distance: number; offsetX: number; offsetY: number; light: number };
function cameraGoal(p: number) {
  const keys: CameraKey[] = [
    { p: 0, yaw: .13, pitch: .07, distance: mix(17, 9.0, reduced ? 1 : easeOut(elapsed / 2.4)), offsetX: 0, offsetY: -.10, light: 0 },
    { p: .13, yaw: .44, pitch: .22, distance: 6.8, offsetX: .05, offsetY: 0, light: 0 },
    { p: .235, yaw: 1.34, pitch: .47, distance: 4.5, offsetX: .63, offsetY: -.1, light: 0 },
    { p: .38, yaw: 2.02, pitch: .08, distance: 9.6, offsetX: .94, offsetY: -.08, light: 0 },
    { p: .48, yaw: 2.35, pitch: -.05, distance: 9.4, offsetX: .92, offsetY: -.06, light: 0 },
    { p: .6, yaw: 3.02, pitch: .30, distance: 9.6, offsetX: -.95, offsetY: -.06, light: .02 },
    { p: .72, yaw: 3.38, pitch: .41, distance: 9.4, offsetX: -.9, offsetY: -.03, light: .04 },
    { p: .84, yaw: 3.92, pitch: .25, distance: 12.5, offsetX: .25, offsetY: .3, light: .72 },
    { p: 1, yaw: 4.22, pitch: .12, distance: 21.0, offsetX: .50, offsetY: .05, light: 1 },
  ];
  let i = 0;
  while (i < keys.length - 2 && p > keys[i + 1].p) i++;
  const a = keys[i], b = keys[i + 1];
  const t = smooth(a.p, b.p, p);
  const result = { ...camera };
  (Object.keys(result) as (keyof typeof camera)[]).forEach(k => result[k] = mix(a[k], b[k], t));
  if (variant === 'B' && p < .13) { result.distance = 12.7; result.offsetX = .2; result.offsetY = -.08; }
  if (variant === 'C' && p < .15) { result.offsetX = narrow() ? 0 : 1.05; result.distance = narrow() ? 11.5 : 9.6; }
  if (narrow()) { result.offsetX *= .20; result.distance *= 1.14; result.offsetY -= p > .27 && p < .76 ? .23 : .05; }
  if (reduced) { result.yaw = .13; result.pitch = .07; result.distance = 10.5; result.offsetX = 0; result.offsetY = -.1; result.light = 0; }
  return result;
}

function tick(now: number) {
  if (document.hidden) return;
  frameId = requestAnimationFrame(tick);
  const dt = previousTime ? Math.min((now - previousTime) / 1000, .05) : 1 / 60;
  previousTime = now;
  elapsed += dt;
  frameWindowCount++;
  if (!frameWindowStart) frameWindowStart = now;
  if (now - frameWindowStart > 2500) {
    const fps = frameWindowCount * 1000 / (now - frameWindowStart);
    canvas.dataset.motionFps = fps.toFixed(1);
    if (!reduced && fps < 40) adaptiveQuality = Math.max(.60, adaptiveQuality - .12);
    canvas.dataset.quality = adaptiveQuality.toFixed(2);
    frameWindowCount = 0; frameWindowStart = now;
  }
  progress = readProgress();
  const ease = reduced ? 1 : 1 - Math.exp(-dt * 15);
  liveProgress = mix(liveProgress, progress, ease);
  if (Math.abs(liveProgress - progress) < .00002) liveProgress = progress;
  const p = reduced ? progress : liveProgress;
  const active = dirty || !reduced || settledFrames < 2;
  if (!active) return;
  setChapter(p);
  updateFlights(p, dt);
  const calm = smooth(.78, .96, p);
  const inProduct = smooth(.28, .35, p) * (1 - smooth(.735, .81, p));
  body.style.setProperty('--scene-presence', String(1 - inProduct * .53));
  if (!reduced) haloTime += dt * mix(.64, .12, calm);
  pointerLive.x = mix(pointerLive.x, pointer.x, 1 - Math.exp(-dt * 8));
  pointerLive.y = mix(pointerLive.y, pointer.y, 1 - Math.exp(-dt * 8));
  body.style.setProperty('--pointer-x', reduced ? '0' : pointerLive.x.toFixed(3));
  body.style.setProperty('--pointer-y', reduced ? '0' : pointerLive.y.toFixed(3));
  const target = cameraGoal(p);
  const cameraEase = reduced ? 1 : 1 - Math.exp(-dt * 11);
  (Object.keys(camera) as (keyof typeof camera)[]).forEach(k => camera[k] = mix(camera[k], target[k], cameraEase));
  // The GPU runs independently of DOM/card springs; its glow is intentionally
  // lower resolution than text. Input is never blocked by shader rendering.
  if (halo && !rendererUnavailable && !document.querySelector('dialog[open]') && (now - lastPaint > (calm > .98 ? 100 : narrow() ? 42 : 32) || dirty)) {
    halo.render({ ...camera, time: haloTime, yaw: camera.yaw + (reduced ? 0 : pointerLive.x * .04 * (1 - calm)), pitch: camera.pitch + (reduced ? 0 : pointerLive.y * .025), motion: .84, energy: mix(.8, .36, calm), state: 0, quality: (narrow() ? .76 : .92) * adaptiveQuality, satelliteFocus: p > .29 && p < .52 ? 1 : p >= .52 && p < .78 ? 2 : 0 });
    if (halo.stats().error) { rendererUnavailable = true; body.classList.add('no-webgl'); }
    lastPaint = now;
  }
  if (dirty) settledFrames = 0; else settledFrames++;
  dirty = false;
}
window.addEventListener('scroll', () => { dirty = true; }, { passive: true });
window.addEventListener('resize', measure, { passive: true });
window.addEventListener('pointermove', event => {
  if (event.pointerType !== 'mouse') return;
  pointer.x = (event.clientX / innerWidth - .5) * 2;
  pointer.y = (event.clientY / innerHeight - .5) * 2;
}, { passive: true });
document.documentElement.addEventListener('pointerleave', () => { pointer = { x: 0, y: 0 }; });
document.addEventListener('visibilitychange', () => {
  cancelAnimationFrame(frameId); previousTime = 0; frameWindowStart = 0; frameWindowCount = 0;
  if (!document.hidden) { dirty = true; frameId = requestAnimationFrame(tick); }
});
window.addEventListener('pagehide', () => { cancelAnimationFrame(frameId); halo?.dispose(); }, { once: true });

setVariant(variant, false);
setReduced();
measure();
frameId = requestAnimationFrame(tick);
const initialChapter = location.hash.slice(1) as Chapter;
if (chapters.includes(initialChapter)) requestAnimationFrame(() => go(initialChapter));
// A read-only probe reports state, not an alternate path for UI verification.
Object.defineProperty(window, 'OrialisJourney', { value: { getState: () => ({ variant, reduced, progress, liveProgress, activeChapter, camera: { ...camera }, flights: flights.map(f => ({ group: f.group, index: f.index, progress: f.spring.x, velocity: f.spring.v })), renderer: halo?.stats() ?? null }) } });
