import { onBeforeUnmount, onMounted, ref } from "vue";

/** Keep a sheet inside the visible area when the Android keyboard pans/resizes it. */
export function useDialogViewport() {
  const viewportStyle = ref<{ height: string; top: string }>();
  let frame = 0;
  let viewport: VisualViewport | null = null;
  function measure(): void {
    frame = 0;
    viewportStyle.value = viewport
      ? { height: `${viewport.height}px`, top: `${viewport.offsetTop}px` }
      : undefined;
  }
  function schedule(): void {
    if (!frame) frame = window.requestAnimationFrame(measure);
  }
  onMounted(() => {
    viewport = window.visualViewport;
    measure();
    window.addEventListener("resize", schedule, { passive: true });
    viewport?.addEventListener("resize", schedule, { passive: true });
    viewport?.addEventListener("scroll", schedule, { passive: true });
  });
  onBeforeUnmount(() => {
    window.cancelAnimationFrame(frame);
    window.removeEventListener("resize", schedule);
    viewport?.removeEventListener("resize", schedule);
    viewport?.removeEventListener("scroll", schedule);
  });
  return { viewportStyle };
}
