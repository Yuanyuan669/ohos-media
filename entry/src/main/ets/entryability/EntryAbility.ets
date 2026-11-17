import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import fs from '@ohos.file.fs';
import { Log } from '../common/Logger';

export const MEDIA_DIR_NAME = 'media';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Log.info('ability onCreate');
    this.ensureMediaDir();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index').catch((e: Error) => {
      Log.error('loadContent failed: ' + e.message);
    });
  }

  onForeground(): void {
    Log.info('ability foreground');
  }

  onBackground(): void {
    Log.info('ability background');
  }

  onDestroy(): void {
    Log.info('ability destroy');
  }

  private ensureMediaDir(): void {
    try {
      const dir = this.context.filesDir + '/' + MEDIA_DIR_NAME;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      Log.info('mediaDir ready: ' + dir);
    } catch (e) {
      Log.error('ensureMediaDir failed: ' + JSON.stringify(e));
    }
  }
}
