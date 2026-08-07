/* create_character board preview — node names match BOARD_CONTRACT.md */
(function () {
  "use strict";

  var ROSTER = [
    { id: "hero_mist", glyph: "雾", name: "雾中客", role: "无名剑客 · 均衡 · 剑",
      intro: "钟下无碑。步履轻，刃意沉。只问雾开时能否见路。",
      stats: { 力: 12, 骨: 12, 身: 12, 息: 12 } },
    { id: "hero_blade", glyph: "刃", name: "霜刃行", role: "快刀客 · 爆发 · 刀",
      intro: "刀出如霜，收势不回头。认准一处，连进三招。",
      stats: { 力: 15, 骨: 10, 身: 14, 息: 9 } },
    { id: "hero_herb", glyph: "药", name: "青囊影", role: "行医隐侠 · 稳健 · 杂学",
      intro: "青囊系肘。言少算深，先保命，再论胜负。",
      stats: { 力: 9, 骨: 15, 身: 10, 息: 14 } },
    { id: "hero_wind", glyph: "风", name: "踏云生", role: "轻功客 · 机变 · 轻功",
      intro: "檐角一点，雾面三折。不恋缠斗，专找夹缝活路。",
      stats: { 力: 10, 骨: 10, 身: 16, 息: 12 } },
    { id: "hero_bow", glyph: "弦", name: "暮弦", role: "冷弓手 · 远程 · 弓",
      intro: "十步外才是她的道理。话少，箭更少。",
      stats: { 力: 11, 骨: 10, 身: 14, 息: 13 } },
    { id: "hero_monk", glyph: "禅", name: "半偈", role: "还俗僧 · 防御 · 拳",
      intro: "袈裟已卸，戒疤还在。今日只问能否走过这截径。",
      stats: { 力: 13, 骨: 16, 身: 8, 息: 11 } },
  ];

  var STAT_MAX = 18;
  var selected = 0;

  var rosterEl = document.getElementById("layout_roster");
  var statsEl = document.getElementById("stats");
  var treeEl = document.getElementById("tree");

  function renderRoster() {
    rosterEl.innerHTML = "";
    ROSTER.forEach(function (e, i) {
      var btn = document.createElement("button");
      btn.type = "button";
      btn.className = "roster_btn" + (i === selected ? " is-selected" : "");
      btn.setAttribute("data-y3", "roster_btn_" + (i + 1));
      btn.id = "roster_btn_" + (i + 1);
      var img = document.createElement("img");
      img.src = i === selected
        ? "../generated/panel_roster_item_selected.png"
        : "../generated/panel_roster_item.png";
      img.alt = "";
      var lab = document.createElement("span");
      lab.className = "roster_label";
      lab.setAttribute("data-y3", "roster_label_" + (i + 1));
      lab.textContent = e.glyph + "  " + e.name;
      btn.appendChild(img);
      btn.appendChild(lab);
      btn.addEventListener("click", function () {
        selected = i;
        paint();
      });
      rosterEl.appendChild(btn);
    });
  }

  function renderStats(entry) {
    statsEl.innerHTML = "";
    var order = ["力", "骨", "身", "息"];
    order.forEach(function (k, idx) {
      var n = entry.stats[k] || 0;
      var row = document.createElement("div");
      row.className = "stat-row";
      var lab = document.createElement("span");
      lab.className = "lab";
      lab.setAttribute("data-y3", "label_stat_" + (idx + 1));
      lab.textContent = k;
      var bar = document.createElement("div");
      bar.className = "bar";
      bar.setAttribute("data-y3", "bar_stat_" + (idx + 1));
      var fill = document.createElement("i");
      fill.style.width = Math.round((n / STAT_MAX) * 100) + "%";
      bar.appendChild(fill);
      var val = document.createElement("span");
      val.className = "val";
      val.setAttribute("data-y3", "label_stat_val_" + (idx + 1));
      val.textContent = String(n);
      row.appendChild(lab);
      row.appendChild(bar);
      row.appendChild(val);
      statsEl.appendChild(row);
    });
  }

  function paint() {
    var e = ROSTER[selected];
    document.getElementById("label_glyph").textContent = e.glyph;
    document.getElementById("label_model_caption").textContent = e.name + " · 预览";
    document.getElementById("label_name").textContent = e.name;
    document.getElementById("label_role").textContent = e.role;
    document.getElementById("label_intro").textContent = e.intro;
    document.getElementById("label_subtitle").textContent =
      "角色位 1 · 点选风骨后确认（预览）";
    document.getElementById("label_tip").textContent =
      "选中：" + e.name + " · 导入编辑器后由 shell 写槽";
    renderRoster();
    renderStats(e);
  }

  document.getElementById("button_返回").addEventListener("click", function () {
    document.getElementById("label_tip").textContent = "（预览）返回 → 应回 save_slot";
  });
  document.getElementById("button_确认立档").addEventListener("click", function () {
    var e = ROSTER[selected];
    document.getElementById("label_tip").textContent =
      "（预览）确认立档：" + e.name + " · 引擎会 LocalRunSlotStore:create";
  });

  treeEl.textContent =
    "create_character\n" +
    "├── image_bg\n" +
    "├── layout_title\n" +
    "│   ├── label_title\n" +
    "│   └── label_subtitle\n" +
    "├── layout_roster\n" +
    "│   ├── roster_btn_1..6\n" +
    "│   └── roster_label_1..6\n" +
    "├── layout_stage\n" +
    "│   ├── image_stage_frame\n" +
    "│   ├── model_preview  ← 模型控件\n" +
    "│   ├── label_glyph\n" +
    "│   └── label_model_caption\n" +
    "├── layout_detail\n" +
    "│   ├── image_detail_panel\n" +
    "│   ├── label_name / role / intro\n" +
    "│   └── label_stat_* / bar_stat_*\n" +
    "├── layout_button\n" +
    "│   ├── button_返回\n" +
    "│   └── button_确认立档\n" +
    "└── layout_tip\n" +
    "    └── label_tip";

  paint();
})();
