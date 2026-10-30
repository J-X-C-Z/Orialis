"use strict";
(() => {
  const form = document.getElementById("mcp-consent");
  if (!form) return;
  const pending = form.elements.pending.value;
  const key = "orialis.mcp.pending";
  const error = document.getElementById("login-error");
  const sso = document.getElementById("oidc-login");
  const current = document.getElementById("current-login");
  const showError = (message) => { error.textContent = message; };
  const clearReturn = () => {
    document.cookie = "orialis_mcp_return=; Max-Age=0; Path=/; SameSite=Lax" +
      (location.protocol === "https:" ? "; Secure" : "");
  };
  const submit = async (token) => {
    if (typeof token !== "string" || !/^[\x21-\x7e]+$/.test(token)) {
      throw new Error("invalid session");
    }
    sso.disabled = current.disabled = true;
    const body = new URLSearchParams({pending, session_token: token, consent: "allow"});
    const response = await fetch(form.action, {method: "POST", credentials: "same-origin",
      headers: {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"}, body});
    if (!response.ok) throw new Error("consent failed");
    const result = await response.json();
    const callback = new URL(result.redirect);
    if (callback.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(callback.hostname)) {
      throw new Error("invalid callback");
    }
    sessionStorage.removeItem(key);
    window.location.assign(callback.href);
  };
  sso.addEventListener("click", async () => {
    sso.disabled = current.disabled = true;
    showError("");
    try {
      if (!/^[A-Za-z0-9_-]{43}$/.test(pending)) throw new Error("invalid pending");
      sessionStorage.setItem(key, pending);
      document.cookie = "orialis_mcp_return=" + pending + "; Max-Age=600; Path=/; SameSite=Lax" +
        (location.protocol === "https:" ? "; Secure" : "");
      const response = await fetch("/api/v1/auth/oidc/start", {
        method: "POST", credentials: "same-origin", headers: {"Content-Type": "application/json"},
        body: JSON.stringify({bind: false}),
      });
      if (!response.ok) throw new Error("OIDC unavailable");
      const data = await response.json();
      if (typeof data.url !== "string") throw new Error("invalid redirect");
      const url = new URL(data.url);
      if (url.protocol !== "https:" || url.username || url.password) throw new Error("invalid redirect");
      window.location.assign(url.href);
    } catch {
      clearReturn();
      sessionStorage.removeItem(key);
      showError("统一账号登录暂不可用或未启用，请稍后重试。");
      sso.disabled = current.disabled = false;
    }
  });
  current.addEventListener("click", async () => {
    try {
      await submit(sessionStorage.getItem("orialis.session"));
    } catch {
      showError("未找到当前已登录账号，请使用统一账号登录。");
      sso.disabled = current.disabled = false;
    }
  });
  const complete = async () => {
    try {
      if (location.hash !== "#oidc-complete") {
        if (location.hash.startsWith("#oidc-")) {
          sessionStorage.removeItem(key);
          showError("统一账号登录已取消或失败，请点击按钮重试。");
        }
        return;
      }
      if (sessionStorage.getItem(key) !== pending) {
        showError("登录请求与当前页面不匹配，请重新点击统一账号登录。");
        return;
      }
      sso.disabled = current.disabled = true;
      const response = await fetch("/api/v1/auth/oidc/exchange", {
        method: "POST", credentials: "same-origin",
      });
      if (!response.ok) throw new Error("exchange failed");
      const session = await response.json();
      if (typeof session.userId !== "string" || !session.userId ||
          typeof session.expiresAt !== "string" || !(Date.parse(session.expiresAt) > Date.now())) {
        throw new Error("invalid session");
      }
      await submit(session.accessToken);
    } catch {
      sessionStorage.removeItem(key);
      showError("登录结果已失效或无法完成授权，请点击统一账号登录重试。");
      sso.disabled = current.disabled = false;
    }
  };
  void complete();
})();
