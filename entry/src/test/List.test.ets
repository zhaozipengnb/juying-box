import localUnitTest from './LocalUnit.test';
import modelTest from './Model.test';
import codingTest from './Coding.test';
import configDecoderTest from './ConfigDecoder.test';
import cmsJsonApiTest from './CmsJsonApi.test';
import configStoreTest from './ConfigStore.test';
import appStateTest from './AppState.test';
import appSettingsTest from './AppSettings.test';
import hlsAdFilterTest from './HlsAdFilter.test';
import liveSourceParserTest from './LiveSourceParser.test';
import drpyDriverTest from './DrpyDriver.test';
import xmlCmsDriverTest from './XmlCmsDriver.test';
import playUrlResolverTest from './PlayUrlResolver.test';
import idnTest from './Idn.test';

export default function testsuite() {
  localUnitTest();
  modelTest();
  codingTest();
  configDecoderTest();
  cmsJsonApiTest();
  configStoreTest();
  appStateTest();
  appSettingsTest();
  hlsAdFilterTest();
  liveSourceParserTest();
  drpyDriverTest();
  xmlCmsDriverTest();
  playUrlResolverTest();
  idnTest();
}
