const CONFIG = window.PLAY_TOGETHER_CONFIG || {};
const SB_URL = String(CONFIG.SUPABASE_URL || "").replace(/\/+$/, "");
const SB_KEY = String(CONFIG.SUPABASE_ANON_KEY || "");

const sb =
  window.supabase && SB_URL && SB_KEY
    ? window.supabase.createClient(SB_URL, SB_KEY, {
        auth: { persistSession: false },
        realtime: { params: { eventsPerSecond: 10 } }
      })
    : null;
const $ = (selector) => document.querySelector(selector);

const S = {
  channel: null,
  beat: null,
  loop: null,
  busy: false,
  ticking: false,
  room: null,
  playerId: null,
  token: null,
  nickname: "",
  role: null,
  explanation: null,
  chat: [],
  timer: null,
  selectedGame: "game1",
  filters: [],
  questions: null,
  myVote: undefined
};

function esc(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  }[c]));
}

function showError(text) {
  const el = $("#lobbyError");
  if (!el) return;
  el.textContent = text || "";
  el.classList.toggle("hidden", !text);
}

function saveSession() {
  if (!S.room || !S.playerId || !S.token) return;

  localStorage.setItem(
    "pt:" + S.room.code,
    JSON.stringify({
      playerId: S.playerId,
      token: S.token,
      nickname: S.nickname
    })
  );
}

function loadSession(code) {
  try {
    return JSON.parse(localStorage.getItem("pt:" + code) || "null");
  } catch {
    return null;
  }
}

function clearSession() {
  if (S.room) {
    localStorage.removeItem("pt:" + S.room.code);
  }
}

/* =========================
   題庫
========================= */

async function loadQuestions() {
  if (!sb) {
    throw new Error("Supabase 設定未完成，請檢查 config.js。");
  }

  const [g1, g2] = await Promise.all([
    sb.rpc("list_categories", { p_game: "game1" }),
    sb.rpc("list_categories", { p_game: "game2" })
  ]);

  if (g1.error) throw new Error(g1.error.message);
  if (g2.error) throw new Error(g2.error.message);

  S.questions = {
    game1: { categories: g1.data || [] },
    game2: { categories: g2.data || [] }
  };

  renderCategories();
}

function renderCategories() {
  if (!S.questions) return;

  const categories =
    S.selectedGame === "game1"
      ? S.questions.game1.categories
      : S.questions.game2.categories;

  S.filters = S.filters.filter((x) => categories.includes(x));

  if (!S.filters.length) {
    S.filters = [...categories];
  }

  const box = $("#catBox");

  if (!box) return;

  box.innerHTML = categories.map((category) => `
    <button
      type="button"
      class="filter-chip ${S.filters.includes(category) ? "active" : ""}"
      data-category="${esc(category)}"
    >
      ${esc(category)}
    </button>
  `).join("");

  box.querySelectorAll(".filter-chip").forEach((button) => {
    button.addEventListener("click", () => {
      button.classList.toggle("active");

      S.filters = [...box.querySelectorAll(".filter-chip.active")]
        .map((x) => x.dataset.category);
    });
  });
}

loadQuestions().catch((error) => {
  showError(error.message);
});

/* =========================
   首頁操作
========================= */

document.querySelectorAll("[data-scroll]").forEach((button) => {
  button.addEventListener("click", () => {
    const target = document.querySelector(button.dataset.scroll);

    if (target) {
      target.scrollIntoView({
        behavior: "smooth"
      });
    }
  });
});

document.querySelectorAll("[data-tab]").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".tab")
      .forEach((x) => x.classList.remove("active"));

    document.querySelectorAll(".tab-panel")
      .forEach((x) => x.classList.remove("active"));

    tab.classList.add("active");

    const target =
      tab.dataset.tab === "create"
        ? "#createTab"
        : "#joinTab";

    document.querySelector(target)
      ?.classList.add("active");
  });
});

document.querySelectorAll("[data-start]").forEach((button) => {
  button.addEventListener("click", () => {
    S.selectedGame = button.dataset.start;

    const select = $("#gameSelect");

    if (select) {
      select.value = S.selectedGame;
    }

    S.filters = [];

    renderCategories();

    document
      .querySelector('[data-tab="create"]')
      ?.click();

    $("#room")?.scrollIntoView({
      behavior: "smooth"
    });
  });
});

