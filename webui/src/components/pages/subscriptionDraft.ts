import { ref } from "vue";

export const pendingSubscriptionDraft = ref<string | null>(null);

export function setPendingSubscriptionDraft(value: string): void {
  pendingSubscriptionDraft.value = value;
}

export function takePendingSubscriptionDraft(): string | null {
  const value = pendingSubscriptionDraft.value;
  pendingSubscriptionDraft.value = null;
  return value;
}
