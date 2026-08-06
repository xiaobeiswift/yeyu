/**
 * 选择角色画板 · 交互原型
 * 五角色位：选中 / 新建 / 进入 / 删除 / 返回
 */
(function () {
  'use strict';

  var stage = document.getElementById('stage');
  var slotsRoot = document.getElementById('slots');
  var messageEl = document.getElementById('message');
  var btnEnter = document.getElementById('btn-enter');
  var btnCreate = document.getElementById('btn-create');
  var btnDelete = document.getElementById('btn-delete');

  var state = { selected: 1 };

  function fitStage() {
    if (!stage) return;
    var scale = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    stage.style.transform = 'scale(' + scale + ')';
    stage.style.marginTop = Math.max(0, (window.innerHeight - 1080 * scale) / 2) + 'px';
  }

  function selectedSlot() {
    return slotsRoot.querySelector('.slot[data-slot="' + state.selected + '"]');
  }

  function isEmpty(slotEl) {
    return slotEl && slotEl.getAttribute('data-empty') === 'true';
  }

  function refreshUi() {
    var nodes = slotsRoot.querySelectorAll('.slot');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var on = Number(n.getAttribute('data-slot')) === state.selected;
      n.classList.toggle('is-selected', on);
      n.setAttribute('aria-selected', on ? 'true' : 'false');
    }

    var slot = selectedSlot();
    var empty = isEmpty(slot);
    btnEnter.disabled = empty;
    btnDelete.disabled = empty;

    if (empty) {
      messageEl.textContent = '已选位 ' + state.selected + ' · 空位，请先「新建」';
    } else {
      var name = slot.querySelector('.slot__name');
      messageEl.textContent =
        '已选位 ' + state.selected + ' · ' + (name ? name.textContent.trim() : '');
    }
  }

  function selectSlot(index) {
    state.selected = index;
    refreshUi();
  }

  function createSlot() {
    var slot = selectedSlot();
    if (!slot) return;
    if (!isEmpty(slot)) {
      if (!window.confirm('位 ' + state.selected + ' 已有角色，覆盖并新建？')) return;
    }
    slot.classList.remove('is-empty');
    slot.setAttribute('data-empty', 'false');
    var portrait = slot.querySelector('.slot__portrait-inner');
    if (portrait) {
      portrait.className = 'slot__portrait-inner slot__portrait-inner--filled';
      portrait.innerHTML = '';
    }
    var meta = slot.querySelector('.slot__meta');
    if (meta) {
      meta.innerHTML =
        '<h2 class="slot__name">新行者 · ' +
        state.selected +
        '</h2>' +
        '<p class="slot__chapter">卷一 · 开局</p>' +
        '<div class="slot__stats">' +
        '<span class="slot__stat">0 分</span>' +
        '<span class="slot__stat">刚刚</span>' +
        '</div>';
    }
    if (!slot.querySelector('.slot__selected-mark')) {
      var mark = document.createElement('div');
      mark.className = 'slot__selected-mark';
      mark.setAttribute('aria-hidden', 'true');
      mark.textContent = '已选';
      slot.querySelector('.slot__frame').appendChild(mark);
    }
    messageEl.textContent = '已新建：新行者 · ' + state.selected;
    refreshUi();
  }

  function deleteSlot() {
    var slot = selectedSlot();
    if (!slot || isEmpty(slot)) return;
    if (!window.confirm('确定删除位 ' + state.selected + ' 的角色？此操作不可恢复。')) return;
    slot.classList.add('is-empty');
    slot.setAttribute('data-empty', 'true');
    var portrait = slot.querySelector('.slot__portrait-inner');
    if (portrait) {
      portrait.className = 'slot__portrait-inner slot__portrait-inner--empty';
      portrait.innerHTML = '';
    }
    var meta = slot.querySelector('.slot__meta');
    if (meta) {
      meta.innerHTML =
        '<h2 class="slot__name slot__name--muted">空 位</h2>' +
        '<p class="slot__chapter">尚未立档</p>' +
        '<p class="slot__empty-hint">点「新建」创建角色</p>';
    }
    var mark = slot.querySelector('.slot__selected-mark');
    if (mark) mark.remove();
    messageEl.textContent = '已删除位 ' + state.selected;
    refreshUi();
  }

  function enterSlot() {
    var slot = selectedSlot();
    if (!slot || isEmpty(slot)) {
      messageEl.textContent = '空位不能进入。请先「新建」。';
      return;
    }
    var name = slot.querySelector('.slot__name');
    messageEl.textContent = '进入：' + (name ? name.textContent.trim() : '');
    stage.style.filter = 'brightness(0.35)';
    setTimeout(function () {
      stage.style.filter = '';
      messageEl.textContent = '（原型）已进入游戏';
    }, 400);
  }

  slotsRoot.addEventListener('click', function (e) {
    var card = e.target.closest('.slot');
    if (!card) return;
    selectSlot(Number(card.getAttribute('data-slot')));
  });

  slotsRoot.addEventListener('dblclick', function (e) {
    var card = e.target.closest('.slot');
    if (!card) return;
    selectSlot(Number(card.getAttribute('data-slot')));
    if (isEmpty(card)) createSlot();
    else enterSlot();
  });

  document.getElementById('btn-back').addEventListener('click', function () {
    messageEl.textContent = '（原型）返回上一屏';
  });
  document.getElementById('btn-create').addEventListener('click', createSlot);
  document.getElementById('btn-delete').addEventListener('click', deleteSlot);
  document.getElementById('btn-enter').addEventListener('click', enterSlot);

  window.addEventListener('resize', fitStage);
  fitStage();
  refreshUi();
})();