$("#gameSelect")?.addEventListener("change", () => {
  S.selectedGame = $("#gameSelect").value;
  S.filters = [];
  renderCategories();
});

$("#toggleCats")?.addEventListener("click", () => {
  const buttons = [
    ...document.querySelectorAll("#catBox .filter-chip")
  ];

  const allSelected =
    buttons.length > 0 &&
    buttons.every((button) =>
      button.classList.contains("active")
    );

  buttons.forEach((button) => {
    button.classList.toggle("active", !allSelected);
  });

  S.filters = allSelected
    ? []
    : buttons.map((button) => button.dataset.category);
});

/* =========================
   房間
========================= */

$("#createBtn")?.addEventListener("click", createRoom);
$("#joinBtn")?.addEventListener("click", joinRoom);
$("#closeGame")?.addEventListener("click", leaveRoom);
$("#joinCode")?.addEventListener("input", () => {
  const input = $("#joinCode");
  const button = $("#joinBtn");

  if (!input || !button) return;

  const code = input.value.trim().toUpperCase();
  input.value = code;

  const valid = /^[A-Z0-9]{6}$/.test(code);

  button.classList.toggle(
    "btn-yellow",
    valid
  );

  button.classList.toggle(
    "btn-blue",
    !valid
  );
});
async function createRoom() {
  try {
    if (!sb) {
      throw new Error("Supabase 設定未完成，請檢查 config.js。");
    }

    S.nickname = $("#createName")?.value.trim() || "玩家";

    const { data, error } = await sb.rpc("create_room", {
      p_game: S.selectedGame,
      p_filters: S.filters
    });

    if (error) throw new Error(error.message);

    await connectRoom(data, "create");

  } catch (error) {
    showError(error.message);
  }
}

async function joinRoom() {
  try {
    if (!sb) {
      throw new Error("Supabase 設定未完成，請檢查 config.js。");
    }

    const code = $("#joinCode")?.value.trim().toUpperCase();

    if (!/^[A-Z0-9]{6}$/.test(code)) {
      throw new Error("房間號要 6 位英數字。");
    }

    S.nickname = $("#joinName")?.value.trim() || "玩家";

    const saved = loadSession(code);

    await connectRoom(code, saved ? "reconnect" : "join", saved);

  } catch (error) {
    showError(error.message);
  }
}

function teardown() {
  clearInterval(S.timer);
  clearInterval(S.beat);
  clearInterval(S.loop);
  S.timer = S.beat = S.loop = null;

  if (S.channel && sb) {
    sb.removeChannel(S.channel);
  }

  S.channel = null;
}

async function fetchState(advance = true) {
  const { data, error } = await sb.rpc(advance ? "sync" : "get_state", {
    p_code: S.room.code,
    p_token: S.token
  });

  if (error) throw new Error(error.message);

  return data;
}

async function refresh(advance = true) {
  if (!S.room || S.busy) return;

  S.busy = true;

  try {
    const room = await fetchState(advance);
    handleServerMessage({ type: "state", room });
    S.failed = 0;
  } catch (error) {
    S.failed = (S.failed || 0) + 1;

    // 連續失敗三次先出聲，避免一下網絡抖動就彈字
    if (S.failed === 3) {
      flash("同步出錯：" + error.message);
    }
  } finally {
    S.busy = false;
  }
}

async function loadChat() {
  const { data } = await sb
    .from("chat_messages")
    .select("player_id,nickname,text,created_at")
    .eq("room_code", S.room.code)
    .order("created_at", { ascending: true })
    .limit(100);

  S.chat = (data || []).map((row) => ({
    playerId: row.player_id,
    nickname: row.nickname,
    text: row.text,
    at: row.created_at
  }));
}

