import { describe, it, expect } from '@ohos/hypium';
import { ConfigStore, KVStore, serializeConfig, parseStoredConfig } from '../main/ets/state/ConfigStore';
import { decodeConfigContent } from 'common';

// 内存 KVStore 假实现（模拟 preferences 行为）
class FakeKVStore implements KVStore {
  private map: Map<string, string> = new Map();
  getSync(k: string): string | undefined { return this.map.get(k); }
  putSync(k: string, v: string): void { this.map.set(k, v); }
  deleteSync(k: string): void { this.map.delete(k); }
}

const SAMPLE_CONFIG = `{
  "sites": [{ "key": "k1", "name": "测试站", "type": 1, "api": "https://example.com/api.php/provide/vod" }]
}`;

export default function configStoreTest() {
  describe('configStoreTest', () => {
    it('serialize_then_parse_roundtrip', 0, () => {
      const cfg = decodeConfigContent(SAMPLE_CONFIG);
      const json = serializeConfig('https://sub.example.com/conf', cfg);
      const back = parseStoredConfig(json);
      // hypium 无 toBeNull 匹配器，用 not().assertNull() 表达"非空"
      expect(back).not().assertNull();
      if (back !== null) {
        expect(back.url === 'https://sub.example.com/conf').assertTrue();
        expect(back.configJson.length > 0).assertTrue();
      }
    });
    it('parse_bad_json_returns_null', 0, () => {
      expect(parseStoredConfig('not-json')).assertNull();
    });
    it('save_then_load', 0, () => {
      const cfg = decodeConfigContent(SAMPLE_CONFIG);
      const store = new ConfigStore(new FakeKVStore());
      store.save('https://sub.example.com/conf', serializeConfig('https://sub.example.com/conf', cfg));
      const loaded = store.load();
      expect(loaded).not().assertNull();
      if (loaded !== null) { expect(loaded.url === 'https://sub.example.com/conf').assertTrue(); }
    });
    it('load_empty_returns_null', 0, () => {
      expect(new ConfigStore(new FakeKVStore()).load()).assertNull();
    });
    it('clear_removes_entry', 0, () => {
      const store = new ConfigStore(new FakeKVStore());
      store.save('u', serializeConfig('u', decodeConfigContent(SAMPLE_CONFIG)));
      store.clear();
      expect(store.load()).assertNull();
    });
  });
}
