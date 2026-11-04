// 直播频道收藏（KVStore 持久化），LivePage 星标与收藏分组共用。
import { KVStore } from './ConfigStore';

const KEY = 'juying_live_favs';

@ObservedV2
export class LiveFavs {
  static instance: LiveFavs = new LiveFavs();
  private store: KVStore | null = null;
  @Trace urls: string[] = [];

  attach(store: KVStore): void {
    this.store = store;
    this.load();
  }

  private load(): void {
    const raw = this.store?.getSync(KEY);
    if (raw === undefined || raw === '') { this.urls = []; return; }
    try {
      const arr = JSON.parse(raw) as string[];
      if (Array.isArray(arr)) { this.urls = arr; }
    } catch (e) { this.urls = []; }
  }

  private persist(): void {
    this.store?.putSync(KEY, JSON.stringify(this.urls));
  }

  has(url: string): boolean {
    return this.urls.indexOf(url) >= 0;
  }

  toggle(url: string): void {
    const i = this.urls.indexOf(url);
    if (i >= 0) { this.urls.splice(i, 1); } else { this.urls.unshift(url); }
    this.persist();
  }
}
