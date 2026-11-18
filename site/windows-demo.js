import { localDateKey } from './demo-date.js';

// Example data only. Nothing here is saved: no request, cookie, or browser storage.
// Offsets are days from today. Labels follow the WPF app (PanelWindow, LmsSection, EditorWindow).
const lmsSeed = [
  { id: 'lms-c', title: '예시 과제 C', course: '예시 과목 2', offset: -1 },
  { id: 'lms-a', title: '예시 과제 A', course: '예시 과목 1', offset: 0 },
  { id: 'lms-b', title: '예시 과제 B', course: '예시 과목 1', offset: 2 },
];
const todoSeed = [
  { title: '예시 보고서 제출 확인', offset: -1 },
  { title: '팀 발표 준비', offset: 0 },
  { title: '읽을 자료 정리', offset: 1 },
  { title: '도서관 책 반납', offset: 3 },
];
const MAX_TITLE = 200;
const MAX_ADDED = 20;
const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
const dateLabel = new Intl.DateTimeFormat('ko-KR', { year: 'numeric', month: 'long', day: 'numeric' });
const monthLabel = new Intl.DateTimeFormat('ko-KR', { year: 'numeric', month: 'long' });
const dueChoices = [0, 1, 7];

const noon = (date) => new Date(date.getFullYear(), date.getMonth(), date.getDate(), 12);
const today = () => noon(new Date());
const addDays = (date, days) => { const next = noon(date); next.setDate(next.getDate() + days); return next; };
const dayNumber = (date) => Math.round(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()) / 86400000);
const daysFromToday = (date) => dayNumber(date) - dayNumber(today());
const shortLabel = (date) => `${date.getMonth() + 1}/${date.getDate()}(${weekdays[date.getDay()]})`;
const headingLabel = (date) => `${date.getMonth() + 1}월 ${date.getDate()}일 (${weekdays[date.getDay()]}) 할 일`;
const todoDayLabel = (days) => (days === 0 ? 'D-Day' : days > 0 ? `D-${days}` : `D+${-days}`);
const lmsDayLabel = (days, done) => (days === -1 && !done ? '어제 마감' : todoDayLabel(days));
// Same rule as the app's title check: 1-200 characters, no control characters.
const hasControl = (text) => [...text].some((ch) => { const code = ch.codePointAt(0); return code < 32 || (code >= 127 && code < 160); });

