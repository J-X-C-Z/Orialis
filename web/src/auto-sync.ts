/** Foreground fallback for clients without an authenticated WebSocket. */
export class AutoSync {
  private timer: ReturnType<typeof setTimeout> | undefined;
  private stopped = false;
  private busy = false;
  private listeners = new AbortController();

  constructor(
    private refreshPage: () => Promise<void>,
    private canRefresh: () => boolean,
  ) {}

  start() {
    document.addEventListener("visibilitychange", this.wake, { signal: this.listeners.signal });
    window.addEventListener("online", this.wake, { signal: this.listeners.signal });
    document.addEventListener("focusout", this.defer, { signal: this.listeners.signal });
    document.addEventListener("close", this.defer, { capture: true, signal: this.listeners.signal });
    this.schedule();
  }

  private wake = () => { void this.refresh(); };
  private defer = () => {
    // Let focus move and dialogs close before checking whether editing ended.
    if (!this.stopped) this.schedule(250);
  };
  private schedule(delay = 30_000) {
    clearTimeout(this.timer);
    if (!this.stopped) this.timer = setTimeout(this.wake, delay);
  }

  async refresh() {
    if (this.stopped || this.busy) return;
    if (!this.canRefresh()) { this.schedule(); return; }
    this.busy = true;
    try {
      await this.refreshPage();
    } catch {
      // Existing page errors remain visible; network failures retry automatically.
    } finally {
      this.busy = false;
      this.schedule();
    }
  }

  dispose() {
    this.stopped = true;
    clearTimeout(this.timer);
    this.listeners.abort();
  }
}
