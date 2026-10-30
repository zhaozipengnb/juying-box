// TimeUtil 单元测试：formatDuration 各时长/非法输入分支
import { describe, it, expect } from '@ohos/hypium';
import { formatDuration } from 'common';

export default function timeUtilTest() {
  describe('timeUtilTest', () => {
    it('formatDuration_basics', 0, () => {
      expect(formatDuration(0) === '00:00').assertTrue();
      expect(formatDuration(59) === '00:59').assertTrue();
      expect(formatDuration(60) === '01:00').assertTrue();
      expect(formatDuration(3661) === '1:01:01').assertTrue();
    });
    it('formatDuration_invalid_inputs', 0, () => {
      expect(formatDuration(NaN) === '00:00').assertTrue();
      expect(formatDuration(-5) === '00:00').assertTrue();
    });
  });
}
