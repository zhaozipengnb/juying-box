import localUnitTest from './LocalUnit.test';
import modelTest from './Model.test';
import codingTest from './Coding.test';
import configDecoderTest from './ConfigDecoder.test';
import cmsJsonApiTest from './CmsJsonApi.test';
import configStoreTest from './ConfigStore.test';

export default function testsuite() {
  localUnitTest();
  modelTest();
  codingTest();
  configDecoderTest();
  cmsJsonApiTest();
  configStoreTest();
}
