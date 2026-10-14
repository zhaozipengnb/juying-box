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
  clear(): void { this.store.deleteSync(KEY_CONFIG); }
}