function subscribe(code) {
  S.channel = sb
    .channel("room:" + code)
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "rooms", filter: "code=eq." + code },
      () => refresh(false)
    )
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "players", filter: "room_code=eq." + code },
      () => refresh(false)
    )
    .on(
      "postgres_changes",
      {
        event: "INSERT",
        schema: "public",
        table: "chat_messages",
        filter: "room_code=eq." + code
      },
      (payload) => {
        S.chat.push({
          playerId: payload.new.player_id,
          nickname: payload.new.nickname,
          text: payload.new.text,
          at: payload.new.created_at
        });

        S.chat = S.chat.slice(-100);
        renderGame();
      }
    )
    .subscribe((status) => {
      const online = status === "SUBSCRIBED";

      setConnectionStatus(
        online ? "CONNECTED" : "CONNECTING",
        online
      );
    });
}

function startLoops() {
  clearInterval(S.beat);
  clearInterval(S.loop);

  // 心跳：保持在線狀態（refresh 本身已經會推進階段）
  S.beat = setInterval(() => {
    if (!S.token) return;

    sb.rpc("touch_player", { p_token: S.token });
    refresh();
  }, 15000);

  // 計時守衛：夠鐘就叫 sync 推進階段
  S.loop = setInterval(() => {
    const endsAt = S.room?.gameState?.endsAt;

    if (!endsAt) return;

    const over = Date.now() >= endsAt;

    // 夠鐘之後每秒試一次，最多試到有人成功推進為止
    if (over) refresh();
  }, 1000);
}

async function connectRoom(code, mode, saved = null) {
  if (!sb) {
    throw new Error("Supabase 設定未完成，請檢查 config.js。");
  }

  teardown();

  S.room = { code };
  S.chat = [];
  S.role = null;
  S.explanation = null;
  S.myVote = undefined;

  $("#roomPanel").innerHTML = "";
  $("#gamePanel").innerHTML = `
    <div class="eyebrow">
      CONNECTING
    </div>

    <p class="notice">
      連緊線……
    </p>
  `;

  setConnectionStatus("CONNECTING", false);
  showGame();

  let joined = null;

  if (saved?.token) {
    const { data, error } = await sb.rpc("touch_player", {
      p_token: saved.token
    });

    if (!error && data) {
      S.playerId = data.playerId;
      S.token = saved.token;
      S.nickname = saved.nickname || S.nickname;
    } else {
      clearSession();
    }
  }

  if (!S.token) {
    const { data, error } = await sb.rpc("join_room", {
      p_code: code,
      p_nickname: S.nickname
    });

    if (error) throw new Error(error.message);

    joined = data;
    S.playerId = data.playerId;
    S.token = data.token;
  }

  await loadChat();

  const room = await fetchState();

  handleServerMessage({
    type: "welcome",
    playerId: S.playerId,
    token: S.token,
    room
  });

  subscribe(code);
  startLoops();

  return joined;
}

/* =========================
   Server messages
========================= */

function handleServerMessage(message) {

  if (message.type === "error") {
    flash(message.message);
    return;
  }

  if (message.type === "welcome") {
    S.playerId = message.playerId;
    S.token = message.token;
    S.room = message.room;

    saveSession();

    setConnectionStatus(
      "CONNECTED",
      true
    );

    renderRoom();
    renderGame();

    return;
  }

  if (message.type === "state") {
  S.room = message.room;

  if (message.room.gameState?.phase === "vote") {
    if (
      message.room.gameState.myVote !== null &&
      message.room.gameState.myVote !== undefined
    ) {
      S.myVote = Number(
        message.room.gameState.myVote
      );
    }
  } else {
    S.myVote = undefined;
  }
    if (message.room.viewerRole) {
      S.role = message.room.viewerRole;
    }

    if (message.room.viewerExplanation) {
      S.explanation =
        message.room.viewerExplanation;
    }

    renderRoom();
    renderGame();

    return;
  }

  if (message.type === "private-role") {
    S.role = message.role;
    S.explanation =
      message.explanation || null;

    renderGame();

    return;
  }

  if (message.type === "chat") {
    S.chat.push(message.chat);

    S.chat = S.chat.slice(-100);

    renderGame();
  }
}

/* =========================
   UI
========================= */

