(() => {
  const root = document.documentElement;
  const macPct = document.querySelector('[data-mac-pct]');
  const extPct = document.querySelector('[data-ext-pct]');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // one full day-night cycle, in ms — slow enough to feel like time passes,
  // fast enough that visitors see a full loop without scrolling away
  const PERIOD_MS = 28000;

  // brightness shape
  const FLOOR = 0.06;        // 0% would make both screens disappear into the bezel
  const SUN_AMP = 0.88;      // peak daylight contribution
  const MOON_AMP = 0.10;     // moon adds a hint of bias overnight

  // bell curve with wrap-around (phase is on the unit circle)
  function bell(phase, center, halfWidth) {
    let d = Math.abs(phase - center);
    if (d > 0.5) d = 1 - d;
    return Math.max(0, 1 - d / halfWidth);
  }

  let rafId = null;
  let startTime = null;

  function update(now) {
    if (startTime === null) startTime = now;
    const phase = (((now - startTime) / PERIOD_MS) % 1 + 1) % 1;

    // ----- sun: visible during phase 0.25..0.75 (one half of the cycle) -----
    const dayAngle = (phase - 0.25) / 0.5;          // 0..1 across the daytime arc
    const sunUp = dayAngle >= 0 && dayAngle <= 1;
    const sunArc = sunUp ? Math.sin(dayAngle * Math.PI) : 0;
    const sunX = sunUp ? dayAngle : 0;
    const sunY = sunArc;

    // ----- moon: visible during the other half, phase 0.75..1.25 (wrap) -----
    const moonPhase = (phase - 0.75 + 1) % 1;       // 0..1 across the night arc
    const moonUp = moonPhase >= 0 && moonPhase <= 1;
    const moonArc = moonUp ? Math.sin(moonPhase * Math.PI) : 0;
    const moonX = moonPhase;
    const moonY = moonArc;

    // ----- brightness -----
    const brightness = Math.min(
      0.98,
      FLOOR + sunArc * SUN_AMP + moonArc * MOON_AMP
    );

    // ----- sky layer amounts (crossfade between night → dusk → day → dusk → night) -----
    const dayAmount = bell(phase, 0.5, 0.30);
    const duskAmount = Math.max(bell(phase, 0.25, 0.10), bell(phase, 0.75, 0.10));
    const nightAmount = bell(phase, 0.0, 0.25);
    const starsAmount = Math.max(0, 1 - sunArc * 1.3 - duskAmount * 0.6);

    root.style.setProperty('--brightness', brightness.toFixed(3));
    root.style.setProperty('--sun-x', sunX.toFixed(3));
    root.style.setProperty('--sun-y', sunY.toFixed(3));
    root.style.setProperty('--sun-vis', sunArc.toFixed(3));
    root.style.setProperty('--moon-x', moonX.toFixed(3));
    root.style.setProperty('--moon-y', moonY.toFixed(3));
    root.style.setProperty('--moon-vis', moonArc.toFixed(3));
    root.style.setProperty('--day-amount', dayAmount.toFixed(3));
    root.style.setProperty('--dusk-amount', duskAmount.toFixed(3));
    root.style.setProperty('--night-amount', nightAmount.toFixed(3));
    root.style.setProperty('--stars-amount', starsAmount.toFixed(3));

    const pct = Math.round(brightness * 100) + '%';
    macPct.textContent = pct;
    extPct.textContent = pct;

    rafId = requestAnimationFrame(update);
  }

  function freezeAt(phase) {
    // single static frame — used for reduced-motion
    startTime = performance.now() - phase * PERIOD_MS;
    update(performance.now());
    cancelAnimationFrame(rafId);
    rafId = null;
  }

  if (reduceMotion) {
    freezeAt(0.42); // late morning — clearly daytime, both screens lit
  } else {
    rafId = requestAnimationFrame(update);
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
