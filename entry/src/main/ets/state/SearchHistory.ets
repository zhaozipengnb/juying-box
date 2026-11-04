// 搜索历史：基于 KVStore 持久化，无痕模式下不写入。
// 消费点：HomePage 搜索栏下方展示历史标签、SettingsPage 清除搜索历史。
import { KVStore } from './ConfigStore';

const KEY_SEARCH_HISTORY = 'juying_search_history';
const MAX_HISTORY = 20;

export class SearchHistory {
  static instance: SearchHistory = new SearchHistory();
  private store: KVStore | null = null;
  private items: string[] = [];

  // EntryAbility 装配：注入持久化后立即装载既有值
  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  load(): void {
    const raw = this.store?.getSync(KEY_SEARCH_HISTORY);
    if (raw === undefined || raw === '') { return; }
    try {
      const arr = JSON.parse(raw) as string[];
      if (Array.isArray(arr)) { this.items = arr.filter((s: string): boolean => typeof s === 'string' && s !== ''); }
    } catch (e) { /* 坏数据按空起步 */ }
  }

  // 新增搜索词：去重后置顶，超限截断
  add(term: string): void {
    const t = term.trim();
    if (t === '') { return; }
    this.items = this.items.filter((s: string): boolean => s !== t);
    this.items.unshift(t);
    if (this.items.length > MAX_HISTORY) { this.items = this.items.slice(0, MAX_HISTORY); }
    this.save();
  }

  getAll(): string[] {
    return this.items;
  }

  clear(): void {
    this.items = [];
    this.save();
  }

  private save(): void {
    if (this.store === null) { return; }
    this.store.putSync(KEY_SEARCH_HISTORY, JSON.stringify(this.items));
  }
}
