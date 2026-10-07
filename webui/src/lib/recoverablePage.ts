import { defineAsyncComponent, defineComponent, h, shallowRef, type Component } from "vue";
import PageLoadState from "@/components/ui/PageLoadState.vue";

type PageLoader = () => Promise<{ default: Component }>;

/** Retry only the failed page. Never reload the WebView or discard other drafts. */
export function createRecoverablePage(loader: PageLoader): Component {
  return defineComponent({
    inheritAttrs: false,
    setup(_props, { attrs, slots }) {
      function createAttempt(): Component {
        return defineAsyncComponent({
          loader: () => loader().then((module) => module.default),
          // Suspense otherwise ignores the component's timeout and error state.
          suspensible: false,
          delay: 120,
          timeout: 20000,
          loadingComponent: PageLoadState,
          errorComponent: defineComponent({
            inheritAttrs: false,
            setup: () => () => h(PageLoadState, {
              failed: true,
              onRetry: () => { current.value = createAttempt(); },
            }),
          }),
        });
      }
      const current = shallowRef(createAttempt());
      return () => h(current.value, attrs, slots);
    },
  });
}

/** A speculative load must not create an unhandled rejection or execute a command. */
export async function prefetchPage(loader: PageLoader): Promise<void> {
  try { await loader(); } catch { /* The visible page provides explicit recovery. */ }
}
