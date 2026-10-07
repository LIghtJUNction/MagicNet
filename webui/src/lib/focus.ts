import { nextTick } from "vue";

const FOCUSABLE_SELECTOR =
  'button:not([disabled]), a[href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, [contenteditable="true"], [tabindex]:not([tabindex="-1"])';

export function trapFocusWithin(
  event: KeyboardEvent,
  root: HTMLElement | null,
): void {
  if (event.key !== "Tab" || !root) return;
  const candidates = Array.from(
    root.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
  ).filter((element) => {
    if (element.matches(":disabled, [hidden], input[type=hidden]") || element.closest("[inert]")) return false;
    if (element.tabIndex < 0 && !(element.isContentEditable && !element.hasAttribute("tabindex"))) return false;
    if (!element.getClientRects().length || getComputedStyle(element).visibility !== "visible") return false;
    return true;
  });
  // Only the selected radio (or first visible option) is in the native Tab sequence.
  const focusable = candidates.filter((element) => {
    if (element instanceof HTMLInputElement && element.type === "radio" && element.name) {
      const group = candidates.filter((radio): radio is HTMLInputElement =>
        radio instanceof HTMLInputElement && radio.type === "radio" &&
        radio.name === element.name && radio.form === element.form);
      return element === (group.find((radio) => radio.checked) ?? group[0]);
    }
    return true;
  });
  if (!focusable.length) {
    event.preventDefault();
    root.focus();
    return;
  }

  const first = focusable.at(0);
  const last = focusable.at(-1);
  if (!first || !last) return;
  const active = document.activeElement;
  const outsideSequence = !root.contains(active) || !focusable.includes(active as HTMLElement);
  if (event.shiftKey && (active === first || outsideSequence)) {
    event.preventDefault();
    last.focus();
  } else if (!event.shiftKey && (active === last || outsideSequence)) {
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
