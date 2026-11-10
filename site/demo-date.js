// Pure local date model. No request, storage, or running clock.
export const DEMO_OFFSETS = Object.freeze({ 'lms-a': 0, 'lms-b': 2, 'lms-c': -1, 'todo-a': 0, 'todo-b': 1 });
const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
export const localDateKey = (date) => `${date.getFullYear()}-${date.getMonth() + 1}-${date.getDate()}`;
export const shortDate = (date) => `${date.getMonth() + 1}/${date.getDate()}`;
export function demoDateModel(now = new Date()) {
  // Noon + setDate keeps calendar arithmetic correct across DST and month/year boundaries.
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
  const year = today.getFullYear();
  const month = today.getMonth();
  const day = today.getDate();
  const dates = Object.fromEntries(Object.entries(DEMO_OFFSETS).map(([id, offset]) => {
    const date = new Date(today); date.setDate(date.getDate() + offset); return [id, date];
  }));
  const firstWeekday = new Date(year, month, 1, 12).getDay();
  const days = new Date(year, month + 1, 0, 12).getDate();
  const cells = Array.from({ length: Math.ceil((firstWeekday + days) / 7) * 7 }, (_, i) => {
    const number = i - firstWeekday + 1;
    if (number < 1 || number > days) return null;
    const date = new Date(year, month, number, 12);
    return { day: number, today: number === day, past: number < day,
      tasks: Object.keys(dates).filter((id) => localDateKey(dates[id]) === localDateKey(date)) };
  });
  return { key: localDateKey(today), monthLabel: `${year}년 ${month + 1}월`,
    desktopLabel: `${month + 1}월 ${day}일 (${weekdays[today.getDay()]})`,
    panelLabel: `${month + 1}/${day}(${weekdays[today.getDay()]})`,
    todayLabel: `${month + 1}월 ${day}일 · 오늘`, dates, cells };
}

export function formatMenuTime(now = new Date()) {
  const hour = now.getHours();
  return `${now.getMonth() + 1}월 ${now.getDate()}일 (${weekdays[now.getDay()]}) ${hour < 12 ? '오전' : '오후'} ${hour % 12 || 12}:${String(now.getMinutes()).padStart(2, '0')}`;
}
export const nextMinuteDelay = (now = Date.now()) => 60000 - now % 60000 + 10;
