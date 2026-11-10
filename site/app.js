import { SITE_CONFIG, verifiedDownload } from './config.js';
import { demoDateModel, shortDate, formatMenuTime, nextMinuteDelay } from './demo-date.js';
const $ = (id) => document.getElementById(id);
const story = $('experience');
const display = $('product-display');
const panel = $('notch-panel');
const compact = matchMedia('(max-width: 900px)');
const frame = document.querySelector('.product-frame');
function expanded(value) {
  frame.classList.toggle('is-expanded', value);
  display.scrollTop = 0;
  display.scrollLeft = 0;
  $('expand-demo').setAttribute('aria-pressed', String(value));
  $('expand-demo').textContent = value ? '전체 보기' : '화면 확대';
}
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const state = { scene: 1, open: true, calendar: false, editor: false, checked: new Set() };
let alertTimer = null;
let clockTimer = null;
let clockVisible = false;
const names = ['노치', '목록', '달력', '편집기'];
const reveal = () => { if (compact.matches) expanded(true); story.scrollIntoView({ behavior: reduced.matches ? 'instant' : 'smooth', block: 'start' }); };
const announce = (message) => { $('demo-status').textContent = message; };
function hideAlert() { clearTimeout(alertTimer); alertTimer = null; $('demo-alert').hidden = true; describeFeature(); }
function describeFeature() {
  const label = !$('demo-alert').hidden ? '오늘 마감 알림'
    : state.editor ? '할 일을 한 번에 편집'
    : !state.open ? '노치에서 바로 확인'
    : state.calendar ? '마감일은 달력에서' : '할 일과 과제를 함께';
  const caption = $('feature-caption');
  if (caption.textContent === label) return;
  const text = document.createElement('span');
  text.textContent = label;
  caption.replaceChildren(text);
}
function render() {
  syncDates();
  describeFeature();
  story.dataset.scene = String(state.scene);
  display.classList.toggle('is-open', state.open);
  display.classList.toggle('is-calendar', state.calendar);
  panel.inert = !state.open || state.editor;
  panel.setAttribute('aria-hidden', String(!state.open || state.editor));
  $('notch-toggle').setAttribute('aria-expanded', String(state.open));
  $('notch-toggle').setAttribute('aria-label', state.open ? '노치 접기' : '노치 펼치기');
  $('list-view').hidden = state.calendar;
  $('calendar-view').hidden = !state.calendar;
  $('calendar-toggle').setAttribute('aria-pressed', String(state.calendar));
  $('calendar-toggle').setAttribute('aria-label', state.calendar ? '목록 보기' : '달력 보기');
  $('editor-window').hidden = !state.editor;
  document.querySelectorAll('[data-scene]').forEach((button) => {
    if (button.tagName === 'BUTTON') button.setAttribute('aria-pressed', String(Number(button.dataset.scene) === state.scene));
  });
  $('previous-scene').disabled = state.scene === 0;
  $('next-scene').disabled = state.scene === 3;
  document.querySelectorAll('[data-check]').forEach((button) => {
    const done = state.checked.has(button.dataset.check);
    button.setAttribute('aria-pressed', String(done));
    button.closest('.task').classList.toggle('is-done', done);
  });
  $('todo-progress').textContent = `${['todo-a', 'todo-b'].filter((id) => state.checked.has(id)).length}개 완료`;
}
function scene(index) {
  hideAlert();
  display.scrollTop = 0;
  state.scene = Math.max(0, Math.min(3, index));
  state.open = state.scene === 1 || state.scene === 2;
  state.calendar = state.scene === 2;
  state.editor = state.scene === 3;
  render();
  announce(`${names[state.scene]} 화면`);
}
function interact(action) { hideAlert(); action(); render(); }
document.documentElement.classList.add('js');
$('desktop-date').textContent = formatMenuTime();
let renderedDate = '';
function syncDates() {
  const model = demoDateModel();
  if (model.key === renderedDate) return;
  renderedDate = model.key;

  $('panel-date').textContent = model.panelLabel;
  $('calendar-month').textContent = model.monthLabel;
  $('selected-day-label').textContent = model.todayLabel;
  Object.entries(model.dates).forEach(([id, date]) => {
    document.querySelector(`[data-task="${id}"] .due small`).textContent = shortDate(date);
  });
  document.querySelectorAll('[data-demo-offset]').forEach((node) => {
    const offset = Number(node.dataset.demoOffset);
    const id = offset === 2 ? 'lms-b' : offset === 1 ? 'todo-b' : 'lms-a';
    node.textContent = `${shortDate(model.dates[id])} · ${offset ? `D-${offset}` : 'D-Day'}`;
  });
  const grid = $('calendar-grid');
  grid.setAttribute('aria-label', `${model.monthLabel} 예시 달력`);
  const cells = model.cells.map((item) => {
    const cell = document.createElement('span');
    cell.className = 'calendar-day';
    if (!item) { cell.classList.add('is-empty'); cell.setAttribute('aria-hidden', 'true'); return cell; }
    cell.textContent = String(item.day);
    cell.setAttribute('aria-label', `${model.monthLabel} ${item.day}일${item.today ? ', 오늘' : ''}${item.tasks.length ? `, 예시 일정 ${item.tasks.length}개` : ''}`);
    cell.classList.toggle('is-past', item.past);
    cell.classList.toggle('is-today', item.today);
    const dots = document.createElement('span'); dots.className = 'day-dots';
    for (const group of ['lms-', 'todo-']) {
      if (!item.tasks.some((id) => id.startsWith(group))) continue;
      const dot = document.createElement('i'); if (group === 'todo-') dot.className = 'green'; dots.append(dot);
    }
    cell.append(dots);
    return cell;
  });
  grid.replaceChildren(...cells);
}
$('notch-toggle').addEventListener('click', () => interact(() => { state.open = !state.open; state.editor = false; announce(state.open ? '예시 할 일 패널을 펼쳤습니다.' : '패널을 접었습니다.'); }));
// Hover opens the preview only on devices with a real hover pointer. No mouse-position polling.
$('notch-toggle').addEventListener('pointerenter', (event) => {
  if (event.pointerType === 'mouse' && !state.open && !state.editor) interact(() => { state.open = true; });
});
// Treat the notch and panel as one hover area, including moves between them.
function leaveNotchPreview(event) {
  if (event.pointerType !== 'mouse' || !state.open || state.editor) return;
  const next = event.relatedTarget;
  if (next instanceof Node && (panel.contains(next) || $('notch-toggle').contains(next))) return;
  if (panel.contains(document.activeElement)) $('notch-toggle').focus({ preventScroll: true });
  interact(() => { state.open = false; });
}
$('notch-toggle').addEventListener('pointerleave', leaveNotchPreview);
panel.addEventListener('pointerleave', leaveNotchPreview);
document.querySelectorAll('[data-open-notch]').forEach((button) => button.addEventListener('click', () => {
  scene(1); reveal();
}));
$('calendar-toggle').addEventListener('click', () => interact(() => { state.calendar = !state.calendar; state.scene = state.calendar ? 2 : 1; announce(state.calendar ? '예시 달력으로 바꿨습니다.' : '목록으로 바꿨습니다.'); }));
$('editor-toggle').addEventListener('click', () => { scene(3); $('editor-close').focus({ preventScroll: true }); });
$('editor-close').addEventListener('click', () => { scene(1); $('editor-toggle').focus({ preventScroll: true }); });
document.querySelectorAll('[data-check]').forEach((button) => button.addEventListener('click', () => interact(() => {
  const id = button.dataset.check;
  state.checked.has(id) ? state.checked.delete(id) : state.checked.add(id);
  announce(`${button.closest('.task').querySelector('.task-title').textContent}, ${state.checked.has(id) ? '완료했습니다' : '완료를 취소했습니다'}. 이 화면의 가상 데이터에만 적용됩니다.`);
})));
document.querySelectorAll('button[data-scene]').forEach((button) => button.addEventListener('click', () => { scene(Number(button.dataset.scene)); reveal(); }));
$('previous-scene').addEventListener('click', () => { scene(state.scene - 1); reveal(); });
$('next-scene').addEventListener('click', () => { scene(state.scene + 1); reveal(); });
$('reset-demo').addEventListener('click', () => { state.checked.clear(); scene(1); reveal(); announce('가상 체험을 처음으로 되돌렸습니다.'); });
$('show-alert').addEventListener('click', () => {
  reveal();
  interact(() => { state.open = false; state.editor = false; });
  const remaining = ['lms-a', 'todo-a'].filter((id) => !state.checked.has(id));
  if (!remaining.length) { announce('오늘의 예시 할 일을 모두 마쳤습니다. 알림 예시를 보려면 처음으로 버튼을 누르세요.'); return; }
  $('alert-count').textContent = `오늘 마감 ${remaining.length}개`;
  $('alert-titles').textContent = remaining.length === 2 ? '예시 과제 A 외 1개' : remaining[0] === 'lms-a' ? '예시 과제 A' : '팀 발표 준비';
  $('demo-alert').hidden = false;
  describeFeature();
  announce('5초 동안 노치 알림 예시를 표시합니다. 알림을 누르면 목록을 펼칩니다.');
  // One finite timeout, only during an explicitly requested preview.
  alertTimer = setTimeout(hideAlert, 5000);
});
$('alert-close').addEventListener('click', () => { hideAlert(); $('show-alert').focus({ preventScroll: true }); });
$('alert-content').addEventListener('click', () => { scene(1); $('calendar-toggle').focus({ preventScroll: true }); });
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && (state.open || state.editor || !$('demo-alert').hidden)) {
    interact(() => { state.open = false; state.editor = false; });
    $('notch-toggle').focus({ preventScroll: true });
  }
});
// User-requested live minute clock. One timeout to the next minute boundary;
// no clock work when this stage is outside the viewport or the tab is hidden.
function updateClock() {
  clearTimeout(clockTimer); clockTimer = null;
  if (document.hidden || !clockVisible) return;
  $('desktop-date').textContent = formatMenuTime();
  syncDates();
  clockTimer = setTimeout(updateClock, nextMinuteDelay());
}
new IntersectionObserver(([entry]) => { clockVisible = entry.isIntersecting; if (!clockVisible) hideAlert(); updateClock(); }).observe(story);
document.addEventListener('visibilitychange', () => { if (document.hidden) hideAlert(); updateClock(); });
addEventListener('focus', updateClock);
$('expand-demo').addEventListener('click', () => expanded(!frame.classList.contains('is-expanded')));
compact.addEventListener('change', () => { if (!compact.matches) expanded(false); });
new ResizeObserver(() => { $('desktop-surface').style.transform = `scale(${display.clientWidth / 900})`; }).observe(display);
$('notch-panel').querySelector('a[href="#setup"]').addEventListener('click', () => { $('setup').open = true; });
const download = verifiedDownload(SITE_CONFIG);
if (download) {
  $('download-link').href = download;
  $('download-link').hidden = false;
  $('download-link').textContent = `Mac용 다운로드 · ${SITE_CONFIG.version}`;
  $('preview-cta').hidden = true;
  $('release-message').textContent = `DoIt ${SITE_CONFIG.version} (${SITE_CONFIG.build}) · macOS ${SITE_CONFIG.minimumMacOS} 이상`;
  document.querySelector('.nav-cta').textContent = '설치 안내';
}
render();

// One entrance for the approved copy; content is visible unless observation is available.
const focusIntro = document.querySelector('.focus-intro');
if (focusIntro && !reduced.matches && 'IntersectionObserver' in window) {
  focusIntro.classList.add('is-arriving');
  const introObserver = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting) return;
    focusIntro.classList.remove('is-arriving');
    introObserver.disconnect();
  }, { threshold: 0.15 });
  introObserver.observe(focusIntro);
}
