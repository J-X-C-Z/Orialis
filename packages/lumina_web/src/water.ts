import { useEffect, type RefObject } from 'react';

// Shared by all surfaces in one provider: bounded work, no idle animation loop.
export function useGlassWater(root: RefObject<HTMLDivElement | null>) {
  useEffect(() => {
    const host = root.current;
    if (!host) return;
    const reduced = matchMedia('(prefers-reduced-motion: reduce)');
    const opaque = matchMedia('(prefers-reduced-transparency: reduce)');
    const contrast = matchMedia('(forced-colors: active)');
    const suppressed = () => reduced.matches || opaque.matches || contrast.matches;
    const slow = (navigator.hardwareConcurrency || 4) <= 4;
    type Field = { canvas: HTMLCanvasElement; ctx: CanvasRenderingContext2D; a: Float32Array; b: Float32Array; pixels: ImageData; w: number; h: number; until: number; last: number; lastInput: number; x: number; y: number; dark: boolean };
    const fields = new Map<HTMLElement, Field>();
    let frame = 0;
    let previous = 0;
    let coarse = slow;
    let costly = 0;
    function discard(el: HTMLElement) { fields.get(el)?.canvas.remove(); fields.delete(el); }
    function clear() { cancelAnimationFrame(frame); frame = 0; previous = 0; fields.forEach((_, el) => discard(el)); }
    function tick(now: number) {
      frame = 0;
      if (document.hidden || suppressed()) { clear(); return; }
      if (previous && now - previous > 28 && ++costly > 8) coarse = true;
      previous = now;
      fields.forEach((f, el) => {
        const rect = el.getBoundingClientRect();
        if (now > f.until || !el.isConnected || !f.canvas.isConnected || rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) { discard(el); return; }
        if (now - f.last < (coarse ? 30 : 15)) return;
        f.last = now;
        const { a, b, w, h, pixels } = f;
        for (let y = 1; y < h - 1; y++) for (let x = 1; x < w - 1; x++) {
          const i = y * w + x;
          b[i] = ((a[i - 1] + a[i + 1] + a[i - w] + a[i + w]) * .5 - b[i]) * .965;
          const light = (a[i - 1] - a[i + 1]) * .65 + (a[i - w] - a[i + w]) * .85;
          const p = i * 4;
          const bright = light > 0;
          pixels.data[p] = bright ? 233 : 43;
          pixels.data[p + 1] = bright ? 246 : 70;
          pixels.data[p + 2] = bright ? 255 : 110;
          pixels.data[p + 3] = Math.min(f.dark ? 52 : 70, Math.abs(light) * (f.dark ? 55 : 85) * Math.min(1, (f.until - now) / 350));
        }
        f.a = b; f.b = a;
        f.ctx.putImageData(pixels, 0, 0);
      });
      if (fields.size) frame = requestAnimationFrame(tick);
      else previous = 0;
    }
    function stimulate(event: PointerEvent) {
      if (document.hidden || suppressed()) return;
      const moving = event.type === 'pointermove';
      if (moving && (event.pointerType !== 'mouse' || coarse)) return;
      const target = (event.target as Element).closest<HTMLElement>('[data-lumina-water]');
      if (!target || target.dataset.luminaWater !== 'true' || !host!.contains(target) || target.matches(':disabled,[aria-disabled="true"]') || target.querySelector('input:disabled')) return;
      const el = target.querySelector<HTMLElement>(':scope > [data-water-surface]') ?? target;
      const rect = el.getBoundingClientRect();
      if (!rect.width || !rect.height || event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) return;
      let f = fields.get(el);
      const now = performance.now();
      if (moving && f && now - f.lastInput < 35) return;
      if (!f) {
        if (fields.size >= (coarse ? 2 : 4)) discard(fields.keys().next().value!);
        const canvas = document.createElement('canvas');
        canvas.className = 'lumina-water-canvas'; canvas.setAttribute('aria-hidden', 'true');
        const cell = Math.max(coarse ? 7 : 4, rect.width / 144, rect.height / 96);
        const w = Math.max(6, Math.ceil(rect.width / cell)); const h = Math.max(6, Math.ceil(rect.height / cell));
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d'); if (!ctx) return;
        f = { canvas, ctx, w, h, a: new Float32Array(w * h), b: new Float32Array(w * h), pixels: ctx.createImageData(w, h), until: now + 1400, last: 0, lastInput: 0, x: event.clientX, y: event.clientY, dark: host!.dataset.theme === 'dark' };
        el.appendChild(canvas); fields.set(el, f);
      }
      const speed = Math.hypot(event.clientX - f.x, event.clientY - f.y) / Math.max(16, now - f.lastInput);
      f.x = event.clientX; f.y = event.clientY; f.lastInput = now;
      f.until = now + 1400;
      const x = event.clientX - rect.left, y = event.clientY - rect.top;
      const gx = x / rect.width * (f.w - 1), gy = y / rect.height * (f.h - 1);
      for (let yy = Math.max(1, Math.floor(gy - 3)); yy <= Math.min(f.h - 2, gy + 3); yy++) for (let xx = Math.max(1, Math.floor(gx - 3)); xx <= Math.min(f.w - 2, gx + 3); xx++) {
        const distance = Math.hypot(xx - gx, yy - gy);
        if (distance < 3) f.a[yy * f.w + xx] += Math.cos(distance / 3 * Math.PI / 2) * (moving ? Math.min(.5, .15 + speed * .22) : 1.25);
      }
      if (!frame) frame = requestAnimationFrame(tick);
    }
    host.addEventListener('pointermove', stimulate, { passive: true });
    host.addEventListener('pointerdown', stimulate, { passive: true });
    document.addEventListener('visibilitychange', clear);
    reduced.addEventListener('change', clear);
    opaque.addEventListener('change', clear);
    contrast.addEventListener('change', clear);
    return () => { clear(); host.removeEventListener('pointermove', stimulate); host.removeEventListener('pointerdown', stimulate); document.removeEventListener('visibilitychange', clear); reduced.removeEventListener('change', clear); opaque.removeEventListener('change', clear); contrast.removeEventListener('change', clear); };
  }, [root]);
}
