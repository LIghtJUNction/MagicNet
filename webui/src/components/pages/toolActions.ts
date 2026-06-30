export type PendingToolAction = {
  key: string;
  title: string;
  detail: string;
  command: string;
  run: () => Promise<void>;
};
