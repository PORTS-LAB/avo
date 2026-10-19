// The games showcase: two screenshots stacked like cards, the one behind
// peeking out, chosen with tabs beside them (or by clicking the card behind).
// Hotspots over the key labels say what each key does: they open on hover
// and focus with CSS alone; here a tap opens and closes them too, and Escape
// hides the one open. Without JavaScript both screenshots show side by side.

import { makeTabs } from './tabs.js';

export function setupShowcase({ reduceMotion }) {
  const root = document.querySelector('[data-showcase]');
  const items = root ? [...root.querySelectorAll('[data-showcase-item]')] : [];
  if (items.length < 2) return;
  const stage = root.querySelector('.showcase-stage');
  const spots = [...root.querySelectorAll('.hotspot')];
  const closeAll = (except = null) => {
    for (const spot of spots) if (spot !== except) spot.classList.remove('is-open');
  };

  const tabs = makeTabs({
    items,
    label: root.dataset.showcaseLabel,
    prefix: 'showcase',
    numbered: true,
    titleOf: (item) => item.querySelector('.shot-label')?.textContent ?? '',
    textOf: (item) => item.querySelector('.shot-text')?.textContent ?? '',
    animate: () => !reduceMotion.matches,
    onSelect(index, previous) {
      items.forEach((item, i) => {
        const front = i === index;
        item.classList.toggle('is-front', front);
        item.classList.toggle('is-back', !front);
        // The card behind is only a glimpse: its hotspots and button are
        // hidden (CSS), and assistive technology skips it.
        item.setAttribute('aria-hidden', String(!front));
      });
      closeAll();
      if (previous >= 0 && !reduceMotion.matches) {
        const arriving = items[index];
        arriving.classList.remove('is-arriving');
        // Restart the light that sweeps across the card as it arrives.
        void arriving.offsetWidth;
        arriving.classList.add('is-arriving');
        window.setTimeout(() => arriving.classList.remove('is-arriving'), 1200);
      }
      root.dispatchEvent(new CustomEvent('showcase:change'));
    },
  });

  // First in reading order: choose a screenshot, then explore it.
  root.prepend(tabs.list);
  for (const shot of root.querySelectorAll('.shot')) {
    const sweep = document.createElement('span');
    sweep.className = 'shot-sweep';
    sweep.setAttribute('aria-hidden', 'true');
    shot.querySelector(':scope > picture')?.after(sweep);
  }
  root.classList.add('is-enhanced');
  tabs.select(0);

  // The card behind comes forward when clicked.
  for (const [i, item] of items.entries()) {
    item.addEventListener('click', (event) => {
      if (!item.classList.contains('is-back')) return;
      event.preventDefault();
      event.stopPropagation();
      tabs.select(i);
    });
  }

  // ---------------------------------------------------------------- hotspots
  root.addEventListener('click', (event) => {
    const dot = event.target.closest('.hotspot-dot');
    if (!dot) return;
    // With a mouse, hovering already shows the tip; a tap or a key press
    // pins it open until the next one.
    if (event.pointerType === 'mouse') return;
    const spot = dot.closest('.hotspot');
    const open = !spot.classList.contains('is-open');
    closeAll(spot);
    spot.classList.toggle('is-open', open);
    spot.classList.remove('is-dismissed');
  });
  document.addEventListener('click', (event) => {
    if (!event.target.closest('.hotspot')) closeAll();
  });

  // Escape hides a tip shown by hover or focus, until the pointer or focus
  // moves on (WCAG 1.4.13).
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    const shown = spots.filter((s) => s.classList.contains('is-open') || s.matches(':hover, :focus-within'));
    for (const spot of shown) spot.classList.add('is-dismissed');
    closeAll();
  });
  for (const spot of spots) {
    const reset = () => spot.classList.remove('is-dismissed');
    spot.addEventListener('pointerleave', reset);
    spot.addEventListener('focusout', reset);
  }

  // While a tip is being read, the deck holds almost still (motion.js).
  stage.addEventListener('pointerover', (event) => {
    if (event.target.closest('.hotspot')) stage.classList.add('is-calm');
  });
  stage.addEventListener('pointerout', (event) => {
    if (event.target.closest('.hotspot') && !event.relatedTarget?.closest?.('.hotspot')) stage.classList.remove('is-calm');
  });
}
