// Tabs built from figures that are all visible without JavaScript, following
// the WAI-ARIA tabs pattern: arrow keys, Home and End move between them.
// When the chosen tab grows or shrinks (its description shows only while it
// is chosen), the others glide to their new place instead of jumping.

const EASE_OUT = 'cubic-bezier(0.16, 1, 0.3, 1)';

/**
 * items: the panels (each with an id). prefix names the classes
 * (`${prefix}-tabs`, `${prefix}-tab`, `${prefix}-tab-title`, ...).
 * onSelect(index, previous) shows the chosen panel. animate() says whether
 * to animate (false when the visitor prefers reduced motion).
 */
export function makeTabs({ items, label, prefix, numbered = false, titleOf, textOf, onSelect, animate = () => true }) {
  const list = document.createElement('div');
  list.className = `${prefix}-tabs`;
  list.setAttribute('role', 'tablist');
  if (label) list.setAttribute('aria-label', label);

  const tabs = items.map((item, i) => {
    const tab = document.createElement('button');
    tab.type = 'button';
    tab.className = `${prefix}-tab`;
    tab.id = `${item.id}-tab`;
    tab.setAttribute('role', 'tab');
    tab.setAttribute('aria-controls', item.id);
    if (numbered) {
      const number = document.createElement('span');
      number.className = `${prefix}-tab-num`;
      number.setAttribute('aria-hidden', 'true');
      number.textContent = String(i + 1).padStart(2, '0');
      tab.append(number);
    }
    const title = document.createElement('span');
    title.className = `${prefix}-tab-title`;
    title.id = `${item.id}-tab-title`;
    title.textContent = titleOf(item);
    tab.append(title);
    tab.setAttribute('aria-labelledby', title.id);
    const description = textOf(item);
    if (description) {
      const text = document.createElement('span');
      text.className = `${prefix}-tab-text`;
      text.id = `${item.id}-tab-text`;
      text.textContent = description;
      tab.append(text);
      tab.setAttribute('aria-describedby', text.id);
    }
    item.setAttribute('role', 'tabpanel');
    item.setAttribute('aria-labelledby', tab.id);
    return tab;
  });

  let current = -1;
  const select = (index, { focus = false } = {}) => {
    if (index !== current) {
      const previous = current;
      // FLIP: where every tab is now, before the change.
      const glide = previous >= 0 && animate() && typeof Element.prototype.animate === 'function';
      const before = glide ? tabs.map((tab) => tab.getBoundingClientRect().top) : null;
      current = index;
      tabs.forEach((tab, i) => {
        const on = i === index;
        tab.setAttribute('aria-selected', String(on));
        tab.tabIndex = on ? 0 : -1;
      });
      list.style.setProperty('--tab-index', String(index));
      onSelect(index, previous);
      if (before) {
        tabs.forEach((tab, i) => {
          const shift = before[i] - tab.getBoundingClientRect().top;
          if (Math.abs(shift) < 0.5) return;
          tab.animate([{ transform: `translateY(${shift}px)` }, { transform: 'none' }], { duration: 520, easing: EASE_OUT });
        });
      }
    }
    if (focus) tabs[index].focus();
  };

  list.addEventListener('click', (event) => {
    const tab = event.target.closest('[role="tab"]');
    if (tab) select(tabs.indexOf(tab));
  });
  list.addEventListener('keydown', (event) => {
    const at = tabs.indexOf(document.activeElement);
    if (at < 0) return;
    const last = tabs.length - 1;
    const next = {
      ArrowRight: at === last ? 0 : at + 1,
      ArrowDown: at === last ? 0 : at + 1,
      ArrowLeft: at === 0 ? last : at - 1,
      ArrowUp: at === 0 ? last : at - 1,
      Home: 0,
      End: last,
    }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    select(next, { focus: true });
  });

  list.append(...tabs);
  return {
    list,
    tabs,
    select,
    get current() {
      return current;
    },
  };
}
