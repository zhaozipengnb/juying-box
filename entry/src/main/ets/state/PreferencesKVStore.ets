// preferences 同步 API 包装：与 ConfigStore 的 KVStore 接口对接
import { preferences } from '@kit.ArkData';
import { KVStore } from './ConfigStore';

export class PreferencesKVStore implements KVStore {
  private pref: preferences.Preferences;
  constructor(pref: preferences.Preferences) { this.pref = pref; }
  getSync(k: string): string | undefined {
    const v = this.pref.getSync(k, '') as string;
    return v === '' ? undefined : v;
  }
  putSync(k: string, v: string): void { this.pref.putSync(k, v); this.pref.flush(); }
  deleteSync(k: string): void { this.pref.deleteSync(k); }
}
