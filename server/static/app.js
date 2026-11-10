// Saphire dev console. Plain JavaScript, no framework.
//
// The page is served by main.go, so every request goes to the page's own origin
// and nothing needs a base URL. Fields are sent exactly as typed: the server is
// the trust boundary, and the purpose of this page is to see what it answers.

const state = {
  // The token is kept for this tab only, so a fresh tab starts without a session.
  token: sessionStorage.getItem("saphire.token") || "",
  expiresAt: Number(sessionStorage.getItem("saphire.expires_at") || 0),
  user: null,
};

// A cap so a long testing session cannot grow the page without limit.
const maxLogEntries = 100;

const $ = (id) => document.getElementById(id);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  node.textContent = text;
  return node;
}

// Status colours follow the status ranges in api-docs.md, so a rate limit and a
// server error do not look the same on the page. A null status is something the
// page itself refused to send; 0 is a request that got no answer at all.
function statusClass(status) {
  if (status === null) return "local";
  if (status === 0) return "unreachable";
  if (status < 300) return "ok";
  if (status === 429) return "rate-limited";
  if (status < 500) return "client-error";
  return "server-error";
}

function statusLabel(status) {
  if (status === null) return "not sent";
  if (status === 0) return "no answer";
  return String(status);
}

function parseJSON(text) {
  try {
    return JSON.parse(text);
  } catch (error) {
    return null; // an answer that is not JSON stays an answer, not a crash
  }
}

function prettyBody(text) {
  const value = parseJSON(text);
  return value === null ? text : JSON.stringify(value, null, 2);
}

function addEntry({ status, method, path, ms, text, curl, retryAfter }) {
  const entry = el("li", "entry " + statusClass(status));

  const head = el("p", "entry-head");
  head.append(
    el("span", "status", statusLabel(status)),
    el("span", "method", method),
    el("span", "path", path),
    el("span", "ms", ms + " ms")
  );
  entry.append(head);

  if (retryAfter) entry.append(el("p", "retry", "Retry-After: " + retryAfter + " s"));

  entry.append(el("pre", "body", prettyBody(text)));

  // The same request written as curl, because api-docs.md is checked with curl.
  if (curl) entry.append(el("p", "curl", "curl " + curl));

  // Newest first: the request you just made is the one you are looking at.
  // Text is set through textContent, so a title the server echoed back cannot
  // become markup here.
  const log = $("log");
  log.prepend(entry);
  while (log.children.length > maxLogEntries) log.lastChild.remove();
}

// One request, logged as the server answered it. Returns null when the server
// could not be reached at all — that is the only failure with no status code.
async function send(method, path, { body, curl, headers = {}, useToken = true }) {
  const requestHeaders = { ...headers };
  if (useToken && state.token) requestHeaders.Authorization = "Bearer " + state.token;

  const started = performance.now();
  let response;
  try {
    response = await fetch(path, { method, headers: requestHeaders, body });
  } catch (error) {
    addEntry({
      status: 0,
      method,
      path,
      ms: Math.round(performance.now() - started),
      text: "the server is not reachable at " + location.origin,
      curl,
    });
    return null;
  }

  const ms = Math.round(performance.now() - started);
  const text = await response.text();
  const retryAfter = response.headers.get("Retry-After");
  addEntry({ status: response.status, method, path, ms, text, curl, retryAfter });
  return { status: response.status, text, retryAfter };
}

function showSession(kind, message) {
  $("session-state").className = "session-state " + kind;
  $("session-text").textContent = message;
}

function renderTokenLine() {
  const line = $("token-line");
  if (!state.token) {
    line.textContent = "no token stored";
    $("token-expiry").textContent = "";
    return;
  }

  line.textContent = state.token;

  if (!state.expiresAt) {
    $("token-expiry").textContent = "no expiry known — the server only shows one in the login response";
    return;
  }

  const left = state.expiresAt - Math.floor(Date.now() / 1000);
  const when = new Date(state.expiresAt * 1000).toLocaleString();
  $("token-expiry").textContent = left > 0
    ? "stored until " + when + " (" + Math.round(left / 60) + " min left)"
    : "past the stored expiry at " + when + " — the next request shows what the server answers";
}

