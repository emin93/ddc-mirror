(() => {
  const root = document.documentElement;
  const stage = document.querySelector('.stage');
  const sunEl = document.querySelector('.celestial--sun');
  const macPct = document.querySelector('[data-mac-pct]');
  const extPct = document.querySelector('[data-ext-pct]');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  const PERIOD_MS = 28000;

  const FLOOR = 0.06;
  const SUN_AMP = 0.92;

  // bell curve with wrap-around — used for crossfading sky layers
  function bell(phase, center, halfWidth) {
    let d = Math.abs(phase - center);
    if (d > 0.5) d = 1 - d;
    return Math.max(0, 1 - d / halfWidth);
  }

  // measure stage size for sun positioning — re-measured on resize.
  // Using transform: translate3d with pixel values keeps the sun on its own
  // compositor layer (no layout/paint when it moves).
  let stageW = 0;
  let stageH = 0;
  function measure() {
    const r = stage.getBoundingClientRect();
    stageW = r.width;
    stageH = r.height;
  }
  measure();
  const ro = new ResizeObserver(measure);
  ro.observe(stage);

  let rafId = null;
  let startTime = null;
  let onScreen = true;
  let lastPctText = -1;

  function update(now) {
    if (startTime === null) startTime = now;
    const phase = (((now - startTime) / PERIOD_MS) % 1 + 1) % 1;

    // sun arc — visible during phase 0.25..0.75
    const dayAngle = (phase - 0.25) / 0.5;
    const sunUp = dayAngle >= 0 && dayAngle <= 1;
    const sunArc = sunUp ? Math.sin(dayAngle * Math.PI) : 0;
    const sunX = sunUp ? dayAngle : 0;
    const sunY = sunArc;

    // brightness — both screens share the same value, parallel
    const brightness = Math.min(0.98, FLOOR + sunArc * SUN_AMP);

    // sky crossfade amounts (cheap — only opacity, GPU composite)
    const dayAmount = bell(phase, 0.5, 0.30);
    const duskAmount = Math.max(bell(phase, 0.25, 0.10), bell(phase, 0.75, 0.10));
    const nightAmount = bell(phase, 0.0, 0.25);
    const starsAmount = Math.max(0, 1 - sunArc * 1.3 - duskAmount * 0.6);

    // ----- writes -----
    // single CSS var, propagates to dimmer + sensor + LED via existing CSS calc
    root.style.setProperty('--brightness', brightness.toFixed(3));
    root.style.setProperty('--day-amount', dayAmount.toFixed(3));
    root.style.setProperty('--dusk-amount', duskAmount.toFixed(3));
    root.style.setProperty('--night-amount', nightAmount.toFixed(3));
    root.style.setProperty('--stars-amount', starsAmount.toFixed(3));

    // sun: direct transform — composite-only, no layout invalidation
    if (sunUp) {
      const px = sunX * stageW;
      const py = (0.85 - sunY * 0.70) * stageH;
      sunEl.style.transform = `translate3d(${px.toFixed(1)}px, ${py.toFixed(1)}px, 0)`;
      sunEl.style.opacity = sunArc.toFixed(3);
    } else {
      sunEl.style.opacity = '0';
    }

    // only re-write text when the integer percentage actually changes
    const pct = Math.round(brightness * 100);
    if (pct !== lastPctText) {
      const text = pct + '%';
      macPct.textContent = text;
      extPct.textContent = text;
      lastPctText = pct;
    }

    rafId = requestAnimationFrame(update);
  }

  function start() {
    if (rafId !== null) return;
    rafId = requestAnimationFrame(update);
  }
  function stop() {
    if (rafId !== null) cancelAnimationFrame(rafId);
    rafId = null;
  }

  if (reduceMotion) {
    // single static frame at late morning
    startTime = performance.now() - 0.42 * PERIOD_MS;
    update(performance.now());
    stop();
  } else {
    // pause the loop when the demo scrolls offscreen — saves CPU on long pages
    if ('IntersectionObserver' in window) {
      const io = new IntersectionObserver((entries) => {
        for (const e of entries) {
          onScreen = e.isIntersecting;
          if (onScreen) start();
          else stop();
        }
      }, { rootMargin: '50px' });
      io.observe(stage);
    } else {
      start();
    }
  }

  // ----- copy-to-clipboard -----
  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const sel = btn.getAttribute('data-copy');
      const el = sel ? document.querySelector(sel) : null;
      if (!el) return;
      const text = el.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        const range = document.createRange();
        range.selectNodeContents(el);
        const sel2 = window.getSelection();
        sel2.removeAllRanges();
        sel2.addRange(range);
        try { document.execCommand('copy'); } catch {}
        sel2.removeAllRanges();
      }
      const def = btn.querySelector('[data-copy-default]');
      const done = btn.querySelector('[data-copy-done]');
      if (def && done) {
        def.hidden = true;
        done.hidden = false;
        setTimeout(() => { def.hidden = false; done.hidden = true; }, 1400);
      }
    });
  });
})();