function showGame() {
  $("#landing")?.classList.add("hidden");
  $("#gameShell")?.classList.remove("hidden");

  if (S.room?.code) {
    $("#roomLabel").textContent =
      S.room.code;
  }
}

function leaveRoom() {
  clearInterval(S.timer);

  if (sb && S.token) {
    sb.rpc("leave_room", { p_token: S.token });
  }

  teardown();

  clearSession();

  S.room = null;
  S.playerId = null;
  S.token = null;
  S.role = null;
  S.explanation = null;
  S.chat = [];

  showError("");

  $("#gameShell")?.classList.add("hidden");
  $("#landing")?.classList.remove("hidden");

  window.scrollTo(0, 0);
}

function setConnectionStatus(text, online) {
  const badge = $("#connBadge");

  if (!badge) return;

  badge.textContent = text;
  badge.classList.toggle("online", online);
}

function flash(text) {
  const panel = $("#gamePanel");

  if (!panel) return;

  panel.insertAdjacentHTML(
    "afterbegin",
    `<div class="status error">${esc(text)}</div>`
  );
}

async function send(message) {
  if (!sb || !S.token) return;

  const t = message.type;

  try {
    if (t === "ready") {
      await sb.rpc("set_ready", { p_token: S.token, p_ready: !!message.ready });
    } else if (t === "start") {
      const { error } = await sb.rpc("start_game", { p_token: S.token });
      if (error) throw error;
    } else if (t === "g1:vote") {
      await sb.rpc("g1_vote", { p_token: S.token, p_option: message.option });
    } else if (t === "g1:chat" || t === "g2:chat") {
      await sb.rpc("send_chat", { p_token: S.token, p_text: message.text });
    } else if (t === "g1:next") {
      const isHost = S.room?.hostId === S.playerId;

      const { error } = isHost
        ? await sb.rpc("g1_next", { p_token: S.token })
        : await sb.rpc("g1_ready", { p_token: S.token });

      if (error) throw error;
    } else if (t === "g2:pick") {
      await sb.rpc("g2_pick", { p_token: S.token, p_target: message.targetId });
    } else if (t === "g2:judge") {
      await sb.rpc("g2_judge", { p_token: S.token, p_target: message.targetId });
    } else if (t === "g2:next") {
      const { error } = await sb.rpc("g2_next", { p_token: S.token });
      if (error) throw error;
    }
  } catch (error) {
    flash(error.message || "操作失敗。");
    return;
  }

  refresh();
}

/* =========================
   Room UI
========================= */

function renderRoom() {
  const room = S.room;

  if (!room?.players) return;

  $("#roomPanel").innerHTML = `
    <div
      class="row"
      style="justify-content:space-between;align-items:end"
    >
      <div>
        <div class="eyebrow">
          ROOM CODE
        </div>

        <div class="lobby-code">
          <strong>${esc(room.code)}</strong>
        </div>
      </div>

      <div>
        <div class="eyebrow">
          GAME
        </div>

        <b>
          ${
            room.game === "game1"
              ? "心有靈犀一點通"
              : "9upper瞎掰王"
          }
        </b>
      </div>
    </div>

    <div style="height:14px"></div>

   <div class="players">
  ${
    room.players.map(
      (player) => `
        <div
          class="player ${
            player.host
              ? "host"
              : ""
          }"
          style="
            display:flex;
            justify-content:space-between;
            align-items:center;
            gap:10px;
          "
        >
          <div>
            ${
              player.host
                ? "👑 "
                : ""
            }

            <strong class="player-name">   ${esc(player.nickname)} </strong>

            <span style="opacity:.65">
              ${
                player.connected
                  ? "●"
                  : "○"
              }
            </span>

            ${
              player.score
                ? ` · ${player.score} 分`
                : ""
            }
          </div>
