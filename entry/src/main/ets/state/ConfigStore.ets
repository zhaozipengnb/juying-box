// 配置持久化：preferences 依赖以 KVStore 接口注入，纯序列化逻辑可本地单测
import { TvboxConfig } from 'common';

export interface KVStore {
  getSync(k: string): string | undefined;
  putSync(k: string, v: string): void;
  deleteSync(k: string): void;
}

export interface StoredConfig {
  url: string;
  configJson: string;
}

const KEY_CONFIG = 'okvideo_stored_config';
const KEY_CURRENT_SITE = 'okvideo_current_site';
const KEY_SOURCE_PACKS = 'okvideo_source_packs';

export function serializeConfig(url: string, config: TvboxConfig): string {
  const stored: StoredConfig = { url: url, configJson: JSON.stringify(config) };
  return JSON.stringify(stored);
}

export function parseStoredConfig(json: string): StoredConfig | null {
  try {
    const obj = JSON.parse(json) as Record<string, Object>;
    const url = obj['url'];
    const cfg = obj['configJson'];
    if (typeof url !== 'string' || typeof cfg !== 'string') { return null; }
    return { url: url, configJson: cfg };
  } catch (e) { return null; }
}

export class ConfigStore {
  private store: KVStore;
  constructor(store: KVStore) { this.store = store; }
  load(): StoredConfig | null {
    const raw = this.store.getSync(KEY_CONFIG);
    if (raw === undefined || raw === '') { return null; }
    return parseStoredConfig(raw);
  }
  save(url: string, json: string): void { this.store.putSync(KEY_CONFIG, json); }
  clear(): void {
    this.store.deleteSync(KEY_CONFIG);
    this.store.deleteSync(KEY_CURRENT_SITE);
  }
  // 当前选中源跨重启记忆：switchSite 时写入，initFromStore 恢复
  saveCurrentSite(key: string): void { this.store.putSync(KEY_CURRENT_SITE, key); }
  loadCurrentSite(): string {
    const v = this.store.getSync(KEY_CURRENT_SITE);
    return v === undefined ? '' : v;
  }
  // 导入聚合源包（SiteConfig 数组 JSON）：随订阅合并，跨重启可用
  saveSourcePacks(sitesJson: string): void { this.store.putSync(KEY_SOURCE_PACKS, sitesJson); }
  loadSourcePacks(): string {
    const v = this.store.getSync(KEY_SOURCE_PACKS);
    return v === undefined ? '' : v;
  }
  clearSourcePacks(): void { this.store.deleteSync(KEY_SOURCE_PACKS); }
}
