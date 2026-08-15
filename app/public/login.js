(function () {
  "use strict";

  var form = document.getElementById("login-form");
  var modeToggle = document.getElementById("mode-toggle");
  var modeInput = form && form.querySelector('input[name="mode"]');
  var passwordGroup = document.getElementById("password-group");
  var passwordInput = document.getElementById("password");
  var recoveryGroup = document.getElementById("recovery-group");
  var recoveryInput = document.getElementById("recovery-code");
  var newPasswordInput = document.getElementById("new-password");
  var newPasswordConfirmInput = document.getElementById("new-password-confirm");
  var submit = document.getElementById("login-submit");
  var submitLabel = submit && submit.querySelector(".submit-label");
  var statusNode = document.getElementById("login-status");
  var errorNode = document.getElementById("login-error");
  if (!form || !modeToggle || !modeInput || !passwordGroup || !passwordInput || !recoveryGroup || !recoveryInput || !newPasswordInput || !newPasswordConfirmInput || !submit) return;

  var mode = "password";

  function setMessage(status, error) {
    if (statusNode) statusNode.textContent = status || "";
    if (errorNode) {
      errorNode.textContent = error || "";
      errorNode.hidden = !error;
    }
  }

  function setMode(nextMode) {
    mode = nextMode === "recovery" ? "recovery" : "password";
    var recovery = mode === "recovery";
    modeInput.value = recovery ? "recovery_code" : "password";
    passwordGroup.hidden = recovery;
    passwordInput.disabled = recovery;
    passwordInput.required = !recovery;
    recoveryGroup.hidden = !recovery;
    recoveryInput.disabled = !recovery;
    recoveryInput.required = recovery;
    newPasswordInput.disabled = !recovery;
    newPasswordInput.required = recovery;
    newPasswordConfirmInput.disabled = !recovery;
    newPasswordConfirmInput.required = recovery;
    modeToggle.textContent = recovery ? "使用密码登录" : "使用恢复码恢复访问";
    modeToggle.setAttribute("aria-expanded", recovery ? "true" : "false");
    if (submitLabel) submitLabel.textContent = recovery ? "更新密码" : "进入观察台";
    var kicker = document.getElementById("form-mode-label");
    if (kicker) kicker.textContent = recovery ? "RECOVERY CODE" : "PASSWORD ACCESS";
    setMessage("", "");
    (recovery ? recoveryInput : passwordInput).focus();
  }

  function safeRedirect(value) {
    if (typeof value !== "string" || value.indexOf("\\") >= 0 || !/^\/(?!\/)/.test(value)) return "/app";
    return value;
  }

  function responseMessage(payload, fallback) {
    if (!payload || typeof payload !== "object") return fallback;
    if (typeof payload.error === "string" && payload.error.trim()) return payload.error;
    if (typeof payload.message === "string" && payload.message.trim()) return payload.message;
    return fallback;
  }

  function retryLabel(seconds) {
    var value = Number(seconds);
    if (!Number.isFinite(value) || value <= 0) return "登录尝试过多，请稍后再试。";
    return "登录尝试过多，请约 " + Math.ceil(value) + " 秒后再试。";
  }

  async function submitLogin(event) {
    event.preventDefault();
    setMessage("正在确认访问…", "");
    submit.disabled = true;
    submit.setAttribute("aria-busy", "true");
    if (submitLabel) submitLabel.textContent = "确认中…";

    var account = document.getElementById("account");
    var accountValue = account ? account.value.trim() : "";
    var credential = mode === "recovery" ? recoveryInput.value.trim() : passwordInput.value;
    if (!accountValue || !credential) {
      setMessage("", "请填写账号和当前登录凭据。");
      submit.disabled = false;
      submit.removeAttribute("aria-busy");
      if (submitLabel) submitLabel.textContent = mode === "recovery" ? "更新密码" : "进入观察台";
      (accountValue ? (mode === "recovery" ? recoveryInput : passwordInput) : account).focus();
      return;
    }

    var payload;
    var endpoint;
    if (mode === "recovery") {
      if (newPasswordInput.value.length < 12) {
        setMessage("", "新密码至少需要 12 个字符。");
        submit.disabled = false;
        submit.removeAttribute("aria-busy");
        if (submitLabel) submitLabel.textContent = "更新密码";
        newPasswordInput.focus();
        return;
      }
      if (newPasswordInput.value !== newPasswordConfirmInput.value) {
        setMessage("", "两次输入的新密码不一致。");
        submit.disabled = false;
        submit.removeAttribute("aria-busy");
        if (submitLabel) submitLabel.textContent = "更新密码";
        newPasswordConfirmInput.focus();
        return;
      }
      payload = { username: accountValue, recovery_code: credential, new_password: newPasswordInput.value };
      endpoint = "/api/auth/recovery";
    } else {
      payload = { username: accountValue, password: credential };
      endpoint = form.dataset.endpoint || form.getAttribute("action") || "/api/auth/login";
    }

    try {
      var response = await fetch(endpoint, {
        method: "POST",
        credentials: "same-origin",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify(payload)
      });
      var result = null;
      try { result = await response.json(); } catch (_error) { result = null; }

      if (response.ok && (!result || result.ok !== false)) {
        if (mode === "recovery") {
          setMode("password");
          setMessage("恢复完成，请使用新密码登录。", "");
          return;
        }
        var target = result && (result.redirect || result.next);
        if (response.redirected && response.url) target = response.url;
        window.location.assign(safeRedirect(target));
        return;
      }

      var retryAfterHeader = response.headers && response.headers.get("Retry-After");
      if (response.status === 429 || retryAfterHeader) {
        var retryAfter = result && (result.retry_after || result.retryAfter);
        retryAfter = retryAfter || retryAfterHeader;
        setMessage("", retryLabel(retryAfter));
      } else if (response.status === 401 || response.status === 403) {
        setMessage("", mode === "recovery" ? "账号或恢复码不正确。" : "账号或登录凭据不正确。");
      } else if (response.status === 422 || response.status === 400) {
        setMessage("", responseMessage(result, "请检查输入后重试。"));
      } else {
        setMessage("", "登录服务暂不可用，请稍后再试。");
      }
    } catch (_error) {
      setMessage("", "无法连接登录服务，请检查网络后再试。");
    } finally {
      submit.disabled = false;
      submit.removeAttribute("aria-busy");
      if (submitLabel) submitLabel.textContent = mode === "recovery" ? "更新密码" : "进入观察台";
    }
  }

  modeToggle.addEventListener("click", function () {
    setMode(mode === "password" ? "recovery" : "password");
  });
  form.addEventListener("submit", submitLogin);
  ["input", "change"].forEach(function (eventName) {
    form.addEventListener(eventName, function () {
      if (errorNode && !errorNode.hidden) setMessage("", "");
    });
  });
})();
