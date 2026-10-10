// Kept independent from CAF/DOM so message and timeline behavior can be tested.
export function activeLyricIndex(lines, seconds) {
  const time = Math.max(0, Number(seconds) || 0) * 1000;
  let low = 0, high = lines.length - 1, answer = -1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (lines[mid].timeMs <= time) { answer = mid; low = mid + 1; }
    else high = mid - 1;
  }
  return answer;
}
export function clock(seconds) {
  const value = Math.max(0, Math.floor(Number(seconds) || 0));
  const hours = Math.floor(value / 3600);
  return hours ? `${hours}:${String(Math.floor(value / 60) % 60).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`
    : `${Math.floor(value / 60)}:${String(value % 60).padStart(2, '0')}`;
}
export class LyricsState {
  constructor() { this.mediaId = null; this.lines = []; this.synced = false; }
  load(id) { this.mediaId = id; this.lines = []; this.synced = false; }
  accept(message) {
    if (message.mediaId !== this.mediaId) return false;
    if (message.type === 'lyricsReset') { this.lines = []; this.synced = message.synced === true; return true; }
    if (message.type !== 'lyrics' || !Array.isArray(message.lines)) return false;
    const rows = message.lines.filter(row => Number.isFinite(row.timeMs) && typeof row.text === 'string').map(row => ({
      timeMs: Math.max(0, row.timeMs), text: row.text.slice(0, 12000), translation: typeof row.translation === 'string' ? row.translation.slice(0, 12000) : '',
    }));
    this.lines.push(...rows.slice(0, Math.max(0, 5000 - this.lines.length)));
    if (this.synced) this.lines.sort((a, b) => a.timeMs - b.timeMs);
    return true;
  }
}
export function safeArtwork(url) {
  try { const parsed = new URL(url); return ['http:', 'https:'].includes(parsed.protocol) ? parsed.href : ''; }
  catch { return ''; }
}
export function normalizeAppearance(ui) {
  if (!ui || typeof ui !== 'object') return {};
  const result = {style: ui.style === 'material' ? 'material' : 'mornye', font: ['Inter','Google Sans Flex'].includes(ui.font) ? ui.font : 'system', reduceMotion: ui.reduceMotion === true};
  for (const key of ['surface','ink','muted','accent','onAccent','backgroundStart','backgroundEnd']) {
    if (typeof ui[key] === 'string' && /^#[0-9a-f]{6}$/i.test(ui[key])) result[key] = ui[key];
  }
  result.labels = {};
  if (ui.labels && typeof ui.labels === 'object') {
    for (const [key,value] of Object.entries(ui.labels)) if (typeof value === 'string') result.labels[key] = value.slice(0,200);
  }
  return result;
}
