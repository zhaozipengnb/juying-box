// 类型归一工具：TVBox/CMS 响应字段宽松取值（string/number/boolean/undefined → 强类型）。
// 注：首参为 Object|undefined 而非 string|number|boolean|undefined，
// 因 Record<string, Object> 的索引访问返回 Object，原联合类型无法直接接收（ArkTS 严格模式）；
// 放宽后对所有调用方向后兼容，运行时行为与计划一致。
export function toInt(v: Object | undefined, def: number): number {
  if (typeof v === 'number') {
    return Math.floor(v as number);
  }
  if (typeof v === 'string') {
    const n = Number(v);
    if (!Number.isNaN(n)) {
      return Math.floor(n);
    }
  }
  return def;
}

export function toStr(v: Object | undefined, def: string): string {
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return String(v);
  }
  return def;
}
