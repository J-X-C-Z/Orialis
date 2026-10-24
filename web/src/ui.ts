export function escape(value: unknown): string {
  return String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
}
let noticeTimer: ReturnType<typeof setTimeout>;
export function notify(message: string) {
  clearTimeout(noticeTimer);
  document.querySelector("#notice")!.textContent = message;
  noticeTimer = setTimeout(() => {
    document.querySelector("#notice")!.textContent = "";
  }, 8000);
}
export function dialog(title: string, content: string): HTMLDialogElement {
  const element = document.createElement("dialog");
  element.innerHTML = `<header class="dialog-header"><h2>${escape(title)}</h2><button type="button" class="icon close" aria-label="关闭">×</button></header>${content}`;
  document.body.append(element);
  element
    .querySelector(".close")!
    .addEventListener("click", () => element.close());
  element.addEventListener("close", () => element.remove());
  element.showModal();
  return element;
}
export function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}
export async function submitting(
  form: HTMLFormElement,
  fn: () => Promise<void>,
) {
  const buttons = form.querySelectorAll<HTMLButtonElement>("button");
  buttons.forEach((b) => (b.disabled = true));
  try {
    await fn();
  } catch (error) {
    const field = form.querySelector<HTMLElement>('[role="alert"]');
    if (field) field.textContent = errorText(error);
    else notify(errorText(error));
  } finally {
    buttons.forEach((b) => (b.disabled = false));
  }
}
