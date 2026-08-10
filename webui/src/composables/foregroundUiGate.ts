/**
 * Gives the latest foreground command exclusive ownership of shared status
 * fields. Device commands remain serialized separately, but callers can still
 * enqueue different actions through different UI locks; an older completion
 * must not clear or overwrite the newer action's progress.
 */
export class ForegroundUiGate {
  private currentToken = 0;

  public begin(): number {
    this.currentToken += 1;
    return this.currentToken;
  }

  public current(): number {
    return this.currentToken;
  }

  public owns(token: number): boolean {
    return token === this.currentToken;
  }
}
