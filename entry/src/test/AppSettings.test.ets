// AppSettings 单测：默认值 / 装载坏数据降级 / 持久化往返（KVStore 假实现，无 @ohos 依赖）
import { describe, it, expect } from '@ohos/hypium';
import { AppSettings, SPEED_OPTIONS, LONG_PRESS_OPTIONS } from '../main/ets/state/AppSettings';
import { KVStore } from '../main/ets/state/ConfigStore';

class MemKV implements KVStore {
  map: Map<string, string> = new Map();
  getSync(k: string): string | undefined { return this.map.get(k); }
  putSync(k: string, v: string): void { this.map.set(k, v); }
  deleteSync(k: string): void { this.map.delete(k); }
}

export default function appSettingsTest() {
  describe('appSettingsTest', () => {
    it('defaults', 0, () => {
      const s = new AppSettings();
      expect(s.picSize === 'normal').assertTrue();
      expect(s.playSpeed === 1.0).assertTrue();
      expect(s.longPressSpeed === 3.0).assertTrue();
      expect(s.incognito).assertFalse();
      expect(s.aggSearch).assertFalse();
      expect(s.showSite).assertTrue();
      expect(s.siteFilter).assertFalse();
      expect(s.wallpaper === 'default').assertTrue();
      expect(SPEED_OPTIONS.indexOf(1.0) >= 0).assertTrue();
      expect(LONG_PRESS_OPTIONS.length > 1).assertTrue();
    });
    it('save_load_roundtrip', 0, () => {
      const kv = new MemKV();
      const s1 = new AppSettings();
      s1.attach(kv);
      s1.picSize = 'large';
      s1.playSpeed = 1.5;
      s1.longPressSpeed = 0;
      s1.incognito = true;
      s1.aggSearch = true;
      s1.showSite = false;
      s1.siteFilter = true;
      s1.aiAdFilter = true;
      s1.builtinDownload = true;
      s1.wallpaper = 'dark';
      s1.save();
      const s2 = new AppSettings();
      s2.attach(kv);
      expect(s2.picSize === 'large').assertTrue();
      expect(s2.playSpeed === 1.5).assertTrue();
      expect(s2.longPressSpeed === 0).assertTrue();
      expect(s2.incognito).assertTrue();
      expect(s2.aggSearch).assertTrue();
      expect(s2.showSite).assertFalse();
      expect(s2.siteFilter).assertTrue();
      expect(s2.aiAdFilter).assertTrue();
      expect(s2.builtinDownload).assertTrue();
      expect(s2.wallpaper === 'dark').assertTrue();
    });
    it('corrupt_payload_falls_back_to_defaults', 0, () => {
      const kv = new MemKV();
      kv.putSync('juying_settings_json', '{not json');
      const s = new AppSettings();
      s.attach(kv);
      expect(s.picSize === 'normal').assertTrue();
      expect(s.playSpeed === 1.0).assertTrue();
    });
    it('invalid_values_ignored', 0, () => {
      const kv = new MemKV();
      kv.putSync('juying_settings_json',
        '{"picSize":"huge","playSpeed":7,"longPressSpeed":9,"wallpaper":"pink","incognito":"yes"}');
      const s = new AppSettings();
      s.attach(kv);
      expect(s.picSize === 'normal').assertTrue();
      expect(s.playSpeed === 1.0).assertTrue();
      expect(s.longPressSpeed === 3.0).assertTrue();
      expect(s.wallpaper === 'default').assertTrue();
      expect(s.incognito).assertFalse();   // 非布尔不接受
    });
  });
}
