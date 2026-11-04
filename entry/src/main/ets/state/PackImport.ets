// 聚合源包导入助手：系统文件选择器选聚合源 JSON（{sites:[...]} 或完整 聚合源配置，
// 规则可内嵌 data: URL）→ 读回文本 → AppState 装载。供首页空态引导与设置页共用。
import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppState } from './AppState';

// 拉起文件选择器并导入源包；成功返回源包站点数，用户取消返回 -1，失败抛错由调用方提示
export async function pickImportPack(app: AppState): Promise<number> {
  const opt = new picker.DocumentSelectOptions();
  opt.maxSelectNumber = 1;
  opt.fileSuffixFilters = ['json'];
  const dp = new picker.DocumentViewPicker();
  const uris: string[] = await dp.select(opt);
  if (uris.length === 0) { return -1; }
  hilog.info(0x0000, 'OKV', 'pack pick uri=%{public}s', uris[0]);
  const f = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  const stat = fs.statSync(f.fd);
  const buf = new ArrayBuffer(Math.max(stat.size, 1));
  const n = fs.readSync(f.fd, buf);
  fs.closeSync(f);
  const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf.slice(0, n)));
  hilog.info(0x0000, 'OKV', 'pack read bytes=%{public}d head=%{public}s', n, text.substring(0, 40));
  const ok = app.loadFromPackText(text);
  hilog.info(0x0000, 'OKV', 'pack load ok=%{public}s sites=%{public}d', ok,
    app.config?.sites.length ?? 0);
  if (!ok) { throw new Error(app.errMsg !== '' ? app.errMsg : '源包装载失败'); }
  return app.config?.sites.length ?? 0;
}
