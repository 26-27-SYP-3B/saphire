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
  let text = await response.text();
  // A 204 has no body. Saying so is better than an empty block that looks like the
  // page lost the answer.
  if (response.status === 204 && text === "") text = "(no body: a 204 has none)";
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

$("list-songs").addEventListener("click", () => {
  send("GET", "/api/music", { curl: `-X GET ${location.origin}/api/music${authFlag()}` });
});

// The streaming endpoint is only worth testing when the pieces arrive one by one, so
// this logs what came in and when instead of the bytes themselves.
async function streamSong(id) {
  // The id is encoded so the path in the log is the path that was sent.
  const path = "/api/music/" + encodeURIComponent(id);
  const started = performance.now();

  let response;
  try {
    response = await fetch(path, { headers: state.token ? { Authorization: "Bearer " + state.token } : {} });
  } catch (error) {
    addEntry({ status: 0, method: "GET", path, ms: Math.round(performance.now() - started), text: "the server is not reachable at " + location.origin });
    return;
  }

  const headers = response.headers;
  if (response.status !== 200) {
    addEntry({
      status: response.status,
      method: "GET",
      path,
      ms: Math.round(performance.now() - started),
      text: await response.text(),
      retryAfter: headers.get("Retry-After"),
      curl: `-X GET ${location.origin}${path}${authFlag()}`,
    });
    return;
  }

  const maxChunkLines = 20; // a 500 MiB song is about 16000 chunks; the entry must not hold them all
  const lines = [];
  let total = 0;
  let chunks = 0;

  const reader = response.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks += 1;
    total += value.length;
    if (chunks <= maxChunkLines) lines.push(`${value.length} bytes at ${Math.round(performance.now() - started)} ms`);
  }

  const declared = Number(headers.get("Content-Length") || 0);
  const summary = [`${chunks} chunk(s), ${total} bytes of ${declared}`, ...lines];
  if (chunks > maxChunkLines) summary.push(`… ${chunks - maxChunkLines} more chunks`);
  if (chunks === 1 && total === declared) summary.push("the whole file arrived in one read, so nothing was streamed");

  addEntry({
    status: response.status,
    method: "GET",
    path,
    ms: Math.round(performance.now() - started),
    text: summary.join("\n"),
    curl: `-X GET ${location.origin}${path}${authFlag()}`,
  });
}

$("stream-song").addEventListener("click", () => {
  const id = $("stream-id").value.trim();
  if (!id) {
    addEntry({ status: null, method: "GET", path: "/api/music/{id}", ms: 0, text: "no song id was typed, so nothing was sent" });
    return;
  }
  streamSong(id);
});

// The playlist and queue cards send what is typed. A value that is shaped like an
// integer becomes a JSON number, because that is what the endpoints expect; anything
// else stays a string so the page can show what the server says about it.
function valueOrNumber(input) {
  const text = input.value;
  return /^-?[0-9]+$/.test(text) ? Number(text) : text;
}

// A path segment as typed, so the path in the log is the path that was sent.
function segment(value) {
  return encodeURIComponent(value);
}

// A request with a JSON body and the stored token, written the way api-docs.md
// describes it.
function authJSON(method, path, payload) {
  const body = payload === undefined ? undefined : JSON.stringify(payload);
  const curl = `-X ${method} ${location.origin}${path}${authFlag()}${body === undefined ? "" : ` -d ${shellQuote(body)}`}`;
  return send(method, path, { headers: { "Content-Type": "application/json" }, body, curl });
}

// Nothing was typed, so nothing was sent. The page says which field is empty instead of
// sending an empty path.
function nothingTyped(field, path) {
  addEntry({ status: null, method: "GET", path, ms: 0, text: `no ${field} was typed, so nothing was sent` });
}

const playlistPath = () => "/api/playlists/" + segment($("playlist-id").value);

$("playlist-form").addEventListener("submit", (event) => {
  event.preventDefault();
  authJSON("POST", "/api/playlists", { name: $("playlist-name").value });
});

$("list-playlists").addEventListener("click", () => {
  send("GET", "/api/playlists", { curl: `-X GET ${location.origin}/api/playlists${authFlag()}` });
});

$("show-playlist").addEventListener("click", () => {
  if (!$("playlist-id").value) return nothingTyped("playlist id", "/api/playlists/{id}");
  const path = playlistPath();
  send("GET", path, { curl: `-X GET ${location.origin}${path}${authFlag()}` });
});

$("add-to-playlist").addEventListener("click", () => {
  if (!$("playlist-id").value) return nothingTyped("playlist id", "/api/playlists/{id}/songs");
  const path = playlistPath() + "/songs";
  authJSON("POST", path, { track_id: valueOrNumber($("add-track-id")) });
});

$("remove-from-playlist").addEventListener("click", () => {
  if (!$("playlist-id").value) return nothingTyped("playlist id", "/api/playlists/{id}/songs/{position}");
  if (!$("remove-position").value) return nothingTyped("position", "/api/playlists/" + segment($("playlist-id").value) + "/songs/{position}");

  const path = playlistPath() + "/songs/" + segment($("remove-position").value);
  send("DELETE", path, { curl: `-X DELETE ${location.origin}${path}${authFlag()}` });
});

$("delete-playlist").addEventListener("click", () => {
  if (!$("playlist-id").value) return nothingTyped("playlist id", "/api/playlists/{id}");
  const path = playlistPath();
  send("DELETE", path, { curl: `-X DELETE ${location.origin}${path}${authFlag()}` });
});

// The queue is what a player reads, so this card shows it as the server keeps it: fill
// from a source, read it, add one song, remove one, clear it.
$("fill-queue").addEventListener("click", () => {
  const source = $("queue-source").value;
  if (!source) return nothingTyped("source", "/api/queue");

  const payload = { source };
  // source_id is only part of the body for a source that names something; sending it
  // for the whole library is refused by the server, so the page does not send it there.
  if (source !== "library" && $("queue-source-id").value) {
    payload.source_id = valueOrNumber($("queue-source-id"));
  }

  authJSON("POST", "/api/queue", payload);
});

$("read-queue").addEventListener("click", () => {
  send("GET", "/api/queue", { curl: `-X GET ${location.origin}/api/queue${authFlag()}` });
});

$("append-queue").addEventListener("click", () => {
  authJSON("POST", "/api/queue/songs", { track_id: valueOrNumber($("queue-append-id")) });
});

$("remove-queue").addEventListener("click", () => {
  if (!$("queue-position").value) return nothingTyped("position", "/api/queue/{position}");
  const path = "/api/queue/" + segment($("queue-position").value);
  send("DELETE", path, { curl: `-X DELETE ${location.origin}${path}${authFlag()}` });
});

$("clear-queue").addEventListener("click", () => {
  send("DELETE", "/api/queue", { curl: `-X DELETE ${location.origin}/api/queue${authFlag()}` });
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
