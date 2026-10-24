// URL 历史：基于 KVStore 持久化，按类型（vod/live/wallpaper）分别存储。
import { KVStore } from './ConfigStore';

const KEY_URL_HISTORY = 'okvideo_url_history';
const MAX_HISTORY = 10;

interface UrlHistoryData {
  vod: string[];
  live: string[];
  wallpaper: string[];
}

export class UrlHistory {
  static instance: UrlHistory = new UrlHistory();
  private store: KVStore | null = null;
  private data: UrlHistoryData = { vod: [], live: [], wallpaper: [] };

  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  load(): void {
    const raw = this.store?.getSync(KEY_URL_HISTORY);
    if (raw === undefined || raw === '') { return; }
    try {
      const obj = JSON.parse(raw) as UrlHistoryData;
      if (obj && Array.isArray(obj.vod)) { this.data.vod = obj.vod; }
      if (obj && Array.isArray(obj.live)) { this.data.live = obj.live; }
      if (obj && Array.isArray(obj.wallpaper)) { this.data.wallpaper = obj.wallpaper; }
    } catch (e) { /* 坏数据按空起步 */ }
  }

  add(target: string, url: string): void {
    const u = url.trim();
    if (u === '') { return; }
    const list = this.getList(target);
    const filtered = list.filter((s: string): boolean => s !== u);
    filtered.unshift(u);
    if (filtered.length > MAX_HISTORY) { filtered.length = MAX_HISTORY; }
    this.setList(target, filtered);
    this.save();
  }

  get(target: string): string[] {
    return this.getList(target);
  }

  clear(target: string): void {
    this.setList(target, []);
    this.save();
  }

  private getList(target: string): string[] {
    if (target === 'vod') { return this.data.vod; }
    if (target === 'live') { return this.data.live; }
    return this.data.wallpaper;
  }

  private setList(target: string, list: string[]): void {
    if (target === 'vod') { this.data.vod = list; }
    else if (target === 'live') { this.data.live = list; }
    else { this.data.wallpaper = list; }
  }

  private save(): void {
    if (this.store === null) { return; }
    this.store.putSync(KEY_URL_HISTORY, JSON.stringify(this.data));
  }
}
