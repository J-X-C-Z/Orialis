import { list, request } from "./api";
import { dialog, errorText, escape, notify, submitting } from "./ui";

interface Conversation {
  id: string;
  title: string;
  isDefault: boolean;
  version: number;
}

interface Message {
  id: string;
  conversationId: string;
  role: string;
  content: string;
  createdAt: string;
}

interface Draft {
  content: string;
  sending: boolean;
  error: string;
  attempt?: { id: string; content: string };
}

interface ReplyWait {
  messageId: string;
  createdAt?: string;
}

function messageMarkup(message: Message): string {
  const mine = message.role === "user";
  return `<article class="list-row message ${mine ? "message-user" : "message-agent"}"><div><strong>${mine ? "我" : escape(message.role === "assistant" ? "助手" : message.role)}</strong><p>${escape(message.content)}</p><time class="muted">${escape(new Date(message.createdAt).toLocaleString())}</time></div></article>`;
}

export async function renderChat(root: HTMLElement): Promise<void> {
  root.innerHTML = `<div class="toolbar"><p class="muted">消息发送到当前账号选择的 Hermes 设备；平时每 5 秒查看，等待回复期间每秒检查。会话超过 7 天未活动会自动删除。</p><div class="actions"><button class="secondary" type="button" data-refresh>刷新会话</button><button class="secondary" type="button" data-toggle-selection>批量删除</button><button class="primary" type="button" data-new-conversation>新建会话</button></div></div><div class="actions chat-selection-actions" data-selection-actions hidden><button class="secondary" type="button" data-select-all>全选</button><button class="danger" type="button" data-delete-selected disabled>删除所选（0）</button><button class="secondary" type="button" data-cancel-selection>取消</button></div><p class="error" role="alert" data-conversation-error></p><div class="chat-layout"><aside class="conversation-list" data-conversations><p class="muted">正在加载会话…</p></aside><section class="chat-thread"><div class="toolbar"><h2 data-chat-title>选择会话</h2><button class="secondary" type="button" data-refresh-messages disabled>刷新消息</button></div><p class="error" role="alert" data-message-error></p><div class="message-list" data-messages><p class="empty">请选择一个会话。</p></div><form class="chat-composer" data-message-form><label class="field wide">输入消息<textarea name="content" rows="3" required></textarea></label><div class="actions"><button class="primary" type="submit" disabled>发送</button></div><p class="error" role="alert" aria-live="polite"></p></form></section></div>`;
  const layout = root.querySelector<HTMLElement>(".chat-layout")!;
  const refreshButton = root.querySelector<HTMLButtonElement>("[data-refresh]")!;
  const conversationsNode = root.querySelector<HTMLElement>("[data-conversations]")!;
  const messagesNode = root.querySelector<HTMLElement>("[data-messages]")!;
  const titleNode = root.querySelector<HTMLElement>("[data-chat-title]")!;
  const conversationError = root.querySelector<HTMLElement>("[data-conversation-error]")!;
  const messageError = root.querySelector<HTMLElement>("[data-message-error]")!;
  const refreshMessagesButton = root.querySelector<HTMLButtonElement>("[data-refresh-messages]")!;
  const form = root.querySelector<HTMLFormElement>("[data-message-form]")!;
  const textarea = form.querySelector<HTMLTextAreaElement>('textarea[name="content"]')!;
  const sendButton = form.querySelector<HTMLButtonElement>('button[type="submit"]')!;
  const formError = form.querySelector<HTMLElement>('[role="alert"]')!;
  const toggleSelectionButton = root.querySelector<HTMLButtonElement>("[data-toggle-selection]")!;
  const selectionActions = root.querySelector<HTMLElement>("[data-selection-actions]")!;
  const selectAllButton = root.querySelector<HTMLButtonElement>("[data-select-all]")!;
  const deleteSelectedButton = root.querySelector<HTMLButtonElement>("[data-delete-selected]")!;
  const cancelSelectionButton = root.querySelector<HTMLButtonElement>("[data-cancel-selection]")!;
  const listeners = new AbortController();
  const drafts = new Map<string, Draft>();
  const repliesPending = new Map<string, ReplyWait>();
  const reads = new Map<number, Promise<void>>();
  let selected: Conversation | null = null;
  let conversations: Conversation[] = [];
  let selectionRevision = 0;
  let conversationRevision = 0;
  let loadingConversations = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let disposed = false;
  let openModal: HTMLDialogElement | null = null;
  let selectionMode = false;
  const selectedForDeletion = new Set<string>();

  const active = () => !disposed && root.isConnected && root.contains(layout);
  const current = (id: string, revision: number) =>
    active() && selected?.id === id && selectionRevision === revision;
  const draftFor = (id: string): Draft => {
    let draft = drafts.get(id);
    if (!draft) {
      draft = { content: "", sending: false, error: "" };
      drafts.set(id, draft);
    }
    return draft;
  };
  const drawComposer = () => {
    const draft = selected ? draftFor(selected.id) : null;
    textarea.value = draft?.content ?? "";
    textarea.disabled = !draft;
    sendButton.disabled = !draft || draft.sending;
    sendButton.textContent = draft?.sending ? "发送中…" : "发送";
    formError.textContent = draft?.error ?? "";
  };
  const saveDraft = () => {
    if (selected) draftFor(selected.id).content = textarea.value;
  };
  const dispose = () => {
    disposed = true;
    clearTimeout(timer);
    listeners.abort();
    observer.disconnect();
    openModal?.close();
  };
  const observer = new MutationObserver(() => {
    if (!active()) dispose();
  });
  observer.observe(document.body, { childList: true, subtree: true });

  const schedulePoll = () => {
    clearTimeout(timer);
    if (!active()) {
      dispose();
      return;
    }
    if (document.hidden) return;
    timer = setTimeout(() => {
      if (!active()) {
        dispose();
        return;
      }
      if (document.hidden) return;
      void (selected ? loadMessages() : loadConversations());
    }, selected && repliesPending.has(selected.id) ? 1000 : 5000);
  };

  const loadMessages = async (
    conversationId = selected?.id,
    revision = selectionRevision,
  ): Promise<void> => {
    if (!conversationId || !current(conversationId, revision) || document.hidden) return;
    const pending = reads.get(revision);
    if (pending) return pending;
    refreshMessagesButton.disabled = true;
    const reading = (async () => {
      try {
        const messages = await list<Message>(
          `/conversations/${encodeURIComponent(conversationId)}/messages`,
        );
        if (!current(conversationId, revision)) return;
        const replyWait = repliesPending.get(conversationId);
        if (replyWait) {
          const sentIndex = messages.findIndex((message) => message.id === replyWait.messageId);
          const hasReply = sentIndex >= 0
            ? messages.slice(sentIndex + 1).some((message) => message.role === "assistant")
            : Boolean(replyWait.createdAt && messages.some((message) =>
              message.role === "assistant" && Date.parse(message.createdAt) > Date.parse(replyWait.createdAt!),
            ));
          if (hasReply) repliesPending.delete(conversationId);
        }
        const nearBottom = messagesNode.scrollHeight - messagesNode.scrollTop - messagesNode.clientHeight < 80;
        const scrollTop = messagesNode.scrollTop;
        const markup = messages.length
          ? messages.map(messageMarkup).join("")
          : '<p class="empty">还没有消息，发出第一条吧。</p>';
        if (messagesNode.innerHTML !== markup) {
          messagesNode.innerHTML = markup;
          messagesNode.scrollTop = nearBottom ? messagesNode.scrollHeight : scrollTop;
        }
        messageError.textContent = "";
      } catch (error) {
        if (current(conversationId, revision))
          messageError.textContent = `${errorText(error)} 将自动重试，也可点击“刷新消息”。`;
      } finally {
        reads.delete(revision);
        if (current(conversationId, revision)) refreshMessagesButton.disabled = false;
        schedulePoll();
      }
    })();
    reads.set(revision, reading);
    return reading;
  };

  const renderConversationList = () => {
    conversationsNode.innerHTML = conversations.length
      ? conversations.map((conversation) => selectionMode
        ? `<label class="conversation-item conversation-select-item"><input type="checkbox" data-select-conversation="${escape(conversation.id)}" ${selectedForDeletion.has(conversation.id) ? "checked" : ""} ${conversation.isDefault ? "disabled" : ""}><span>${escape(conversation.title)}</span>${conversation.isDefault ? '<span class="pill">默认</span>' : ""}</label>`
        : `<button class="conversation-item ${selected?.id === conversation.id ? "selected" : ""}" type="button" data-conversation="${escape(conversation.id)}" aria-pressed="${selected?.id === conversation.id}">${escape(conversation.title)}${conversation.isDefault ? '<span class="pill">默认</span>' : ""}</button>`,
      ).join("")
      : '<p class="empty">还没有会话。</p>';
    selectionActions.hidden = !selectionMode;
    toggleSelectionButton.hidden = selectionMode;
    deleteSelectedButton.disabled = selectedForDeletion.size === 0;
    deleteSelectedButton.textContent = `删除所选（${selectedForDeletion.size}）`;
  };
  const selectConversation = (next: Conversation | null) => {
    saveDraft();
    const changed = selected?.id !== next?.id;
    selected = next;
    if (changed) {
      selectionRevision++;
      messagesNode.innerHTML = next
        ? '<p class="muted">正在读取消息…</p>'
        : '<p class="empty">请选择一个会话。</p>';
      messagesNode.scrollTop = 0;
      messageError.textContent = "";
    }
    titleNode.textContent = next?.title ?? "选择会话";
    refreshMessagesButton.disabled = !next || reads.has(selectionRevision);
    drawComposer();
    renderConversationList();
  };

  const loadConversations = async (): Promise<void> => {
    if (!active() || document.hidden || loadingConversations) return;
    loadingConversations = true;
    refreshButton.disabled = true;
    const revision = conversationRevision;
    try {
      const items = await request<Conversation[]>("/conversations");
      if (!active() || revision !== conversationRevision) return;
      conversations = items;
      const next = items.find((item) => item.id === selected?.id) ?? items[0] ?? null;
      selectConversation(next);
      conversationError.textContent = "";
      await loadMessages();
    } catch (error) {
      if (active()) {
        conversationError.textContent = `${errorText(error)} 可点击“刷新会话”重试。`;
        if (!conversations.length) conversationsNode.innerHTML = '<p class="empty">暂时无法读取会话。</p>';
      }
    } finally {
      loadingConversations = false;
      if (active()) refreshButton.disabled = false;
      schedulePoll();
    }
  };

  refreshButton.addEventListener("click", () => void loadConversations(), { signal: listeners.signal });
  refreshMessagesButton.addEventListener("click", () => void loadMessages(), { signal: listeners.signal });
  conversationsNode.addEventListener("click", (event) => {
    const button = (event.target as Element).closest<HTMLElement>("[data-conversation]");
    const next = conversations.find((item) => item.id === button?.dataset.conversation);
    if (!active() || !next || selected?.id === next.id) return;
    selectConversation(next);
    void loadMessages();
  }, { signal: listeners.signal });
  conversationsNode.addEventListener("change", (event) => {
    const checkbox = (event.target as Element).closest<HTMLInputElement>("[data-select-conversation]");
    const id = checkbox?.dataset.selectConversation;
    if (!active() || !id) return;
    if (checkbox.checked) selectedForDeletion.add(id);
    else selectedForDeletion.delete(id);
    renderConversationList();
  }, { signal: listeners.signal });
  toggleSelectionButton.addEventListener("click", () => {
    if (!active()) return;
    selectionMode = true;
    selectedForDeletion.clear();
    renderConversationList();
  }, { signal: listeners.signal });
  cancelSelectionButton.addEventListener("click", () => {
    selectionMode = false;
    selectedForDeletion.clear();
    renderConversationList();
  }, { signal: listeners.signal });
  selectAllButton.addEventListener("click", () => {
    for (const item of conversations) if (!item.isDefault) selectedForDeletion.add(item.id);
    renderConversationList();
  }, { signal: listeners.signal });
  deleteSelectedButton.addEventListener("click", () => {
    if (!active() || selectedForDeletion.size === 0) return;
    const targets = conversations.filter((item) => selectedForDeletion.has(item.id) && !item.isDefault);
    if (!targets.length || !window.confirm(`确定删除所选 ${targets.length} 个会话？`)) return;
    deleteSelectedButton.disabled = true;
    void (async () => {
      const results = await Promise.allSettled(targets.map((item) =>
        request<void>(`/conversations/${encodeURIComponent(item.id)}`, "DELETE", { baseVersion: item.version }),
      ));
      if (!active()) return;
      const deleted = new Set<string>();
      let failed = 0;
      results.forEach((result, index) => {
        if (result.status === "fulfilled") deleted.add(targets[index]!.id);
        else failed++;
      });
      conversations = conversations.filter((item) => !deleted.has(item.id));
      for (const id of deleted) selectedForDeletion.delete(id);
      if (selected && deleted.has(selected.id)) {
        drafts.delete(selected.id);
        selectConversation(conversations[0] ?? null);
      }
      if (failed === 0) {
        selectionMode = false;
        selectedForDeletion.clear();
        conversationError.textContent = "";
        notify(`${deleted.size} 个会话已删除。`);
      } else {
        conversationError.textContent = `${deleted.size} 个已删除，${failed} 个失败；失败项已保留，可重试。`;
      }
      renderConversationList();
      if (selected) await loadMessages();
    })();
  }, { signal: listeners.signal });
  textarea.addEventListener("input", saveDraft, { signal: listeners.signal });
  document.addEventListener("visibilitychange", () => {
    if (!active()) {
      dispose();
      return;
    }
    clearTimeout(timer);
    if (!document.hidden) void (selected ? loadMessages() : loadConversations());
  }, { signal: listeners.signal });

  root.querySelector("[data-new-conversation]")!.addEventListener("click", () => {
    if (!active()) return;
    const clientId = crypto.randomUUID();
    const modal = dialog("新建会话", `<form class="form-grid" data-conversation-form><p class="error" role="alert" aria-live="polite"></p><label class="field">会话名称<input name="title" required></label><div class="actions wide"><button class="primary" type="submit">创建</button><button class="secondary" type="button" data-cancel>取消</button></div></form>`);
    openModal = modal;
    modal.querySelector("[data-cancel]")!.addEventListener("click", () => modal.close());
    modal.addEventListener("close", () => { if (openModal === modal) openModal = null; });
    const createForm = modal.querySelector<HTMLFormElement>("[data-conversation-form]")!;
    let creating = false;
    createForm.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!active() || creating) return;
      creating = true;
      void submitting(createForm, async () => {
        try {
          const title = String(new FormData(createForm).get("title") ?? "").trim();
          if (!title) throw new Error("请填写会话名称。");
          const created = await request<Conversation>("/conversations", "POST", { id: clientId, title });
          if (!active()) return;
          modal.close();
          conversationRevision++;
          conversations.push(created);
          selectConversation(created);
          await loadMessages();
          if (active()) notify("会话已创建。");
        } finally {
          creating = false;
        }
      });
    });
  }, { signal: listeners.signal });

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    if (!active() || !selected) return;
    const conversationId = selected.id;
    const draft = draftFor(conversationId);
    if (draft.sending) return;
    saveDraft();
    const content = draft.content.trim();
    if (!content) {
      draft.error = "请输入消息内容。";
      drawComposer();
      return;
    }
    if (draft.attempt?.content !== content)
      draft.attempt = { id: crypto.randomUUID(), content };
    const attempt = draft.attempt;
    draft.sending = true;
    draft.error = "";
    drawComposer();
    void (async () => {
      try {
        const sent = await request<Message>(`/conversations/${encodeURIComponent(conversationId)}/messages`, "POST", attempt);
        if (draft.content.trim() === content) draft.content = "";
        draft.attempt = undefined;
        draft.sending = false;
        repliesPending.set(conversationId, { messageId: sent?.id ?? attempt.id, createdAt: sent?.createdAt });
        if (active() && selected?.id === conversationId) {
          drawComposer();
          notify("消息已发送，正在自动等待助手回复。");
          void loadMessages(conversationId, selectionRevision);
        }
      } catch (error) {
        draft.error = errorText(error);
      } finally {
        draft.sending = false;
        if (active() && selected?.id === conversationId) drawComposer();
      }
    })();
  }, { signal: listeners.signal });

  drawComposer();
  await loadConversations();
}
