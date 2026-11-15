const WEEKDAYS = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

export function parseDay(day: string): Date {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(y, m - 1, d);
}

export function dayKey(ms: number): string {
  const d = new Date(ms);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function weekday(day: string): string {
  return WEEKDAYS[parseDay(day).getDay()];
}

export function monthDay(day: string): string {
  const d = parseDay(day);
  return `${d.getMonth() + 1}月${d.getDate()}日`;
}

function daysBetween(day: string, today: string): number {
  return Math.round((parseDay(today).getTime() - parseDay(day).getTime()) / 86400000);
}

/** Short label for a history row: 昨天 / 周三 / 11月2日 / 2025年3月1日. */
export function shortDay(day: string, today: string): string {
  const diff = daysBetween(day, today);
  if (diff === 0) return "今天";
  if (diff === 1) return "昨天";
  if (diff > 1 && diff < 7) return weekday(day);
  const d = parseDay(day);
  if (d.getFullYear() === parseDay(today).getFullYear()) return `${d.getMonth() + 1}月${d.getDate()}日`;
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

/** Group heading for the history list. */
export function groupOf(day: string, today: string): string {
  const diff = daysBetween(day, today);
  if (diff < 7) return "最近七天";
  const d = parseDay(day);
  const t = parseDay(today);
  if (d.getFullYear() === t.getFullYear() && d.getMonth() === t.getMonth()) return "本月早些时候";
  if (d.getFullYear() === t.getFullYear()) return `${d.getMonth() + 1}月`;
  return `${d.getFullYear()}年${d.getMonth() + 1}月`;
}
