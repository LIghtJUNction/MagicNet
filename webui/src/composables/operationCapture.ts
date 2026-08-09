export type OperationCapture = {
  sequence: number;
  phase: "idle" | "accepted" | "queued" | "running" | "done" | "error";
  command: string;
  output: string;
};

type OperationCaptureUpdate = Partial<Pick<OperationCapture, "phase" | "output">>;

export function emptyOperationCapture(output = ""): OperationCapture {
  return {
    sequence: 0,
    phase: "idle",
    command: "",
    output,
  };
}

export function beginOperationCapture(
  state: OperationCapture,
  command: string,
  output: string,
): number {
  const sequence = state.sequence + 1;
  state.sequence = sequence;
  state.phase = "accepted";
  state.command = command;
  state.output = output;
  return sequence;
}

export function updateOperationCapture(
  state: OperationCapture,
  sequence: number,
  update: OperationCaptureUpdate,
): boolean {
  if (sequence !== state.sequence) return false;
  if (update.phase) state.phase = update.phase;
  if (update.output !== undefined) state.output = update.output;
  return true;
}

export function invalidateOperationCapture(state: OperationCapture): number {
  state.sequence += 1;
  state.phase = "idle";
  state.command = "";
  state.output = "";
  return state.sequence;
}