${
  player.host
    ? ""
    : `
      <span
        class="${
          player.ready
            ? "ready-label"
            : "not-ready-label"
        }"
      >
        ${
          player.ready
            ? "✓ Ready"
            : "未準備"
        }
      </span>
    `
}
        </div>
      `
    ).join("")
  }
</div>

 ${ 
  room.hostId === S.playerId &&
  (
    !room.gameState ||
    room.gameState.phase === "waiting"
  )
  ? (() => {
      const connectedPlayers =
  room.players.filter(
    (p) => p.connected
  );

const connectedCount =
  connectedPlayers.length;

const allReady =
  connectedCount >= 2 &&
  connectedPlayers
    .filter(
      (p) => !p.host
    )
    .every(
      (p) => p.ready
    );

const canStart =
  room.hostId === S.playerId &&
  allReady;

      return `
        <div style="margin-top:15px;display:flex;gap:10px;flex-wrap:wrap">
          <button
            id="startBtn"
            class="btn ${canStart ? "btn-green" : "btn-disabled"}"
            ${canStart ? "" : "disabled"}
          >
            START GAME
          </button>

          <button
            id="leaveBtn"
            class="btn btn-outline"
          >
            LEAVE ROOM
          </button>
        </div>
      `;
    })()
  : `
      <div style="margin-top:15px;display:flex;gap:10px;flex-wrap:wrap">
        <button
          id="readyBtn"
          class="btn ${
            room.players.find(p => p.id === S.playerId)?.ready
              ? "btn-green"
              : "btn-ready"
          }"
        >
          ${
            room.players.find(p => p.id === S.playerId)?.ready
              ? "✓ Ready"
              : "Ready？"
          }
        </button>

        <button
          id="leaveBtn"
          class="btn btn-outline"
        >
          LEAVE ROOM
        </button>
      </div>
    `
}

    <p class="notice">
      ${
        room.players
          .filter((p) => p.connected)
          .length
      }/6 人在線。
      夠人就可以開始。
    </p>
  `;

const currentPlayer =
  room.players.find(
    p => p.id === S.playerId
  );

$("#readyBtn")?.addEventListener(
  "click",
  () => {
    send({
      type: "ready",
      ready: !currentPlayer?.ready
    });
  }
);
  
const startBtn = $("#startBtn");

startBtn?.addEventListener("click", async () => {
  if (startBtn.disabled) return;

  const ok = await askConfirm(
    "肯定開始遊戲？"
  );

  if (ok) {
    send({ type: "start" });
  }
});

$("#leaveBtn")?.addEventListener(
  "click",
  leaveRoom
);
}

/* =========================
   Game state
========================= */

function renderGame() {
  const game =
    S.room?.gameState;

  if (!game) {
    $("#gamePanel").innerHTML = `
      <div class="eyebrow">
        READY
      </div>

      <h2 class="title">
        WAIT FOR<br>
        <span>YOUR FRIENDS.</span>
      </h2>

      <p class="notice">
        夠人數之後，房主就可以開始。
      </p>
    `;

    return;
  }

  if (S.room.game === "game1") {
    renderGame1(game);
  } else {
    renderGame2(game);
  }
}

function startTimer(element, endsAt) {
  clearInterval(S.timer);

  if (!element || !endsAt) return;

  const update = () => {
    const remaining =
      Math.max(0, endsAt - Date.now());

    element.textContent =
      (remaining / 1000)
        .toFixed(1) + "s";
  };

  update();

  S.timer = setInterval(
    update,
    100
  );
}

/* =========================
   Game 1
========================= */

