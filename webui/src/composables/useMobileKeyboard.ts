import { nextTick, onBeforeUnmount, onMounted, ref } from "vue";

export function isMobileKeyboardOpen(
  baselineHeight: number,
  currentHeight: number,
  isEditing: boolean,
  scale = 1,
): boolean {
  // Browser toolbars and pinch zoom must not hide navigation.
  return isEditing && scale <= 1.05 && baselineHeight - currentHeight > 120;
}

function isTextEntry(element: Element | null): element is HTMLElement {
  if (element instanceof HTMLTextAreaElement) return true;
  if (element instanceof HTMLInputElement) {
    return [
      "text",
      "search",
      "url",
      "tel",
      "email",
      "password",
      "number",
    ].includes(element.type);
  }
  return element instanceof HTMLElement && element.isContentEditable;
}

export function useMobileKeyboard() {
  const keyboardOpen = ref(false);
  let baselineHeight = 0;
  let baselineWidth = 0;
  let frame = 0;

  function measure(): void {
    frame = 0;
    const viewport = window.visualViewport;
    const height = viewport?.height ?? window.innerHeight;
    const width = window.innerWidth;
    const active = document.activeElement;
    const editing = isTextEntry(active);

    // A rotation establishes a new viewport, not a keyboard-sized occlusion.
    if (Math.abs(width - baselineWidth) > 80) {
      baselineHeight = height;
      baselineWidth = width;
    }
    if (!editing) baselineHeight = Math.max(baselineHeight, height);
    const opened = isMobileKeyboardOpen(
      baselineHeight,
      height,
      editing,
      viewport?.scale ?? 1,
    );
    const justOpened = opened && !keyboardOpen.value;
    keyboardOpen.value = opened;
    if (justOpened && editing) {
      void nextTick(() => {
        if (active.isConnected)
          active.scrollIntoView({ block: "nearest", behavior: "auto" });
      });
    }
  }

  function schedule(): void {
    if (!frame) frame = window.requestAnimationFrame(measure);
  }

  onMounted(() => {
    baselineHeight = window.visualViewport?.height ?? window.innerHeight;
    baselineWidth = window.innerWidth;
    window.addEventListener("resize", schedule, { passive: true });
    window.visualViewport?.addEventListener("resize", schedule, {
      passive: true,
    });
    document.addEventListener("focusin", schedule);
    document.addEventListener("focusout", schedule);
  });

  onBeforeUnmount(() => {
    window.cancelAnimationFrame(frame);
    window.removeEventListener("resize", schedule);
    window.visualViewport?.removeEventListener("resize", schedule);
    document.removeEventListener("focusin", schedule);
    document.removeEventListener("focusout", schedule);
  });

  return { keyboardOpen };
}
