// DoIt 전체 편집기 (PRD F9, DESIGN.md "전체 편집기 창", T-006)
// - 외부 라이브러리 없음. 앱과는 window.webkit.messageHandlers.doit(웹 → 앱)과 window.doit.render(state)(앱 → 웹)로만 통신한다
// - 사용자 제목은 항상 textContent / value로만 넣는다 (innerHTML 쓰지 않음)
// - 저장은 앱이 한다. 웹은 요청만 보내고, 앱이 검사·저장한 뒤 다시 render해 준 상태를 그린다
'use strict';

(function () {
  const $ = (id) => document.getElementById(id);
  const el = {
    search: $('search'),
    sortDue: $('sort-due'),
    sortAdded: $('sort-added'),
    lmsSection: $('lms-section'),
    lmsToggle: $('lms-toggle'),
    lmsCount: $('lms-count'),
    lmsList: $('lms-list'),
    todoCount: $('todo-count'),
    todoList: $('todo-list'),
    empty: $('empty'),
    bulkbar: $('bulkbar'),
    bulkCount: $('bulk-count'),
    bulkDone: $('bulk-done'),
    bulkUndone: $('bulk-undone'),
    bulkDelete: $('bulk-delete'),
    bulkClear: $('bulk-clear'),
  };

  const MAX_TITLE = 200;
  const WEEKDAYS = ['일', '월', '화', '수', '목', '금', '토'];
  const SVG_NS = 'http://www.w3.org/2000/svg';

  // 화면 상태 (앱으로 보내지 않는 것들)
  let state = null;          // 앱이 마지막으로 보낸 상태
  let pending = null;        // 고치는 중에 온 상태 (끝나면 그린다)
  let sortMode = 'due';      // 'due' | 'added'
  let lmsCollapsed = false;
  let selected = new Set();  // 고른 내 할 일 id
  let deleteArmed = false;   // `n개 삭제?` 확인 단계
  let editing = null;        // { id, input } 제목 고치는 중
  let dateFocused = false;   // 날짜 입력 사용 중

  function post(message) {
    try {
      window.webkit.messageHandlers.doit.postMessage(message);
    } catch (e) {
      // 앱 밖(일반 브라우저)에서 열렸을 때 — 아무것도 하지 않음
    }
  }

  // ── 날짜 계산 (yyyy-MM-dd 문자열, 시간대 영향 없게 UTC로) ──
  function dayNumber(text) {
    const [y, m, d] = text.split('-').map(Number);
    return Math.round(Date.UTC(y, m - 1, d) / 86400000);
  }
  function daysFromToday(text) {
    return dayNumber(text) - dayNumber(state.today);
  }
  function dDay(text) {
    const d = daysFromToday(text);
    if (d === 0) return 'D-Day';
    return d > 0 ? 'D-' + d : 'D+' + (-d);
  }
  function shortDate(text) {
    const [y, m, d] = text.split('-').map(Number);
    const w = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
    return m + '/' + d + '(' + WEEKDAYS[w] + ')';
  }
  function isValidDate(text) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(text)) return false;
    const [y, m, d] = text.split('-').map(Number);
    const t = new Date(Date.UTC(y, m - 1, d));
    return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
  }

  // ── 검색 ──
  function norm(s) {
    return (s || '').normalize('NFC').toLocaleLowerCase();
  }
  function matches(title, query) {
    return query === '' || norm(title).includes(query);
  }

  // ── 작은 요소 만들기 ──
  function make(tag, className, text) {
    const n = document.createElement(tag);
    if (className) n.className = className;
    if (text !== undefined) n.textContent = text;
    return n;
  }
  function svg(viewBox, build) {
    const s = document.createElementNS(SVG_NS, 'svg');
    s.setAttribute('viewBox', viewBox);
    s.setAttribute('aria-hidden', 'true');
    build(s);
    return s;
  }
  function svgChild(parent, tag, attrs) {
    const c = document.createElementNS(SVG_NS, tag);
    for (const k in attrs) c.setAttribute(k, attrs[k]);
    parent.appendChild(c);
  }
  function checkMark() {
    return svg('0 0 10 10', (s) => svgChild(s, 'polyline', { points: '2,5.2 4.2,7.4 8,3' }));
  }
  function pencil() {
    return svg('0 0 16 16', (s) => {
      svgChild(s, 'path', { d: 'M10.5 2.5l3 3L6 13H3v-3z' });
      svgChild(s, 'line', { x1: '9', y1: '4', x2: '12', y2: '7' });
    });
  }

  // ── 그리기 ──
  function applyPalette(palette, dark) {
    const root = document.documentElement.style;
    for (const name in palette) root.setProperty('--' + name, palette[name]);
    root.setProperty('color-scheme', dark ? 'dark' : 'light');
  }

  function busy() {
    return editing !== null || dateFocused;
  }

  window.doit = {
    render(next) {
      if (!next || typeof next !== 'object') return;
      applyPalette(next.palette || {}, !!next.dark);
      if (busy()) {
        pending = next;  // 고치는 중에는 목록을 다시 만들지 않는다 (입력·한글 조합이 끊기지 않게)
        return;
      }
      state = next;
      pending = null;
      draw();
    },
  };

  function flushPending() {
    if (busy()) return;
    if (pending) {
      state = pending;
      pending = null;
    }
    if (state) draw();
  }

  function draw() {
    if (!state) return;
    const query = norm(el.search.value.trim());

    // LMS 과제 (앱이 패널 LMS 칸 순서로 보냄)
    const lms = Array.isArray(state.lms) ? state.lms : null;
    el.lmsSection.hidden = lms === null;
    el.lmsSection.classList.toggle('collapsed', lmsCollapsed);
    el.lmsToggle.setAttribute('aria-expanded', String(!lmsCollapsed));
    const lmsShown = lms ? lms.filter((x) => matches(x.title, query)) : [];
    el.lmsCount.textContent = String(lmsShown.length);
    el.lmsList.replaceChildren(...lmsShown.map(lmsRow));
    if (lms && lmsShown.length === 0 && query === '') {
      el.lmsList.replaceChildren(make('li', 'none', '보일 과제가 없어요'));
    }

    // 내 할 일
    const key = sortMode === 'added' ? 'addedRank' : 'dueRank';
    const todos = state.todos.filter((t) => matches(t.title, query)).sort((a, b) => a[key] - b[key]);
    // 보이지 않게 된 항목은 선택에서 뺀다 (일괄 동작은 보이는 것에만)
    const shownIds = new Set(todos.map((t) => t.id));
    for (const id of Array.from(selected)) if (!shownIds.has(id)) selected.delete(id);
    el.todoCount.textContent = String(todos.length);
    el.todoList.replaceChildren(...todos.map(todoRow));
    if (todos.length === 0 && query === '') {
      el.todoList.replaceChildren(make('li', 'none', '할 일이 없어요 · 새 할 일은 노치 패널에서 추가해요'));
    }

    // 검색 결과 없음
    const nothing = query !== '' && todos.length === 0 && lmsShown.length === 0;
    el.empty.hidden = !nothing;
    el.empty.textContent = nothing ? '찾는 할 일이 없어요' : '';
    el.todoList.parentElement.hidden = nothing;
    if (nothing) el.lmsSection.hidden = true;

    drawBulk();
  }

  function lmsRow(item) {
    const days = daysFromToday(item.dueDate);
    const overdue = !item.checked && days < 0;
    const li = make('li', 'row');
    if (item.checked) li.classList.add('done');
    if (overdue) li.classList.add('overdue');

    const check = make('button', 'check' + (item.checked ? ' on' : ''));
    check.type = 'button';
    check.title = item.checked ? '체크 해제' : '체크';
    check.setAttribute('aria-pressed', String(item.checked));
    check.appendChild(checkMark());
    check.addEventListener('click', () => post({ type: 'toggleLmsCheck', uid: item.uid }));
    li.appendChild(check);

    const main = make('div', 'main');
    const title = make('span', 'title', item.title);
    title.title = item.title;
    main.appendChild(title);
    if (item.course) main.appendChild(make('span', 'chip', item.course));
    li.appendChild(main);

    const due = make('div', 'lms-due');
    let label = dDay(item.dueDate);
    if (overdue) label = days === -1 ? '어제 마감' : (-days) + '일 전 마감';
    due.appendChild(make('span', 'dday', label));
    due.appendChild(make('span', 'lms-date', shortDate(item.dueDate)));
    li.appendChild(due);
    return li;
  }

  function todoRow(todo) {
    const days = daysFromToday(todo.dueDate);
    const li = make('li', 'row');
    li.dataset.id = todo.id;
    if (todo.isDone) li.classList.add('done');
    else if (days < 0) li.classList.add('overdue');
    else if (days === 0) li.classList.add('today');
    if (selected.has(todo.id)) li.classList.add('selected');

    const pick = make('input', 'select');
    pick.type = 'checkbox';
    pick.checked = selected.has(todo.id);
    pick.title = '선택';
    pick.addEventListener('change', () => {
      if (pick.checked) selected.add(todo.id); else selected.delete(todo.id);
      li.classList.toggle('selected', pick.checked);
      deleteArmed = false;
      drawBulk();
    });
    li.appendChild(pick);

    const check = make('button', 'check' + (todo.isDone ? ' on' : ''));
    check.type = 'button';
    check.title = todo.isDone ? '미완료로' : '완료';
    check.setAttribute('aria-pressed', String(todo.isDone));
    check.appendChild(checkMark());
    check.addEventListener('click', () => post({ type: 'setDone', ids: [todo.id], done: !todo.isDone }));
    li.appendChild(check);

    const main = make('div', 'main');
    const title = make('span', 'title', todo.title);
    title.title = todo.title;
    title.addEventListener('dblclick', () => startEdit(todo.id));
    main.appendChild(title);
    li.appendChild(main);

    const edit = make('button', 'edit');
    edit.type = 'button';
    edit.title = '제목 고치기';
    edit.appendChild(pencil());
    edit.addEventListener('click', () => startEdit(todo.id));
    li.appendChild(edit);

    const due = make('div', 'due');
    const date = make('input', 'date');
    date.type = 'date';
    date.value = todo.dueDate;
    date.required = true;
    date.title = '마감일';
    date.addEventListener('focus', () => { dateFocused = true; });
    date.addEventListener('blur', () => { dateFocused = false; flushPending(); });
    date.addEventListener('change', () => {
      // 고르면 바로 저장. 빈 값·잘못된 값은 보내지 않고 원래 날짜로 되돌린다
      if (!isValidDate(date.value)) { date.value = todo.dueDate; return; }
      if (date.value === todo.dueDate) return;
      post({ type: 'updateTodo', id: todo.id, title: todo.title, dueDate: date.value });
      todo.dueDate = date.value;  // 같은 날짜를 다시 보내지 않게 (앱이 곧 새 상태로 다시 그림)
    });
    due.appendChild(date);
    due.appendChild(make('span', 'dday', dDay(todo.dueDate)));
    li.appendChild(due);
    return li;
  }

  // ── 제목 고치기 ──
  function startEdit(id) {
    if (editing) finishEdit(true);
    if (editing) return;  // 고치던 제목이 빈칸이라 끝나지 않음
    // 다시 그려졌을 수 있으니 지금 화면에서 행을 찾는다
    const todo = state && state.todos.find((t) => t.id === id);
    const row = Array.from(el.todoList.children).find((li) => li.dataset.id === id);
    const main = row && row.querySelector('.main');
    if (!todo || !main) return;
    const input = make('input', 'title-input');
    input.type = 'text';
    input.value = todo.title;
    input.maxLength = MAX_TITLE;
    input.spellcheck = false;
    input.autocomplete = 'off';
    editing = { id: todo.id, todo, input };
    main.replaceChildren(input);
    input.focus();
    input.select();

    input.addEventListener('keydown', (e) => {
      // 한글 조합 중 Enter·Esc는 조합을 끝내는 키이므로 저장·취소로 쓰지 않는다
      if (e.isComposing || e.keyCode === 229) return;
      if (e.key === 'Enter') { e.preventDefault(); finishEdit(true); }
      else if (e.key === 'Escape') { e.preventDefault(); finishEdit(false); }
    });
    input.addEventListener('input', () => input.classList.remove('invalid'));
    input.addEventListener('blur', () => {
      // 밖을 누르면 저장 (빈칸이면 취소)
      if (editing && editing.input === input) finishEdit(true);
    });
  }

  function finishEdit(save) {
    if (!editing) return;
    const { todo, input } = editing;
    const title = input.value.trim();
    if (save && title === '' && document.activeElement === input) {
      input.classList.add('invalid');  // 빈칸은 저장하지 않음 — 고치거나 Esc
      input.placeholder = '제목을 비울 수 없어요';
      return;
    }
    editing = null;
    if (save && title !== '' && title !== todo.title && title.length <= MAX_TITLE) {
      post({ type: 'updateTodo', id: todo.id, title, dueDate: todo.dueDate });
    }
    flushPending();  // 원래 행으로 다시 그린다 (저장했으면 곧 앱이 새 상태를 보냄)
  }

  // ── 일괄 막대 ──
  function drawBulk() {
    const n = selected.size;
    el.bulkbar.hidden = n === 0;
    if (n === 0) deleteArmed = false;
    el.bulkCount.textContent = n + '개 선택';
    el.bulkDelete.textContent = deleteArmed ? n + '개 삭제?' : '삭제';
    el.bulkDelete.classList.toggle('confirm', deleteArmed);
  }

  function selectedIds() {
    return Array.from(selected);
  }

  el.bulkDone.addEventListener('click', () => {
    post({ type: 'setDone', ids: selectedIds(), done: true });
    deleteArmed = false;
    drawBulk();
  });
  el.bulkUndone.addEventListener('click', () => {
    post({ type: 'setDone', ids: selectedIds(), done: false });
    deleteArmed = false;
    drawBulk();
  });
  el.bulkDelete.addEventListener('click', () => {
    if (!deleteArmed) {
      deleteArmed = true;  // 한 번 더 눌러야 삭제 (alert·confirm 쓰지 않음)
      drawBulk();
      return;
    }
    post({ type: 'deleteTodos', ids: selectedIds() });
    selected.clear();
    deleteArmed = false;
    drawBulk();
  });
  el.bulkClear.addEventListener('click', () => {
    selected.clear();
    deleteArmed = false;
    draw();
  });

  // 삭제 확인 중에 다른 곳을 누르면 취소
  document.addEventListener('mousedown', (e) => {
    if (deleteArmed && e.target !== el.bulkDelete) {
      deleteArmed = false;
      drawBulk();
    }
  }, true);

  // ── 도구줄 ──
  el.search.addEventListener('input', () => draw());
  el.search.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !e.isComposing && el.search.value !== '') {
      el.search.value = '';
      draw();
    }
  });
  function setSort(mode) {
    sortMode = mode;
    el.sortDue.classList.toggle('on', mode === 'due');
    el.sortAdded.classList.toggle('on', mode === 'added');
    el.sortDue.setAttribute('aria-pressed', String(mode === 'due'));
    el.sortAdded.setAttribute('aria-pressed', String(mode === 'added'));
    draw();
  }
  el.sortDue.addEventListener('click', () => setSort('due'));
  el.sortAdded.addEventListener('click', () => setSort('added'));
  el.lmsToggle.addEventListener('click', () => {
    lmsCollapsed = !lmsCollapsed;
    draw();
  });

  // 링크·끌어 놓기로 다른 곳에 가지 않게 (이동 자체는 앱이 한 번 더 막는다)
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', (e) => e.preventDefault());

  post({ type: 'ready' });
})();