function renderGame1(game) {

if (game.phase === "intro") {
  $("#gamePanel").innerHTML = `
    <div class="game-intro">
      <div class="eyebrow">
        ROUND ${game.round}
      </div>

      <h2>
        遊戲準備開始！
      </h2>

      <p>
        準備揀你嘅答案
      </p>
    </div>
  `;

  clearInterval(S.timer);

  return;
}

  if (game.phase === "vote") {

    const votes =
      game.votes || {};

    const myVote =
  S.myVote !== undefined
    ? S.myVote
    : (
        game.myVote !== null &&
        game.myVote !== undefined
          ? Number(game.myVote)
          : undefined
      );

    $("#gamePanel").innerHTML = `
      <div
        class="row"
        style="justify-content:space-between;align-items:end"
      >
        <div>
          <div class="eyebrow">
            ROUND ${game.round}
          </div>

          <h2 class="title">
            心有靈犀<br>
            <span>一點通</span>
          </h2>
        </div>

        <div
          id="time"
          class="timer"
        ></div>
      </div>

      <div class="question">
        ${esc(
          game.question.question
        )}
      </div>

      <div class="answers">
        ${
          game.question.options
            .map(
              (option, index) => `
                <button
  class="answer ${
    myVote === index
      ? "selected"
      : ""
  }"
  style="
    background:${
      myVote === index
        ? "var(--yellow)"
        : "#fff"
    };
    border-color:${
      myVote === index
        ? "var(--yellow-deep)"
        : "#e7e9ee"
    };
  "
  ${
    myVote !== undefined
      ? "disabled"
      : ""
  }
  onclick="vote1(${index})"
>
                  ${
                    String.fromCharCode(
                      65 + index
                    )
                  }
                  ·
                  ${esc(option)}
                </button>
              `
            )
            .join("")
        }
      </div>

      <p class="notice">
        10 秒投票。
        ${
          myVote !== undefined
            ? "你已經投咗。"
            : "每人一票。"
        }
      </p>
    `;

    startTimer(
      $("#time"),
      game.endsAt
    );

    return;
  }

  const counts =
    game.votes || [0, 0];

  $("#gamePanel").innerHTML = `
    <div>
      <div class="eyebrow">
        RESULT · ROUND ${game.round}
      </div>

      <h2 class="title">
        WHAT DID<br>
        <span>EVERYONE CHOOSE?</span>
      </h2>
    </div>

    <div class="question">
      ${esc(
        game.question.question
      )}
    </div>

    <div class="bars">
  ${[0, 1]
    .map((index) => {
      const count = counts[index] || 0;
      const maxCount = Math.max(
        counts[0] || 0,
        counts[1] || 0,
        1
      );

      const width =
        count === 0
          ? 0
          : Math.max(
              10,
              (count / maxCount) * 100
            );

      const voters =
        game.voters?.[index] || [];

      const isMajority =
        game.winner === index;

      return `
        <div class="vote-result-row">
          <div class="vote-result-head">
            <strong>
              選擇 ${String.fromCharCode(65 + index)}
            </strong>

            <strong>
              ${count} 票
            </strong>
          </div>

          <div class="vote-result-bar">
            <div
              class="vote-result-fill ${
                isMajority ? "majority" : ""
              }"
              style="width:${width}%"
            ></div>
          </div>

          <div class="vote-result-names">
            ${
              voters.length
                ? voters
                    .map(
                      (name) =>
                        `<span>${esc(name)}</span>`
                    )
                    .join("、")
                : "冇人揀呢個"
            }
          </div>
        </div>
      `;
    })
    .join("")}
</div>

    <div
      class="${
        game.winner === null
          ? "status"
          : "result"
      }"
    >
      ${
        game.winner === null
          ? "今題打和。"
          : "多數揀咗：" +
            String.fromCharCode(
              65 + game.winner
            ) +
            " · " +
            esc(
              game.question.options[
                game.winner
              ]
            )
      }
    </div>

    <div style="height:16px"></div>

    <div class="eyebrow">
      TALK IT OUT
    </div>

    <div
      id="chatBox"
      class="chat"
    >
      ${renderChatHtml()}
    </div>

    <div
      class="row"
      style="margin-top:10px"
    >
      <input
        id="chat1"
        placeholder="講下你點諗…"
      >

    <button
  id="chat1Send"
  class="btn btn-send"
  disabled
  onclick="chat1()"
>
  SEND
</button>

 ${
  S.room.hostId === S.playerId
    ? `
      <button
        class="btn btn-yellow"
        onclick="next1()"
      >
        NEXT QUESTION
      </button>
    `
    : `
      <button
        class="btn btn-outline"
        onclick="next1()"
      >
        準備好
      </button>
    `
}
    </div>

    <p class="notice">
      準備好下一題：
      ${game.nextReadyCount || 0}/
      ${
        S.room.players
          .filter((p) => p.connected)
          .length
      }
    </p>
  `;
  const chatInput = $("#chat1");
  const chatSend = $("#chat1Send");

  if (chatInput && chatSend) {
    const updateSendButton = () => {
      const hasText =
        chatInput.value.trim().length > 0;

      chatSend.disabled = !hasText;

      chatSend.classList.toggle(
        "ready",
        hasText
      );
    };

    chatInput.addEventListener(
      "input",
      updateSendButton
    );

    updateSendButton();
  }

  scrollChat();
}

