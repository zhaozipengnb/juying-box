// 时长格式化：秒 → 'h:mm:ss' / 'mm:ss'（非法输入返回 '00:00'）
export function formatDuration(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) { return '00:00'; }
  const total = Math.floor(sec);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const mm = m.toString().padStart(2, '0');
  const ss = s.toString().padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}
