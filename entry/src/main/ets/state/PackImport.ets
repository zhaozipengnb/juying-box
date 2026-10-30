// 聚合源包导入助手：系统文件选择器选聚合源 JSON（{sites:[...]} 或完整 TVBox 配置，
// 规则可内嵌 data: URL）→ 读回文本 → AppState 装载。供首页空态引导与设置页共用。
import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import { util } from '@kit.ArkTS';
import { AppState } from './AppState';

// 拉起文件选择器并导入源包；成功返回源包站点数，用户取消返回 -1，失败抛错由调用方提示
export async function pickImportPack(app: AppState): Promise<number> {
  const opt = new picker.DocumentSelectOptions();
  opt.maxSelectNumber = 1;
  opt.fileSuffixFilters = ['json'];
  const dp = new picker.DocumentViewPicker();
  const uris: string[] = await dp.select(opt);
  if (uris.length === 0) { return -1; }
  const f = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  const stat = fs.statSync(f.fd);
  const buf = new ArrayBuffer(Math.max(stat.size, 1));
  const n = fs.readSync(f.fd, buf);
  fs.closeSync(f);
  const text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buf.slice(0, n)));
  return app.importSourcePack(text);
}
