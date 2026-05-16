(() => {
  const root = document.documentElement;
  const macPct = document.querySelector('[data-mac-pct]');
  const extPct = document.querySelector('[data-ext-pct]');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // brightness keyframes: target value (0..1) and how long to hold once reached (ms)
  const sequence = [
    { v: 0.30, hold: 1200 },
    { v: 0.68, hold: 1500 },
    { v: 0.94, hold: 1900 },
    { v: 0.42, hold: 1500 },
    { v: 0.16, hold: 1300 },
    { v: 0.74, hold: 1700 },
  ];

  // ease curves picked by hand — not `linear`, not `ease`
  const easeOutQuart = (t) => 1 - Math.pow(1 - t, 4);

  const TRANSITION_MS = 1100;   // ms to ease from current to next target
  const MIRROR_LAG_MS = 340;    // external monitor lags behind built-in (feels like real DDC)
  const TRAIL_LIMIT   = 720;    // ring buffer for past brightness samples

  let idx = 0;
  let phase = 'transition';      // 'transition' | 'hold'
  let phaseStart = performance.now();
  let from = sequence[sequence.length - 1].v;
  let to   = sequence[0].v;

  // ring buffer: [{ t, v }, ...] — used to mirror with a real time delay
  const trail = [];

  function setBuiltin(v) {
    root.style.setProperty('--brightness-builtin', v.toFixed(3));
    macPct.textContent = Math.round(v * 100) + '%';
  }
  function setExternal(v) {
    root.style.setProperty('--brightness-external', v.toFixed(3));
    extPct.textContent = Math.round(v * 100) + '%';
  }

  function pushSample(t, v) {
    trail.push({ t, v });
    if (trail.length > TRAIL_LIMIT) trail.shift();
  }

  function sampleAt(targetT) {
    // find the most recent sample at or before targetT
    if (trail.length === 0) return 0.28;
    for (let i = trail.length - 1; i >= 0; i--) {
      if (trail[i].t <= targetT) return trail[i].v;
    }
    return trail[0].v;
  }

  let rafId = null;

  function tick(now) {
    const elapsed = now - phaseStart;
    let v;

    if (phase === 'transition') {
      const t = Math.min(1, elapsed / TRANSITION_MS);
      v = from + (to - from) * easeOutQuart(t);
      if (t >= 1) {
        phase = 'hold';
        phaseStart = now;
        v = to;
      }
    } else {
      v = to;
      if (elapsed >= sequence[idx].hold) {
        from = to;
        idx = (idx + 1) % sequence.length;
        to = sequence[idx].v;
        phase = 'transition';
        phaseStart = now;
      }
    }

    setBuiltin(v);
    pushSample(now, v);

    // mirror: lookup what builtin was MIRROR_LAG_MS ago
    setExternal(sampleAt(now - MIRROR_LAG_MS));

    rafId = requestAnimationFrame(tick);
  }

  function start() {
    setBuiltin(0.28);
    setExternal(0.28);
    pushSample(performance.now(), 0.28);
    rafId = requestAnimationFrame(tick);
  }

  function stop() {
    if (rafId !== null) cancelAnimationFrame(rafId);
    rafId = null;
  }

  if (reduceMotion) {
    setBuiltin(0.70);
    setExternal(0.70);
  } else {
    start();
    // pause when tab is hidden — saves battery, avoids large catch-up jumps
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        stop();
      } else if (!rafId) {
        // reset phase so the loop resumes smoothly instead of fast-forwarding
        phaseStart = performance.now();
        rafId = requestAnimationFrame(tick);
      }
    });
  }

  // copy-to-clipboard
  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const sel = btn.getAttribute('data-copy');
      const el = sel ? document.querySelector(sel) : null;
      if (!el) return;
      const text = el.textContent.trim();
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // fallback for older browsers / file:// origins
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
