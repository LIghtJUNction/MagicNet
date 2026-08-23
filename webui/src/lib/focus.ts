import { nextTick } from "vue";

const FOCUSABLE_SELECTOR =
  'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function trapFocusWithin(
  event: KeyboardEvent,
  root: HTMLElement | null,
): void {
  if (event.key !== "Tab" || !root) return;
  const focusable = Array.from(
    root.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
  ).filter((element) => element.getClientRects().length > 0);
  if (!focusable.length) {
    event.preventDefault();
    root.focus();
    return;
  }

  const first = focusable.at(0);
  const last = focusable.at(-1);
  if (!first || !last) return;
  const active = document.activeElement;
  if (event.shiftKey && (active === first || !root.contains(active))) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || !root.contains(active))) {
    event.preventDefault();
    first.focus();
  }
}

export function restoreFocusAfterUpdate(target: EventTarget | null): void {
  const element = target instanceof HTMLElement ? target : null;
  if (!element) return;
  void nextTick(() => {
    if (element.isConnected) element.focus();
  });
}
