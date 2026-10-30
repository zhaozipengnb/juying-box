import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { ConfigStore } from '../state/ConfigStore';
import { PreferencesKVStore } from '../state/PreferencesKVStore';
import { AppState } from '../state/AppState';
import { AppSettings } from '../state/AppSettings';
import { SearchHistory } from '../state/SearchHistory';
import { UrlHistory } from '../state/UrlHistory';
import { PlayHistory } from '../state/PlayHistory';
import { Favorites } from '../state/Favorites';
import { DownloadManager } from '../state/DownloadManager';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 装配持久化：preferences 就绪后从存储恢复配置（loadContent 先行渲染 initing 态，不阻塞首帧）
    const context = this.context.getApplicationContext();
    // 个性化设置独立持久化（okvideo_settings），装载失败不影响订阅链路
    preferences.getPreferences(context, 'okvideo_settings').then((prefS: preferences.Preferences) => {
      AppSettings.instance.attach(new PreferencesKVStore(prefS));
      SearchHistory.instance.attach(new PreferencesKVStore(prefS));
    UrlHistory.instance.attach(new PreferencesKVStore(prefS));
      PlayHistory.instance.attach(new PreferencesKVStore(prefS));
      Favorites.instance.attach(new PreferencesKVStore(prefS));
      DownloadManager.instance.attach(this.context, new PreferencesKVStore(prefS));
    }).catch((eS: Object) => {
      hilog.error(DOMAIN, 'testTag', 'settings 装配异常: %{public}s', eS instanceof Error ? eS.message : JSON.stringify(eS));
    });
    preferences.getPreferences(context, 'okvideo_config').then(async (pref: preferences.Preferences) => {
      const store = new ConfigStore(new PreferencesKVStore(pref));
      // 恢复订阅并合并已导入的聚合源包（initFromStore 内部装载源包）
      return AppState.instance.initFromStore(store);
    }).catch((e: Object) => {
      // 装配失败兜底：preferences 打开或恢复链路异常时降级到配置页，用户可重新输入订阅
      hilog.error(DOMAIN, 'testTag', '装配链路异常: %{public}s', e instanceof Error ? e.message : JSON.stringify(e));
      AppState.instance.phase = 'home';
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
