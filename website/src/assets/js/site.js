// Every page: the header and menu, the haze, gentle reveals, and (on the home
// page) the settings tour's tabs.
// Nothing here is required to read the site; without JavaScript the content
// is all there.

import { mountHaze } from './haze-field.js';

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

function setupReveal() {
  if (reduceMotion.matches || !('IntersectionObserver' in window)) return;
  const selector = [
    '.section-head', '.feature', '.tile', '.steps li', '.art', '.req-list > div', '.faq-list',
    '.channels-block', '.plain-list li', '.also', '.tour-gallery',
  ].join(',');
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add('reveal-in');
        entry.target.classList.remove('reveal-pending');
        io.unobserve(entry.target);
      }
    },
    { rootMargin: '0px 0px -6% 0px', threshold: 0.06 },
  );
  const fold = window.innerHeight * 0.9;
  const groups = new Map();
  for (const el of document.querySelectorAll(selector)) {
    // Never hide what is already on screen.
    if (el.getBoundingClientRect().top < fold) continue;
    const index = groups.get(el.parentElement) ?? 0;
    groups.set(el.parentElement, index + 1);
    el.style.transitionDelay = `${Math.min(index, 5) * 70}ms`;
    el.classList.add('reveal-pending');
    io.observe(el);
  }
}

/**
 * The settings tour: without JavaScript every screenshot is shown with its
 * caption. Here the captions become tabs (WAI-ARIA tabs pattern: arrow keys,
 * Home and End move between them) beside one large screenshot.
 */
function setupTour() {
  const tour = document.querySelector('[data-tour]');
  const items = tour ? [...tour.querySelectorAll('[data-tour-item]')] : [];
  if (items.length < 2) return;

  const list = document.createElement('div');
  list.className = 'tour-tabs';
  list.setAttribute('role', 'tablist');
  list.setAttribute('aria-label', tour.dataset.tourLabel || '');
  const tabs = items.map((item) => {
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = 'tour-tab';
    tab.id = `${item.id}-tab`;
    tab.setAttribute('role', 'tab');
    tab.setAttribute('aria-controls', item.id);
    const title = document.createElement('span');
    title.className = 'tour-tab-title';
    title.id = `${item.id}-tab-title`;
    title.textContent = item.querySelector('h3')?.textContent ?? '';
    tab.append(title);
    tab.setAttribute('aria-labelledby', title.id);
    const caption = item.querySelector('figcaption p');
    if (caption) {
      const text = document.createElement('span');
      text.className = 'tour-tab-text';
      text.id = `${item.id}-tab-text`;
      text.textContent = caption.textContent;
      tab.append(text);
      tab.setAttribute('aria-describedby', text.id);
    }
    item.setAttribute('role', 'tabpanel');
    item.setAttribute('aria-labelledby', tab.id);
    item.tabIndex = 0;
    return tab;
  });

  const select = (index, focus = false) => {
    tabs.forEach((tab, i) => {
      const on = i === index;
      tab.setAttribute('aria-selected', String(on));
      tab.tabIndex = on ? 0 : -1;
      items[i].hidden = !on;
    });
    if (focus) tabs[index].focus();
  };
  list.addEventListener('click', (event) => {
    const tab = event.target.closest('[role="tab"]');
    if (tab) select(tabs.indexOf(tab));
  });
  list.addEventListener('keydown', (event) => {
    const current = tabs.indexOf(document.activeElement);
    if (current < 0) return;
    const last = tabs.length - 1;
    const next = {
      ArrowRight: current === last ? 0 : current + 1,
      ArrowDown: current === last ? 0 : current + 1,
      ArrowLeft: current === 0 ? last : current - 1,
      ArrowUp: current === 0 ? last : current - 1,
      Home: 0,
      End: last,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    select(next, true);
  });

  list.append(...tabs);
  tour.prepend(list);
  tour.classList.add('is-tabbed');
  const linked = items.findIndex((item) => `#${item.id}` === window.location.hash);
  select(linked >= 0 ? linked : 0);

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

function setupHaze() {
  for (const canvas of document.querySelectorAll('canvas[data-haze]')) {
    try {
      mountHaze(canvas, canvas.dataset.haze, { reduceMotion });
    } catch {
      // The CSS background stays.
    }
  }
}

setupHeader();
setupCurrentSection();
setupTour();
setupHaze();
setupReveal();
