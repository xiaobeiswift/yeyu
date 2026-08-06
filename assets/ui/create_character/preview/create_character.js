/* 山径散碑立档 · 无通栏方板 / 无横轨方块 */

(function () {
  "use strict";

  var ROSTER = [
    {
      id: "hero_mist",
      glyph: "雾",
      catalogName: "雾中客",
      role: "无名剑客",
      tag: "均衡 · 剑",
      intro: "钟下无碑。步履轻，刃意沉。只问雾开时能否见路。",
      stats: { 力: 12, 骨: 12, 身: 12, 息: 12 },
      chapter: "卷一 · 开局",
      weapon: true,
    },
    {
      id: "hero_blade",
      glyph: "刃",
      catalogName: "霜刃行",
      role: "快刀客",
      tag: "爆发 · 刀",
      intro: "刀出如霜，收势不回头。认准一处，连进三招。",
      stats: { 力: 15, 骨: 10, 身: 14, 息: 9 },
      chapter: "卷一 · 开局",
      weapon: true,
    },
    {
      id: "hero_herb",
      glyph: "药",
      catalogName: "青囊影",
      role: "行医隐侠",
      tag: "稳健 · 杂学",
      intro: "青囊系肘。言少算深，先保命，再论胜负。",
      stats: { 力: 9, 骨: 15, 身: 10, 息: 14 },
      chapter: "卷一 · 开局",
      weapon: false,
    },
    {
      id: "hero_wind",
      glyph: "风",
      catalogName: "踏云生",
      role: "轻功客",
      tag: "机变 · 轻功",
      intro: "檐角一点，雾面三折。不恋缠斗，专找夹缝活路。",
      stats: { 力: 10, 骨: 10, 身: 16, 息: 12 },
      chapter: "卷一 · 开局",
      weapon: false,
    },
    {
      id: "hero_bow",
      glyph: "弦",
      catalogName: "暮弦",
      role: "冷弓手",
      tag: "远程 · 弓",
      intro: "十步外才是她的道理。话少，箭更少。",
      stats: { 力: 11, 骨: 10, 身: 14, 息: 13 },
      chapter: "卷一 · 开局",
      weapon: true,
    },
    {
      id: "hero_monk",
      glyph: "禅",
      catalogName: "半偈",
      role: "还俗僧",
      tag: "防御 · 拳",
      intro: "袈裟已卸，戒疤还在。今日只问能否走过这截径。",
      stats: { 力: 13, 骨: 16, 身: 8, 息: 11 },
      chapter: "卷一 · 开局",
      weapon: false,
    },
    {
      id: "hero_fox",
      glyph: "狐",
      catalogName: "细雪",
      role: "机变客",
      tag: "控制 · 暗器",
      intro: "笑里有针。不硬拼刀锋，专搅局、专拆招。",
      stats: { 力: 8, 骨: 11, 身: 15, 息: 14 },
      chapter: "卷一 · 开局",
      weapon: false,
    },
    {
      id: "hero_spear",
      glyph: "枪",
      catalogName: "长庚",
      role: "枪冢余生",
      tag: "穿透 · 枪",
      intro: "一杆旧枪。人未至，枪尖已先问路。",
      stats: { 力: 14, 骨: 11, 身: 13, 息: 10 },
      chapter: "卷一 · 开局",
      weapon: true,
    },
  ];

  var STAT_MAX = 18;
  var INDEX_LABEL = ["位一", "位二", "位三", "位四", "位五"];
  var SLOT_SHAPE = ["a", "b", "c", "d", "e"];

  var state = {
    screen: "slots",
    selectedSlot: 1,
    createTargetSlot: 1,
    selectedHeroId: null,
    slots: [{ empty: true }, { empty: true }, { empty: true }, { empty: true }, { empty: true }],
  };

  var el = {
    stage: document.getElementById("stage"),
    screenSlots: document.getElementById("screen-slots"),
    screenCreate: document.getElementById("screen-create"),
    slotsRow: document.getElementById("slots-row"),
    slotsHint: document.getElementById("slots-hint"),
    slotsTip: document.getElementById("slots-tip"),
    btnCreate: document.getElementById("btn-slots-create"),
    btnEnter: document.getElementById("btn-slots-enter"),
    btnDelete: document.getElementById("btn-slots-delete"),
    rosterList: document.getElementById("roster-list"),
    heroFigure: document.getElementById("hero-figure"),
    heroGlyph: document.getElementById("hero-glyph"),
    heroWeapon: document.getElementById("hero-weapon"),
    heroBurst: document.getElementById("hero-burst"),
    heroCaption: document.getElementById("hero-caption"),
    epigraph: document.getElementById("epigraph"),
    detailName: document.getElementById("detail-name"),
    detailRole: document.getElementById("detail-role"),
    detailIntro: document.getElementById("detail-intro"),
    detailStats: document.getElementById("detail-stats"),
    nameInput: document.getElementById("name-input"),
    nameHint: document.getElementById("name-hint"),
    btnConfirm: document.getElementById("btn-create-confirm"),
    btnCancel: document.getElementById("btn-create-cancel"),
    toast: document.getElementById("toast"),
  };

  function fitStage() {
    if (!el.stage) return;
    var s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    el.stage.style.transform = "scale(" + s + ")";
    el.stage.style.marginTop = Math.max(0, (window.innerHeight - 1080 * s) / 2) + "px";
  }

  function showToast(text) {
    el.toast.textContent = text;
    el.toast.classList.add("is-show");
    clearTimeout(showToast._t);
    showToast._t = setTimeout(function () {
      el.toast.classList.remove("is-show");
    }, 1700);
  }

  function setScreen(name) {
    state.screen = name;
    el.screenSlots.classList.toggle("is-active", name === "slots");
    el.screenCreate.classList.toggle("is-active", name === "create");
  }

  function currentSlot() {
    return state.slots[state.selectedSlot - 1];
  }

  function findHero(id) {
    for (var i = 0; i < ROSTER.length; i++) {
      if (ROSTER[i].id === id) return ROSTER[i];
    }
    return null;
  }

  function codepointCount(str) {
    var n = 0;
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) i++;
      n++;
    }
    return n;
  }

  function validateName(raw) {
    var name = (raw || "").trim();
    if (!name) return { ok: false, reason: "落笔为名" };
    var n = codepointCount(name);
    if (n < 2) return { ok: false, reason: "至少二字" };
    if (n > 6) return { ok: false, reason: "至多六字" };
    if (/\s/.test(name)) return { ok: false, reason: "勿含空白" };
    return { ok: true, name: name, reason: "可入卷 · 位" + state.createTargetSlot };
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function renderSlots() {
    var html = "";
    for (var i = 0; i < 5; i++) {
      var s = state.slots[i];
      var idx = i + 1;
      var empty = s.empty !== false;
      var selected = state.selectedSlot === idx;
      html +=
        '<button type="button" class="slot-card slot-card--' +
        SLOT_SHAPE[i] +
        (selected ? " is-selected" : "") +
        (empty ? " is-empty" : "") +
        '" data-slot="' +
        idx +
        '" role="option" aria-selected="' +
        selected +
        '">' +
        '<span class="slot-card__rock" aria-hidden="true"></span>' +
        '<span class="slot-card__index">' +
        INDEX_LABEL[i] +
        "</span>" +
        '<span class="slot-card__glyph' +
        (empty ? "" : " is-filled") +
        '">' +
        (empty ? "空" : s.glyph || "侠") +
        "</span>" +
        '<span class="slot-card__name">' +
        (empty ? "空位" : escapeHtml(s.display_name)) +
        "</span>" +
        '<span class="slot-card__meta">' +
        (empty
          ? "尚未立档"
          : escapeHtml(s.catalogName || "") + " · " + escapeHtml(s.updated || "刚刚")) +
        "</span>" +
        "</button>";
    }
    el.slotsRow.innerHTML = html;

    var slot = currentSlot();
    var empty = !slot || slot.empty !== false;
    el.btnCreate.disabled = !empty;
    el.btnEnter.disabled = empty;
    el.btnDelete.disabled = empty;
    el.slotsTip.textContent = empty
      ? "择一空位 · 上山立档"
      : "「" + (slot.display_name || "") + "」· 入或删";
  }

  function renderRoster() {
    var html = "";
    for (var i = 0; i < ROSTER.length; i++) {
      var h = ROSTER[i];
      var sel = state.selectedHeroId === h.id;
      html +=
        '<button type="button" class="stone stone--' +
        i +
        (sel ? " is-selected" : "") +
        '" data-hero="' +
        h.id +
        '">' +
        '<span class="stone__face" aria-hidden="true"></span>' +
        '<span class="stone__glyph">' +
        h.glyph +
        "</span>" +
        '<span class="stone__label">' +
        h.catalogName +
        "</span>" +
        "</button>";
    }
    el.rosterList.innerHTML = html;
  }

  function renderStats(hero) {
    if (!hero) {
      el.detailStats.innerHTML = "";
      return;
    }
    var html = "";
    var keys = Object.keys(hero.stats);
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      var v = hero.stats[k];
      var filled = Math.max(0, Math.min(5, Math.round((v / STAT_MAX) * 5)));
      var dots = "";
      for (var d = 0; d < 5; d++) {
        dots += '<span class="bone__dot' + (d < filled ? " is-on" : "") + '"></span>';
      }
      html +=
        '<li class="bone"><span class="bone__label">' +
        k +
        '</span><span class="bone__dots">' +
        dots +
        '</span><span class="bone__value">' +
        v +
        "</span></li>";
    }
    el.detailStats.innerHTML = html;
  }

  function playEnterAnim() {
    var fig = el.heroFigure;
    var burst = el.heroBurst;
    fig.classList.remove("is-idle", "is-enter");
    void fig.offsetWidth;
    fig.classList.add("is-enter");
    burst.classList.remove("is-on");
    void burst.offsetWidth;
    burst.classList.add("is-on");
    clearTimeout(playEnterAnim._t);
    playEnterAnim._t = setTimeout(function () {
      fig.classList.remove("is-enter");
      fig.classList.add("is-idle");
      burst.classList.remove("is-on");
    }, 900);
  }

  function selectHero(id, withAnim) {
    var hero = findHero(id);
    if (!hero) return;
    state.selectedHeroId = id;

    el.heroGlyph.textContent = hero.glyph;
    if (el.heroWeapon) {
      if (hero.weapon) el.heroWeapon.removeAttribute("hidden");
      else el.heroWeapon.setAttribute("hidden", "");
    }
    el.heroCaption.textContent = hero.catalogName + " · " + hero.role;
    el.detailName.textContent = hero.catalogName;
    el.detailRole.textContent = hero.role + " · " + hero.tag;
    el.detailIntro.textContent = hero.intro;
    renderStats(hero);
    renderRoster();

    el.epigraph.hidden = false;
    // re-trigger epigraph animation
    el.epigraph.style.animation = "none";
    void el.epigraph.offsetWidth;
    el.epigraph.style.animation = "";

    if (withAnim !== false) playEnterAnim();
    if (!el.nameInput.value) el.nameInput.placeholder = "落名";
    updateNameUi();
  }

  function updateNameUi() {
    var v = validateName(el.nameInput.value);
    el.nameHint.textContent = v.reason;
    el.nameHint.classList.toggle("is-error", !v.ok && el.nameInput.value.trim().length > 0);
    el.nameHint.classList.toggle("is-ok", v.ok);
    el.btnConfirm.disabled = !(v.ok && state.selectedHeroId);
  }

  function openCreate() {
    var slot = currentSlot();
    if (!slot || slot.empty === false) {
      showToast("先择空位");
      return;
    }
    state.createTargetSlot = state.selectedSlot;
    state.selectedHeroId = null;
    el.nameInput.value = "";
    el.epigraph.hidden = true;
    el.heroGlyph.textContent = "？";
    el.heroCaption.textContent = "点石 · 影自雾来";
    el.heroFigure.classList.remove("is-enter");
    el.heroFigure.classList.add("is-idle");
    if (el.heroWeapon) el.heroWeapon.setAttribute("hidden", "");
    renderRoster();
    updateNameUi();
    setScreen("create");
    selectHero(ROSTER[0].id, true);
  }

  function cancelCreate() {
    setScreen("slots");
    renderSlots();
  }

  function confirmCreate() {
    var v = validateName(el.nameInput.value);
    if (!v.ok || !state.selectedHeroId) {
      updateNameUi();
      return;
    }
    var hero = findHero(state.selectedHeroId);
    state.slots[state.createTargetSlot - 1] = {
      empty: false,
      display_name: v.name,
      catalogName: hero.catalogName,
      glyph: hero.glyph,
      character_id: hero.id,
      chapter: hero.chapter,
      updated: "刚刚",
    };
    state.selectedSlot = state.createTargetSlot;
    setScreen("slots");
    renderSlots();
    showToast("立档 · " + v.name);
  }

  function deleteSlot() {
    var slot = currentSlot();
    if (!slot || slot.empty !== false) return;
    state.slots[state.selectedSlot - 1] = { empty: true };
    renderSlots();
    showToast("已空 · 位" + state.selectedSlot);
  }

  function enterSlot() {
    var slot = currentSlot();
    if (!slot || slot.empty !== false) {
      showToast("空位不可入");
      return;
    }
    showToast("入 · " + slot.display_name);
  }

  el.slotsRow.addEventListener("click", function (e) {
    var card = e.target.closest("[data-slot]");
    if (!card) return;
    state.selectedSlot = parseInt(card.getAttribute("data-slot"), 10);
    renderSlots();
  });

  el.btnCreate.addEventListener("click", openCreate);
  el.btnEnter.addEventListener("click", enterSlot);
  el.btnDelete.addEventListener("click", deleteSlot);
  el.btnCancel.addEventListener("click", cancelCreate);
  el.btnConfirm.addEventListener("click", confirmCreate);

  el.rosterList.addEventListener("click", function (e) {
    var stone = e.target.closest("[data-hero]");
    if (!stone) return;
    selectHero(stone.getAttribute("data-hero"), true);
  });

  el.nameInput.addEventListener("input", updateNameUi);
  el.nameInput.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !el.btnConfirm.disabled) confirmCreate();
  });

  window.addEventListener("resize", fitStage);
  fitStage();
  renderSlots();
})();
