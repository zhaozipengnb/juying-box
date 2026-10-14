// HttpClient（M1 Task 5）—— 基于 @ohos.net.http 的统一网络层
// TDD 说明：本文件依赖 @ohos.net.http，无法本地单测，真机验证在收口阶段执行
import { http } from '@kit.NetworkKit';
import { utf8Decode } from 'common';

export interface HttpFetchOptions {
  method?: string;                      // 默认 GET
  headers?: Record<string, string>;    // 含 User-Agent
  timeoutMs?: number;                  // 默认 15000
}
export interface HttpFetchResult {
  status: number;                       // HTTP 状态码
  headers: Record<string, string>;      // 响应头（小写键）
  body: ArrayBuffer;                    // 原始字节（订阅是 JPEG）
  text: () => string;  // UTF-8 解码
}

export async function httpFetch(url: string, opts?: HttpFetchOptions): Promise<HttpFetchResult> {
  const client = http.createHttp();
  // 默认 UA 提取为显式类型常量（?? 右侧对象字面量需显式类型，arkts-no-untyped-obj-literals）
  const defaultHeaders: Record<string, string> = { 'User-Agent': 'okhttp/3.15' };
  try {
    const resp = await client.request(url, {
      method: (opts?.method === 'POST') ? http.RequestMethod.POST : http.RequestMethod.GET,
      header: opts?.headers ?? defaultHeaders,
      connectTimeout: opts?.timeoutMs ?? 15000,
      readTimeout: opts?.timeoutMs ?? 15000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    });
    const headers: Record<string, string> = {};
    const respHeaders = resp.header as Record<string, string>;
    for (const k of Object.keys(respHeaders)) { headers[k.toLowerCase()] = respHeaders[k]; }
    const bodyBuf = resp.result instanceof ArrayBuffer ? resp.result : new ArrayBuffer(0);
    // 返回对象提取为显式类型变量（async return 的对象字面量需显式类型，arkts-no-untyped-obj-literals）
    const result: HttpFetchResult = {
      status: resp.responseCode, headers: headers, body: bodyBuf,
      text: (): string => utf8Decode(new Uint8Array(bodyBuf))
    };
    return result;
  } finally {
    client.destroy();
  }
}