// A value quoted for the shell, so a username with a quote in it prints as the
// same request that was sent.
function shellQuote(value) {
  return "'" + value.replace(/'/g, `'\\''`) + "'";
}

// Only the header that was actually sent: an Authorization line that is not part of
// the request would change which 401 the server answers.
function authFlag() {
  return state.token ? ` -H "Authorization: Bearer ${state.token}"` : "";
}

function jsonPost(endpoint, payload) {
  return send("POST", endpoint, {
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    // Register and login are anonymous calls; a stored token would only make the
    // request look different from the one api-docs.md describes.
    useToken: false,
    curl: `-X POST ${location.origin}${endpoint} -d ${shellQuote(JSON.stringify(payload))}`,
  });
}

$("register-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  await jsonPost("/api/register", {
    username: $("register-username").value,
    password: $("register-password").value,
  });
});

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const payload = { username: $("login-username").value, password: $("login-password").value };

  const result = await jsonPost("/api/login", payload);
  if (!result || result.status !== 200) return;

  const data = parseJSON(result.text);
  if (!data) return;

  state.token = data.token;
  state.expiresAt = data.expires_at;
  sessionStorage.setItem("saphire.token", state.token);
  sessionStorage.setItem("saphire.expires_at", String(state.expiresAt));
  state.user = null;
  renderTokenLine();
  showSession("pending", "token stored · session not checked yet");
});

async function checkSession() {
  if (!state.token) {
    showSession("none", "no session");
    return;
  }

  const result = await send("GET", "/api/session", {
    curl: `-X GET ${location.origin}/api/session${authFlag()}`,
  });
  if (!result) return;

  if (result.status === 200) {
    const user = parseJSON(result.text);
    if (!user) {
      showSession("bad", "answered 200 with a body that is not JSON");
      return;
    }
    state.user = user;
    showSession("ok", "signed in as " + user.username);
    return;
  }

  state.user = null;
  if (result.status === 429) {
    showSession("bad", "rate limited, next token in " + result.retryAfter + " s");
  } else {
    showSession("bad", "the stored token was refused (" + result.status + ")");
  }
}

$("check-session").addEventListener("click", checkSession);

$("clear-session").addEventListener("click", () => {
  state.token = "";
  state.expiresAt = 0;
  state.user = null;
  sessionStorage.removeItem("saphire.token");
  sessionStorage.removeItem("saphire.expires_at");
  renderTokenLine();
  showSession("none", "no session");
});

$("upload-form").addEventListener("submit", async (event) => {
  event.preventDefault();

  const file = $("upload-file").files[0];
  if (!file) {
    addEntry({ status: null, method: "POST", path: "/api/music/upload", ms: 0, text: "no file was chosen, so nothing was sent" });
    return;
  }

  const form = new FormData();
  form.append("file", file); // the field name the endpoint requires

  const result = await send("POST", "/api/music/upload", {
    body: form,
    curl: `-X POST ${location.origin}/api/music/upload${authFlag()} -F ${shellQuote("file=@" + file.name)}`,
  });

  if (!result || result.status !== 201) return;

  const track = parseJSON(result.text);
  if (track) showSession("ok", "uploaded " + track.title + " as " + track.stored_name);
});

$("list-library").addEventListener("click", () => {
  send("GET", "/api/music", { curl: `-X GET ${location.origin}/api/music${authFlag()}` });
});

$("get-track").addEventListener("click", () => {
  const id = $("track-id").value.trim();
  if (!id) {
    addEntry({ status: null, method: "GET", path: "/api/music/{id}", ms: 0, text: "no id was typed, so nothing was sent" });
    return;
  }

  // The answer is the file itself, so the body here is its bytes as text: enough to
  // see the status, the content type and the length, not a playable audio stream.
  send("GET", "/api/music/" + id, { curl: `-X GET ${location.origin}/api/music/${id}${authFlag()}` });
});

$("clear-log").addEventListener("click", () => {
  $("log").textContent = "";
});

// A stored token is checked on load, so the page starts by showing whether it is
// still valid — that is the 401 path from api-docs.md, and one request in the log.
if (state.token) {
  renderTokenLine();
  showSession("pending", "token stored · checking");
  checkSession();
} else {
  renderTokenLine();
  showSession("none", "no session");
}