window.vote1 = async (index) => {
  const ok = await askConfirm(
    "肯定投呢個？"
  );

  if (!ok) return;

  S.myVote = index;
  renderGame();

  send({
    type: "g1:vote",
    option: index
  });
};

window.chat1 = () => {
  const input = $("#chat1");
  const button = $("#chat1Send");

  if (!input) return;

  const text =
    input.value.trim();

  if (!text) return;

  send({
    type: "g1:chat",
    text
  });

  input.value = "";

  if (button) {
    button.disabled = true;
    button.classList.remove("ready");
  }
};

window.next1 = () => {
  send({
    type: "g1:next"
  });
};

/* =========================
   Game 2
========================= */

function roleBlock() {
  if (!S.role) return "";

  const label =
    S.role === "judge"
      ? "諗樣（公開）"
      : S.role === "truth"
        ? "老實人"
        : "9upper";

  return `
    <div
      class="role ${S.role}"
    >
      <div class="eyebrow">
        YOUR ROLE
      </div>

      <strong
        style="font:700 30px 'Fredoka'"
      >
        ${label}
      </strong>

      ${
        S.explanation
          ? `
            <p>
              <b>正確解釋：</b>
              ${esc(S.explanation)}
            </p>
          `
          : ""
      }
    </div>
  `;
}

function renderGame2(game) {

  let html = `
    <div
      class="row"
      style="justify-content:space-between;align-items:end"
    >
      <div>
        <div class="eyebrow">
          9UPPER BLUFF GAME
        </div>

        <h2 class="title">
          瞎掰王<br>
          <span>
            ${esc(game.term || "")}
          </span>
        </h2>
      </div>

      ${
        game.endsAt
          ? `
            <div
              id="time"
              class="timer"
            ></div>
          `
          : ""
      }
    </div>

    ${roleBlock()}
  `;

  if (game.phase === "prep") {
    html += `
      <div class="status">
        睇題目 30 秒。
        只有老實人收到正確解釋。
      </div>
    `;
  }

  if (game.phase === "picking") {
    const isJudge = game.judgeId === S.playerId;
    const left = (game.candidates || []).length;

    html += `
      <div
        class="eyebrow"
        style="margin-top:18px"
      >
        WHO SPEAKS NEXT
      </div>

      ${
        isJudge
          ? `
            <div class="status">
              10 秒內揀下一位發言。
              唔揀就隨機。
            </div>

            <div class="choice-grid">
              ${
                (game.candidates || [])
                  .map(
                    (player) => `
                      <button
                        class="choice"
                        onclick="pick2('${player.id}')"
                      >
                        ${esc(player.nickname)}
                      </button>
                    `
                  )
                  .join("")
              }
            </div>
          `
          : `
            <div class="status">
              諗樣揀緊下一位發言（仲有 ${left} 位未講）。
            </div>
          `
      }
    `;
  }
    if (game.phase === "speaking") {
    const active =
      S.room.players.find(
        (player) =>
          player.id ===
          game.currentPlayerId
      );

    const mine =
      game.currentPlayerId ===
      S.playerId;

    html += `
      <div class="status">
        而家發言：
        <b>
          ${esc(
            active?.nickname || ""
          )}
        </b>

        ${
          mine
            ? " · 輪到你喇，30 秒。"
            : ""
        }

        <span class="muted">
          （${(game.spokenIds || []).length}/${(game.order || []).length} 已發言）
        </span>
      </div>

      <div
        id="chatBox"
        class="chat"
      >
        ${renderChatHtml()}
      </div>

      <div
        class="row"
        style="margin-top:10px"
      >
        <input
          id="chat2"
          ${
            mine
              ? ""
              : "disabled"
          }
          placeholder="${
            mine
              ? "打你嘅解釋…"
              : "等緊發言…"
          }"
        >

        <button
          id="chat2Send"
          class="btn btn-send"
          disabled
          onclick="chat2()"
        >
          SEND
        </button>
      </div>
    `;

    const chatInput = $("#chat2");
    const chatSend = $("#chat2Send");

    if (chatInput && chatSend) {
      const updateSendButton = () => {
        const hasText =
          chatInput.value.trim().length > 0;

        chatSend.disabled =
          !mine || !hasText;

        chatSend.classList.toggle(
          "ready",
          mine && hasText
        );
      };

      chatInput.addEventListener(
        "input",
        updateSendButton
      );

      updateSendButton();
    }

    scrollChat();
  }

  if (game.phase === "judge") {

    const isJudge =
      game.judgeId ===
      S.playerId;

    html += `
      <div
        class="eyebrow"
        style="margin-top:18px"
      >
        WHO IS THE 老實人
      </div>

      ${
        isJudge
          ? `
            <div class="status">
              2 分鐘內揀出你認為嘅老實人。
              唔揀就隨機。
            </div>

            <div class="choice-grid">
              ${
                (game.choices || [])
                  .map(
                    (player) => `
                      <button
                        class="choice"
                        onclick="judge2('${player.id}')"
                      >
                        ${esc(
                          player.nickname
                        )}
                      </button>
                    `
                  )
                  .join("")
              }
            </div>
          `
          : `
            <div class="status">
              諗樣有 2 分鐘揀出老實人。
            </div>
          `
      }
    `;
  }

  if (game.phase === "result") {

    html += `
      <div class="result">
        ${
          game.correct
            ? "✅ 諗樣估中咗！"
            : "❌ 諗樣估錯咗！"
        }
      </div>

      <p class="notice">
        真正嘅老實人：
        <b>
          ${esc(
            game.truthNickname
          )}
        </b>
        <br>

        正確解釋：
        ${esc(
          game.correctExplanation
        )}
      </p>

      ${
        S.room.hostId ===
        S.playerId
          ? `
            <button
              class="btn yellow"
              style="margin-top:15px"
              onclick="next2()"
            >
              NEXT ROUND
            </button>
          `
          : ""
      }
    `;
  }

  $("#gamePanel").innerHTML = html;

  if (game.endsAt) {
    startTimer(
      $("#time"),
      game.endsAt
    );
  }
}

