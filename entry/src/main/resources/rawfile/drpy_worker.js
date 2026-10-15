// drpy Worker：drpy2 运行时与插件的隔离执行环境
// 关键：Worker 线程允许同步 XHR——为 drpy2 提供宿主要求的同步 req()（主线程被禁，必须在此）
// 消息协议：
//   主线程 → { type:'init', drpy2Code, extCode, cfgJson }
//   主线程 → { type:'call', method, args: string[] }
//   Worker → { type:'log', msg } / { type:'result', id, value }（call 结果，value 为 JSON 字符串或 {__error}）

// Worker 无 window：drpy2 内部引用 window 的点需兜底
if (typeof window === 'undefined') { globalThis.window = globalThis; }
if (typeof document === 'undefined') {
  // 极简 document 桩：drpy2 个别路径引用（DOM 解析在 ArkTS 代理模式下不触达）
  globalThis.document = { createElement: function () { return { style: {} }; } };
}

// ---------- 宿主同步网络层（drpy2 的 req 依赖） ----------
function syncReq(url, obj) {
  obj = obj || {};
  var x = new XMLHttpRequest();
  x.open((obj.method || 'GET'), url, false);  // 同步 XHR：Worker 内合法
  var hs = obj.headers || {};
  var ks = Object.keys(hs);
  for (var i = 0; i < ks.length; i++) {
    try { x.setRequestHeader(ks[i], hs[ks[i]]); } catch (e) { /* 非法头忽略 */ }
  }
  try { x.send(obj.body || null); } catch (e) {
    return { content: '', headers: {}, error: String(e) };
  }
  var headers = {};
  var raw = x.getAllResponseHeaders().trim().split(/[\r\n]+/);
  for (var j = 0; j < raw.length; j++) {
    var kv = raw[j].split(': ');
    if (kv.length >= 2) { headers[kv[0].toLowerCase()] = kv.slice(1).join(': '); }
  }
  // 诊断：网络结果明细（CORS 拦截时 status=0、responseText 空）
  if (x.status === 0 || x.responseText.length === 0) {
    self.postMessage({ type: 'log', msg: 'XHR SUSPECT url=' + url.substring(0, 60) + ' status=' + x.status + ' len=' + x.responseText.length });
  }
  return { content: x.responseText, headers: headers, status: x.status };
}

// drpy2 期望的宿主 req：返回 {content, headers}
globalThis.req = function (url, obj) {
  var r = syncReq(url, obj);
  if (r.error) { throw new Error('req failed: ' + r.error); }
  return { content: r.content, headers: r.headers };
};

// 供 drpy2 顶层 `fetch = request` 覆盖前的占位（运行时注入后自行覆盖，无需宿主 fetch）

// ---------- 消息处理 ----------
var inited = false;

self.onmessage = function (ev) {
  var m = ev.data;
  if (m.type === 'init') {
    try {
      // 注入 drpy2 运行时（ES module 的 export default 兼容替换为 globalThis.__DRPY）
      var drpyCode = m.drpy2Code.replace('export default', 'globalThis.__DRPY =');
      // drpy2 内部引用的宿主符号兜底
      self.eval(drpyCode);
      if (m.extCode) { self.eval(m.extCode); }  // 插件 var rule = {...} → Worker 作用域 rule
      var drpy = globalThis.__DRPY;
      if (!drpy) { throw new Error('drpy 运行时注入失败（无 __DRPY）'); }
      drpy.init(m.cfgJson);
      inited = true;
      self.postMessage({ type: 'log', msg: 'init ok' });
    } catch (e) {
      self.postMessage({ type: 'log', msg: 'init ERR: ' + String(e) });
      self.postMessage({ type: 'result', id: m.callId, value: JSON.stringify({ __error: 'init: ' + String(e) }) });
    }
    return;
  }
  if (m.type === 'call') {
    if (!inited) {
      self.postMessage({ type: 'result', id: m.id, value: JSON.stringify({ __error: 'drpy 未就绪' }) });
      return;
    }
    (async function () {
      try {
        var fn = globalThis.__DRPY[m.method];
        if (typeof fn !== 'function') { throw new Error('未知方法: ' + m.method); }
        var r = await fn.apply(null, m.args);
        var out = typeof r === 'string' ? r : JSON.stringify(r);
        self.postMessage({ type: 'result', id: m.id, value: out === undefined ? '' : out });
      } catch (e) {
        self.postMessage({ type: 'result', id: m.id, value: JSON.stringify({ __error: String(e) }) });
      }
    })();
    return;
  }
};
