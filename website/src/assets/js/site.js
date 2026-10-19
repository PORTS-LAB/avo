// Every page: the header and menu, the haze, reveals on scroll and motion
// that follows the pointer; on the home page also the games showcase, the
// settings tour's tabs and click to zoom on screenshots.
// Nothing here is required to read the site; without JavaScript the content
// is all there.

import { mountHaze } from './haze-field.js';
import { setupLightbox } from './lightbox.js';
import { setupMotion } from './motion.js';
import { setupShowcase } from './showcase.js';
import { makeTabs } from './tabs.js';

const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

function setupHeader() {
  const header = document.querySelector('[data-header]');
  if (!header) return;
  const onScroll = () => header.classList.toggle('is-scrolled', window.scrollY > 8);
  onScroll();
  window.addEventListener('scroll', onScroll, { passive: true });

  const toggle = header.querySelector('[data-nav-toggle]');
  const nav = header.querySelector('[data-nav]');
  if (!toggle || !nav) return;
  const label = toggle.querySelector('[data-label-open]');
  const openLabel = label.textContent;
  const closeLabel = toggle.dataset.closeLabel || openLabel;
  toggle.hidden = false;

  const setOpen = (open) => {
    toggle.setAttribute('aria-expanded', String(open));
    nav.classList.toggle('is-open', open);
    header.classList.toggle('is-open', open);
    label.textContent = open ? closeLabel : openLabel;
  };
  toggle.addEventListener('click', () => setOpen(toggle.getAttribute('aria-expanded') !== 'true'));
  nav.addEventListener('click', (event) => {
    if (event.target.closest('a')) setOpen(false);
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
      setOpen(false);
      toggle.focus();
    }
  });
  window.matchMedia('(min-width: 981px)').addEventListener('change', (event) => {
    if (event.matches) setOpen(false);
  });
}

/** Marks the menu link of the section being read. */
function setupCurrentSection() {
  const links = [...document.querySelectorAll('[data-nav] a[href*="#"]')];
  const map = new Map();
  for (const link of links) {
    const url = new URL(link.href);
    if (url.pathname !== window.location.pathname) continue;
    const target = url.hash && document.getElementById(decodeURIComponent(url.hash.slice(1)));
    if (target) map.set(target, link);
  }
  if (!map.size || !('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        const link = map.get(entry.target);
        if (entry.isIntersecting) {
          for (const other of map.values()) other.removeAttribute('aria-current');
          link.setAttribute('aria-current', 'location');
        }
      }
    },
    { rootMargin: '-45% 0px -50% 0px' },
  );
  for (const target of map.keys()) io.observe(target);
}

/**
 * Scroll reveals: what is below the fold rises and fades in as it arrives.
 * Things that arrive together come in one after another, top to bottom and
 * left to right. Nothing already on screen is hidden, and nothing moves for
 * visitors who prefer reduced motion.
 */
function setupReveal() {
  if (reduceMotion.matches || !('IntersectionObserver' in window)) return;
  const selector = [
    '.section-head > *', '.feature-card', '.tile', '.steps li', '.showcase', '.req-list > div', '.faq-list',
    '.channels-block', '.plain-list li', '.also', '.tour-gallery', '.status-note', '.more-link', '.dev-grid .cta-row',
  ].join(',');
  const io = new IntersectionObserver(
    (entries) => {
      const arriving = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top || a.boundingClientRect.left - b.boundingClientRect.left);
      arriving.forEach((entry, i) => {
        const el = entry.target;
        el.style.setProperty('--reveal-delay', `${Math.min(i, 6) * 85}ms`);
        el.classList.add('reveal-in');
        el.classList.remove('reveal-pending');
        io.unobserve(el);
      });
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.08 },
  );
  const fold = window.innerHeight * 0.9;
  for (const el of document.querySelectorAll(selector)) {
    // Never hide what is already on screen.
    if (el.getBoundingClientRect().top < fold) continue;
    el.classList.add('reveal-pending');
    io.observe(el);
  }
}

/**
 * Looping animations (the recording dot, the hotspots' pulse) pause while
 * their section is off screen.
 */
function setupOffscreenPause() {
  if (!('IntersectionObserver' in window)) return;
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) entry.target.classList.toggle('is-offscreen', !entry.isIntersecting);
    },
    { rootMargin: '100px 0px' },
  );
  for (const section of document.querySelectorAll('.hero, .section')) io.observe(section);
}

/**
 * The settings tour: without JavaScript every screenshot is shown with its
 * caption. Here the captions become tabs beside one large screenshot, and the
 * screenshots cross-fade, moving the way the list moves.
 */
function setupTour() {
  const tour = document.querySelector('[data-tour]');
  const items = tour ? [...tour.querySelectorAll('[data-tour-item]')] : [];
  if (items.length < 2) return;

  const tabs = makeTabs({
    items,
    label: tour.dataset.tourLabel,
    prefix: 'tour',
    titleOf: (item) => item.querySelector('h3')?.textContent ?? '',
    textOf: (item) => item.querySelector('figcaption p')?.textContent ?? '',
    animate: () => !reduceMotion.matches,
    onSelect(index) {
      items.forEach((item, i) => {
        const on = i === index;
        item.classList.toggle('is-off', !on);
        // Screens above the chosen one wait above it, the others below.
        item.style.setProperty('--off', i < index ? '-1' : '1');
        item.inert = !on;
        item.setAttribute('aria-hidden', String(!on));
      });
    },
  });
  tour.prepend(tabs.list);
  tour.classList.add('is-tabbed');
  const linked = items.findIndex((item) => `#${item.id}` === window.location.hash);
  tabs.select(linked >= 0 ? linked : 0);

  // Hidden panels would only start loading when chosen: fetch them early.
  const warm = () => {
    for (const img of tour.querySelectorAll('img[loading="lazy"]')) img.loading = 'eager';
  };
  if (!('IntersectionObserver' in window)) return warm();
  const io = new IntersectionObserver(
    (entries) => {
      if (entries.some((e) => e.isIntersecting)) {
        io.disconnect();
        warm();
      }
    },
    { rootMargin: '600px 0px' },
  );
  io.observe(tour);
}

// Where the pointer is over the hero, for the haze's light (motion.js fills it in).
const hazePointer = { x: 0.5, y: 0.5, active: false };

function setupHaze() {
  for (const canvas of document.querySelectorAll('canvas[data-haze]')) {
    try {
      mountHaze(canvas, canvas.dataset.haze, { reduceMotion, pointer: canvas.closest('[data-hero]') ? hazePointer : null });
    } catch {
      // The CSS background stays.
    }
  }
}

// Layout changes first (tabs, the stacked showcase), so the reveals measure
// the page as it will stay.
setupHeader();
setupCurrentSection();
setupTour();
setupShowcase({ reduceMotion });
setupLightbox({ reduceMotion });
setupHaze();
setupReveal();
setupOffscreenPause();
setupMotion({ reduceMotion, hazePointer });