window.chat2 = () => {
  const input = $("#chat2");
  const button = $("#chat2Send");

  if (!input) return;

  const text =
    input.value.trim();

  if (!text) return;

  send({
    type: "g2:chat",
    text
  });

  input.value = "";

  if (button) {
    button.disabled = true;
    button.classList.remove("ready");
  }
};

window.pick2 = (targetId) => {
  send({
    type: "g2:pick",
    targetId
  });
};

window.judge2 = (targetId) => {
  send({
    type: "g2:judge",
    targetId
  });
};

window.next2 = () => {
  send({
    type: "g2:next"
  });
};

function renderChatHtml() {
  return S.chat.map(
    (message) => `
      <div class="msg">
        <b>
          ${esc(message.nickname)}
        </b>
        ：
        ${esc(message.text)}
      </div>
    `
  ).join("");
}

function scrollChat() {
  const box = $("#chatBox");

  if (box) {
    box.scrollTop =
      box.scrollHeight;
  }
}


function askConfirm(message) {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");

    overlay.className = "confirm-overlay";

    overlay.innerHTML = `
      <div class="confirm-card">
        <div class="eyebrow">
          CONFIRM
        </div>

        <h3>
          ${esc(message)}
        </h3>

        <div class="confirm-actions">
          <button
            class="btn btn-green"
            data-confirm="yes"
          >
            是
          </button>

          <button
            class="btn btn-outline"
            data-confirm="no"
          >
            取消
          </button>
        </div>
      </div>
    `;

    document.body.appendChild(overlay);

    const finish = (value) => {
      overlay.remove();
      resolve(value);
    };

    overlay
      .querySelector('[data-confirm="yes"]')
      .addEventListener(
        "click",
        () => finish(true)
      );

    overlay
      .querySelector('[data-confirm="no"]')
      .addEventListener(
        "click",
        () => finish(false)
      );
  });
}