export function startWindowsDemo() {
  const $ = (name) => document.getElementById(`windows-${name}`);
  const panel = $('panel');
  const tray = $('tray');
  const stage = $('stage');
  const dialog = $('dialog');
  const closeDialog = $('close-dialog');
  const calendar = $('calendar');
  const input = $('input');
  const search = $('search');
  const sort = $('sort');
  const settingTabs = Array.from(document.querySelectorAll('#windows-settings [role="tab"]'));
  let lms;
  let todos;
  let nextId;
  let mode;
  let month;
  let selectedDate;
  let dueChoice;
  let lmsExpanded;
  let armedDelete;
  let batch;
  let batchDeleteArmed;

  function resetData() {
    const base = today();
    lms = lmsSeed.map((item) => ({ ...item, date: addDays(base, item.offset), done: false }));
    todos = todoSeed.map((item, index) => ({ id: `todo-${index}`, order: index, title: item.title, date: addDays(base, item.offset), done: false }));
    nextId = todos.length;
    mode = 'list';
    dueChoice = 0;
    lmsExpanded = true;
    armedDelete = null;
    batch = new Set();
    batchDeleteArmed = false;
    setToday();
  }

  const announce = (message) => { $('demo-status').textContent = message; };
  function setToday() {
    selectedDate = today();
    month = new Date(selectedDate.getFullYear(), selectedDate.getMonth(), 1, 12);
  }
  const calendarOpen = () => mode === 'calendar';
  const canModifySelectedDay = () => !calendarOpen() || daysFromToday(selectedDate) >= 0;
  const draftDueDate = () => (calendarOpen() ? selectedDate : addDays(today(), dueChoices[dueChoice]));
  const byDue = (a, b) => dayNumber(a.date) - dayNumber(b.date) || a.order - b.order;

  function makeCheck(label, done, disabled, data) {
    const check = document.createElement('input');
    check.type = 'checkbox';
    check.className = 'windows-check';
    check.checked = done;
    check.disabled = disabled;
    check.setAttribute('aria-label', label);
    Object.assign(check.dataset, data);
    return check;
  }

  function makeDeadline(dayText, date, overdue) {
    const box = document.createElement('span');
    const day = document.createElement('b');
    const when = document.createElement('small');
    box.className = 'windows-deadline';
    day.textContent = dayText;
    day.classList.toggle('is-past', overdue);
    when.textContent = shortLabel(date);
    box.append(day, when);
    return box;
  }

  function lmsRow(item, canToggle) {
    const row = document.createElement('li');
    const text = document.createElement('span');
    const title = document.createElement('span');
    const course = document.createElement('small');
    const days = daysFromToday(item.date);
    row.className = 'windows-task is-lms';
    row.classList.toggle('is-checked', item.done);
    text.className = 'windows-task-label';
    title.textContent = item.title;
    course.textContent = item.course;
    text.append(title, course);
    row.append(makeCheck(`${item.title}, 과제 완료 체크`, item.done, !canToggle, { windowsLms: item.id }), text,
      makeDeadline(lmsDayLabel(days, item.done), item.date, !item.done && days < 0));
    return row;
  }

  function todoRow(item, canToggle, canDelete) {
    const row = document.createElement('li');
    const title = document.createElement('span');
    const days = daysFromToday(item.date);
    row.className = 'windows-task';
    row.classList.toggle('is-checked', item.done);
    title.className = 'windows-task-label';
    title.textContent = item.title;
    row.append(makeCheck(`${item.title}, 완료 체크`, item.done, !canToggle, { windowsTodo: item.id }), title,
      makeDeadline(todoDayLabel(days), item.date, !item.done && days < 0));
    if (canDelete) {
      const armed = armedDelete === item.id;
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'windows-delete';
      remove.classList.toggle('is-armed', armed);
      remove.dataset.windowsDelete = item.id;
      remove.textContent = armed ? '삭제?' : '×';
      remove.setAttribute('aria-label', armed ? `${item.title} 삭제 확인` : `${item.title} 삭제`);
      row.append(remove);
    }
    return row;
  }

  function renderList() {
    const container = $('list');
    const showDay = calendarOpen();
    const key = localDateKey(selectedDate);
    const canWrite = canModifySelectedDay();
    const lmsItems = lms.filter((item) => !showDay || localDateKey(item.date) === key).sort(byDue);
    const todoItems = todos.filter((item) => !showDay || localDateKey(item.date) === key).sort(byDue);
    const parts = [];
    if (lmsItems.length) {
      const section = document.createElement('section');
      const toggle = document.createElement('button');
      const list = document.createElement('ul');
      section.className = 'windows-lms';
      toggle.type = 'button';
      toggle.className = 'windows-lms-heading';
      toggle.id = 'windows-lms-toggle';
      toggle.setAttribute('aria-expanded', String(lmsExpanded));
      toggle.setAttribute('aria-controls', 'windows-lms-rows');
      toggle.textContent = `LMS 과제 · ${lmsItems.length}개`;
      list.id = 'windows-lms-rows';
      list.hidden = !lmsExpanded;
      list.append(...lmsItems.map((item) => lmsRow(item, canWrite)));
      section.append(toggle, list);
      parts.push(section);
    }
    const heading = document.createElement('h3');
    heading.className = 'windows-todo-heading';
    heading.textContent = showDay ? headingLabel(selectedDate) : '할 일';
    parts.push(heading);
    if (todoItems.length) {
      const list = document.createElement('ul');
      list.append(...todoItems.map((item) => todoRow(item, canWrite, canWrite && !showDay)));
      parts.push(list);
    } else {
      const empty = document.createElement('p');
      empty.className = 'windows-empty';
      empty.textContent = showDay ? '이 날의 할 일이 없어요.' : '할 일이 없어요.';
      parts.push(empty);
    }
    container.replaceChildren(...parts);
  }

  function renderQuickAdd() {
    const canWrite = canModifySelectedDay();
    const due = draftDueDate();
    const label = daysFromToday(due) === 0 ? '오늘' : shortLabel(due);
    $('quick-add').hidden = !canWrite;
    $('past-day').hidden = canWrite;
    if (!canWrite) $('add-error').hidden = true;
    $('due').hidden = calendarOpen();
    $('due-text').hidden = !calendarOpen();
    $('due').textContent = label;
    $('due').setAttribute('aria-label', `마감 날짜, ${label}`);
    $('due-text').textContent = label;
  }

  function renderDays(focusDay = false) {
    const first = new Date(month.getFullYear(), month.getMonth(), 1, 12);
    const selectedKey = localDateKey(selectedDate);
    const todayKey = localDateKey(today());
    const gridStart = addDays(first, -first.getDay());
    const inGrid = dayNumber(selectedDate) >= dayNumber(gridStart) && dayNumber(selectedDate) < dayNumber(gridStart) + 42;
    const tabKey = inGrid ? selectedKey : localDateKey(first);
    $('month').textContent = monthLabel.format(first);
    const buttons = Array.from({ length: 42 }, (_, index) => {
      const date = addDays(gridStart, index);
      const key = localDateKey(date);
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'windows-day';
      button.classList.toggle('is-today', key === todayKey);
      button.classList.toggle('is-adjacent', date.getMonth() !== first.getMonth());
      button.dataset.windowsDate = key;
      button.tabIndex = key === tabKey ? 0 : -1;
      button.setAttribute('aria-label', dateLabel.format(date));
      button.setAttribute('aria-pressed', String(key === selectedKey));
      button.append(String(date.getDate()));
      const dots = document.createElement('span');
      dots.className = 'windows-day-dots';
      dots.setAttribute('aria-hidden', 'true');
      const todoMatches = todos.filter((item) => localDateKey(item.date) === key);
      const lmsMatches = lms.filter((item) => localDateKey(item.date) === key);
      for (const [matches, kind] of [[todoMatches, 'todo'], [lmsMatches, 'lms']]) {
        if (!matches.length) continue;
        const dot = document.createElement('i');
        const overdue = kind === 'lms' && daysFromToday(date) < 0 && matches.some((item) => !item.done);
        dot.classList.toggle('is-lms', kind === 'lms');
        dot.classList.toggle('is-overdue', overdue);
        dot.classList.toggle('is-checked', matches.every((item) => item.done));
        dots.append(dot);
      }
      button.append(dots);
      return button;
    });
    $('days').replaceChildren(...buttons);
    if (focusDay) buttons.find((button) => button.dataset.windowsDate === selectedKey)?.focus({ preventScroll: true });
  }

  function renderPanel() {
    const open = calendarOpen();
    panel.dataset.mode = mode;
    $('calendar-view').hidden = !open;
    calendar.textContent = open ? '목록' : '달력';
    calendar.setAttribute('aria-label', open ? '할 일 목록 보기' : '월간 달력 보기');
    calendar.setAttribute('aria-pressed', String(open));
    if (open) renderDays();
    renderQuickAdd();
    renderList();
    $('caption').textContent = open ? '같은 패널에서 월간 달력을 확인합니다.' : '트레이에서 내 할 일과 과제를 함께 봅니다.';
  }

  function renderEditor() {
    const query = search.value.trim().normalize('NFC').toLowerCase();
    const sorted = [...todos].sort(sort.value === 'added' ? (a, b) => a.order - b.order : byDue);
    const visible = sorted.filter((item) => !query || item.title.normalize('NFC').toLowerCase().includes(query));
    for (const id of [...batch]) if (!todos.some((item) => item.id === id)) batch.delete(id);
    const rows = visible.map((item) => {
      const row = document.createElement('li');
      const state = document.createElement('span');
      const title = document.createElement('span');
      const days = daysFromToday(item.date);
      row.className = 'windows-editor-row';
      row.classList.toggle('is-checked', item.done);
      state.className = 'windows-editor-state';
      state.textContent = item.done ? '완료' : '미완료';
      title.className = 'windows-task-label';
      title.textContent = item.title;
      title.title = item.title;
      row.append(makeCheck(`${item.title}, 일괄 작업 선택`, batch.has(item.id), false, { windowsBatchItem: item.id }), state, title,
        makeDeadline(todoDayLabel(days), item.date, !item.done && days < 0));
      return row;
    });
    $('editor-rows').replaceChildren(...rows);
    $('editor-empty').hidden = rows.length > 0;
    $('batch').hidden = batch.size === 0;
    $('batch-count').textContent = `${batch.size}개 선택`;
    $('batch-delete').textContent = batchDeleteArmed ? `${batch.size}개 삭제 확인` : '삭제';
  }

  function addTodo() {
    if (!canModifySelectedDay()) return;
    const title = input.value.trim();
    const error = $('add-error');
    let message = '';
    if (!title) return;
    if (title.length > MAX_TITLE) message = `제목은 ${MAX_TITLE}자까지 입력할 수 있어요.`;
    else if (hasControl(title)) message = '제목에 줄바꿈이나 제어 문자는 넣을 수 없어요.';
    else if (todos.length >= todoSeed.length + MAX_ADDED) message = '체험에서는 예시 할 일을 더 추가할 수 없어요.';
    error.textContent = message;
    error.hidden = !message;
    if (message) {
      announce(message);
      return;
    }
    todos.push({ id: `todo-${nextId}`, order: nextId, title, date: draftDueDate(), done: false });
    nextId += 1;
    input.value = '';
    dueChoice = 0;
    renderPanel();
    announce(`${title} 추가 (예시라 저장하지 않습니다)`);
    calendar.focus({ preventScroll: true });
  }

  function closePanel(restoreFocus = false) {
    panel.hidden = true;
    armedDelete = null;
    tray.setAttribute('aria-expanded', 'false');
    tray.setAttribute('aria-label', 'DoIt 트레이 열기');
    if (restoreFocus) tray.focus({ preventScroll: true });
  }

  function showPanel(focus = false) {
    dialog.hidden = true;
    renderPanel();
    panel.hidden = false;
    tray.setAttribute('aria-expanded', 'true');
    tray.setAttribute('aria-label', 'DoIt 트레이 닫기');
    if (focus) calendar.focus({ preventScroll: true });
    announce(calendarOpen() ? 'DoIt 달력 패널을 열었습니다.' : 'DoIt 목록 패널을 열었습니다.');
  }

  function closeWindow(restoreFocus = false) {
    dialog.hidden = true;
    batchDeleteArmed = false;
    $('caption').textContent = '작업 표시줄에서 DoIt 아이콘을 눌러 보세요.';
    if (restoreFocus) tray.focus({ preventScroll: true });
  }

  function selectSettingTab(tab, focus = false) {
    for (const item of settingTabs) {
      const active = item === tab;
      item.setAttribute('aria-selected', String(active));
      item.tabIndex = active ? 0 : -1;
      document.getElementById(item.getAttribute('aria-controls')).hidden = !active;
    }
    if (focus) tab.focus({ preventScroll: true });
  }

  function openDialog(kind) {
    const editor = kind === 'editor';
    const title = editor ? '전체 편집기' : '설정';
    closePanel();
    dialog.dataset.kind = kind;
    $('dialog-title').textContent = `DoIt ${title}`;
    $('editor').hidden = !editor;
    $('settings').hidden = editor;
    batchDeleteArmed = false;
    if (editor) renderEditor();
    else selectSettingTab(settingTabs[0]);
    dialog.hidden = false;
    $('caption').textContent = editor ? '전체 편집기는 별도 창에서 열립니다.' : '설정은 별도 창에서 열립니다.';
    closeDialog.focus({ preventScroll: true });
    announce(`DoIt ${title} 창을 열었습니다.`);
  }

  function selectDay(key) {
    const [year, monthNumber, day] = key.split('-').map(Number);
    selectedDate = new Date(year, monthNumber - 1, day, 12);
    month = new Date(year, monthNumber - 1, 1, 12);
    renderDays(true);
    renderQuickAdd();
    renderList();
    announce(`${dateLabel.format(selectedDate)} 선택`);
  }

  function runBatch(action) {
    const selected = todos.filter((item) => batch.has(item.id));
    if (action === 'clear') {
      batch.clear();
      batchDeleteArmed = false;
      announce('선택을 해제했습니다.');
    } else if (action === 'delete') {
      if (!batchDeleteArmed) {
        batchDeleteArmed = true;
        renderEditor();
        announce(`${selected.length}개를 삭제하려면 한 번 더 누르세요.`);
        $('batch-delete').focus({ preventScroll: true });
        return;
      }
      todos = todos.filter((item) => !batch.has(item.id));
      batch.clear();
      batchDeleteArmed = false;
      announce('선택한 할 일을 삭제했습니다.');
    } else {
      const done = action === 'done';
      for (const item of selected) item.done = done;
      batchDeleteArmed = false;
      announce(done ? '선택한 할 일을 완료했습니다.' : '선택한 할 일을 미완료로 바꿨습니다.');
    }
    renderEditor();
    if (batch.size === 0) search.focus({ preventScroll: true });
  }

  tray.addEventListener('click', (event) => {
    if (panel.hidden) showPanel(event.detail === 0);
    else {
      closePanel();
      $('caption').textContent = '작업 표시줄에서 DoIt 아이콘을 눌러 보세요.';
      announce('DoIt 패널을 닫았습니다.');
    }
  });
  tray.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      if (!event.repeat) tray.click();
    }
  });
  calendar.addEventListener('click', () => {
    mode = calendarOpen() ? 'list' : 'calendar';
    if (calendarOpen()) setToday();
    armedDelete = null;
    $('add-error').hidden = true;
    renderPanel();
    announce(calendarOpen() ? '달력으로 바꿨습니다.' : '목록으로 바꿨습니다.');
  });
  for (const [name, offset] of [['prev-month', -1], ['next-month', 1]]) {
    $(name).addEventListener('click', () => {
      month.setMonth(month.getMonth() + offset);
      renderDays();
      announce(`${monthLabel.format(month)} 달력`);
    });
  }
  $('today').addEventListener('click', () => {
    setToday();
    renderPanel();
    announce('오늘 날짜를 선택했습니다.');
  });
  $('days').addEventListener('click', (event) => {
    const date = event.target.closest('[data-windows-date]')?.dataset.windowsDate;
    if (date) selectDay(date);
  });
  $('days').addEventListener('keydown', (event) => {
    const offsets = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };
    const offset = offsets[event.key];
    if (offset === undefined || !event.target.dataset.windowsDate) return;
    event.preventDefault();
    const [year, monthNumber, day] = event.target.dataset.windowsDate.split('-').map(Number);
    selectDay(localDateKey(new Date(year, monthNumber - 1, day + offset, 12)));
  });
  $('due').addEventListener('click', () => {
    dueChoice = (dueChoice + 1) % dueChoices.length;
    renderQuickAdd();
    announce(`마감 날짜 ${$('due').textContent}`);
  });
  $('add').addEventListener('click', addTodo);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.isComposing && event.keyCode !== 229 && !event.repeat) {
      event.preventDefault();
      addTodo();
    }
  });
  input.addEventListener('input', () => { $('add-error').hidden = true; });
  search.addEventListener('input', renderEditor);
  sort.addEventListener('change', () => {
    renderEditor();
    announce(`${sort.selectedOptions[0].textContent}으로 정렬했습니다.`);
  });
  $('settings').querySelector('[role="tablist"]').addEventListener('keydown', (event) => {
    const index = settingTabs.indexOf(event.target);
    if (index < 0) return;
    const next = { ArrowLeft: index - 1, ArrowRight: index + 1, Home: 0, End: settingTabs.length - 1 }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    selectSettingTab(settingTabs[(next + settingTabs.length) % settingTabs.length], true);
  });
  stage.addEventListener('change', (event) => {
    const target = event.target;
    if (target.dataset.windowsLms) {
      const item = lms.find((row) => row.id === target.dataset.windowsLms);
      if (!item || !canModifySelectedDay()) return;
      item.done = target.checked;
      renderPanel();
      document.querySelector(`[data-windows-lms="${item.id}"]`)?.focus({ preventScroll: true });
      announce(`${item.title} ${item.done ? '완료' : '완료 취소'}`);
    } else if (target.dataset.windowsTodo) {
      const item = todos.find((row) => row.id === target.dataset.windowsTodo);
      if (!item || !canModifySelectedDay()) return;
      item.done = target.checked;
      armedDelete = null;
      renderPanel();
      document.querySelector(`[data-windows-todo="${item.id}"]`)?.focus({ preventScroll: true });
      announce(`${item.title} ${item.done ? '완료' : '완료 취소'}`);
    } else if (target.dataset.windowsBatchItem) {
      const id = target.dataset.windowsBatchItem;
      if (target.checked) batch.add(id);
      else batch.delete(id);
      batchDeleteArmed = false;
      renderEditor();
      document.querySelector(`[data-windows-batch-item="${id}"]`)?.focus({ preventScroll: true });
    }
  });
  stage.addEventListener('click', (event) => {
    const tool = event.target.closest('[data-windows-dialog]');
    const remove = event.target.closest('[data-windows-delete]');
    const batchButton = event.target.closest('[data-windows-batch]');
    const tab = event.target.closest('#windows-settings [role="tab"]');
    if (tool) openDialog(tool.dataset.windowsDialog);
    else if (event.target.closest('#windows-lms-toggle')) {
      lmsExpanded = !lmsExpanded;
      renderList();
      $('lms-toggle').focus({ preventScroll: true });
    } else if (remove) {
      const id = remove.dataset.windowsDelete;
      const item = todos.find((row) => row.id === id);
      if (!item) return;
      if (armedDelete === id) {
        todos = todos.filter((row) => row.id !== id);
        armedDelete = null;
        renderPanel();
        calendar.focus({ preventScroll: true });
        announce(`${item.title} 삭제`);
      } else {
        armedDelete = id;
        renderList();
        document.querySelector(`[data-windows-delete="${id}"]`)?.focus({ preventScroll: true });
        announce('한 번 더 누르면 삭제합니다.');
      }
    } else if (batchButton) runBatch(batchButton.dataset.windowsBatch);
    else if (tab) selectSettingTab(tab, true);
    else if (!panel.hidden && !event.composedPath().includes(panel) && !event.composedPath().includes(tray)) {
      closePanel(panel.contains(document.activeElement));
      $('caption').textContent = '작업 표시줄에서 DoIt 아이콘을 눌러 보세요.';
      announce('DoIt 패널을 닫았습니다.');
    }
  });
  closeDialog.addEventListener('click', () => closeWindow(true));
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || $('experience').closest('[role="tabpanel"]').hidden) return;
    if (event.isComposing) return;
    if (!dialog.hidden) closeWindow(true);
    else if (!panel.hidden) {
      closePanel(true);
      $('caption').textContent = '작업 표시줄에서 DoIt 아이콘을 눌러 보세요.';
    } else return;
    event.preventDefault();
    announce('DoIt 예시 화면을 닫았습니다.');
  });
  $('reset').addEventListener('click', () => {
    resetData();
    input.value = '';
    search.value = '';
    sort.value = 'due';
    $('add-error').hidden = true;
    closePanel();
    closeWindow();
    announce('Windows 체험을 초기화했습니다.');
  });

  resetData();

  return {
    open() {
      showPanel();
      $('experience').scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
      tray.focus({ preventScroll: true });
    },
  };
}
