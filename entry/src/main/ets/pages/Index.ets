import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import avSession from '@ohos.multimedia.avsession';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';
import { Log } from '../common/Logger';
import { listMedia, isVideo, isAudio, extOf, humanMs, copyByFd } from '../common/MediaLib';

const BUNDLE: string = 'com.local.media';
const ABILITY: string = 'EntryAbility';

@Entry
@Component
struct Index {
  @State files: string[] = [];
  @State selected: string = '';
  @State playState: string = 'idle';
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State bgInfo: string = '';
  @State busy: boolean = false;
  @State videoCount: number = 0;

  private player: media.AVPlayer | null = null;
  private playFd: number = -1;
  private timer: number = -1;
  private session: avSession.AVSession | null = null;
  private bgStarted: boolean = false;

  aboutToAppear(): void {
    this.refreshFiles();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private mediaDir(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return ctx.filesDir + '/media';
  }

  private refreshFiles(): void {
    const all: string[] = listMedia(this.mediaDir());
    this.files = all.filter((n: string) => isAudio(n));
    this.videoCount = all.length - this.files.length;
  }

  private startTimer(): void {
    this.stopTimer();
    this.timer = setInterval(() => {
      const p = this.player;
      if (p === null) {
        return;
      }
      this.playState = p.state;
      this.positionMs = p.currentTime;
      if (p.duration > 0) {
        this.durationMs = p.duration;
      }
    }, 500);
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private closePlayer(): void {
    this.stopTimer();
    if (this.player !== null) {
      try {
        this.player.release();
      } catch (e) {
        Log.warn('release failed');
      }
      this.player = null;
    }
    if (this.playFd >= 0) {
      try {
        fs.closeSync(this.playFd);
      } catch (e) {
        Log.warn('close fd failed');
      }
      this.playFd = -1;
    }
    this.positionMs = 0;
    this.durationMs = 0;
    this.playState = 'idle';
  }

  private async ensureSession(): Promise<void> {
    if (this.session !== null) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const s: avSession.AVSession = await avSession.createAVSession(ctx, 'media-player', 'audio');
      this.session = s;
      await s.setAVMetadata({ assetId: this.selected, title: this.selected, artist: '本地媒体', duration: this.durationMs });
      await s.activate();
    } catch (e) {
      const err = e as BusinessError;
      Log.warn('avsession failed code=' + err.code + ' ' + err.message);
    }
  }

  private async ensureBackground(): Promise<void> {
    if (this.bgStarted) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const want: Want = { bundleName: BUNDLE, abilityName: ABILITY };
      const info: wantAgent.WantAgentInfo = {
        wants: [want],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.bgStarted = true;
      this.bgInfo = '后台播放中';
    } catch (e) {
      const err = e as BusinessError;
      this.bgInfo = '后台失败(' + err.code + ')';
    }
  }

  private async stopBackground(): Promise<void> {
    if (!this.bgStarted) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (e) {
      Log.warn('stop background failed');
    }
    this.bgStarted = false;
    this.bgInfo = '';
  }

  private async loadAndPlay(name: string): Promise<void> {
    this.busy = true;
    this.closePlayer();
    this.selected = name;
    const path = this.mediaDir() + '/' + name;
    try {
      this.playFd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      const p: media.AVPlayer = await media.createAVPlayer();
      this.player = p;
      p.on('stateChange', (state: string) => {
        this.playState = state;
        if (state === 'completed') {
          this.next();
        }
      });
      p.on('error', (err: BusinessError) => {
        this.playState = 'error';
        Log.warn('player error ' + err.code + ' ' + err.message);
      });
      p.on('timeUpdate', (t: number) => {
        this.positionMs = t;
      });
      p.fdSrc = { fd: this.playFd };
      const ready: boolean = await this.waitInitialized(p);
      if (!ready) {
        throw new Error('player not initialized');
      }
      if (isVideo(name)) {
        this.playState = 'video-unsupported';
        Log.info('video deferred to M3: ' + name);
        return;
      }
      await p.prepare();
      this.durationMs = p.duration;
      await this.ensureSession();
      await p.play();
      await this.ensureBackground();
      this.startTimer();
    } catch (e) {
      const err = e as BusinessError;
      this.playState = 'error';
      Log.warn('load failed ' + name + ' code=' + err.code + ' ' + err.message);
    }
    this.busy = false;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async waitInitialized(p: media.AVPlayer): Promise<boolean> {
    const start: number = Date.now();
    while (Date.now() - start < 5000) {
      if (p.state === 'initialized') {
        return true;
      }
      if (p.state === 'error') {
        return false;
      }
      await this.delay(50);
    }
    return false;
  }

  private async toggle(): Promise<void> {
    const p = this.player;
    if (p === null) {
      if (this.selected.length > 0) {
        await this.loadAndPlay(this.selected);
      } else if (this.files.length > 0) {
        await this.loadAndPlay(this.files[0]);
      }
      return;
    }
    try {
      if (p.state === 'playing') {
        await p.pause();
        this.stopTimer();
      } else {
        if (p.state === 'completed' || p.state === 'stopped') {
          await p.seek(0);
        }
        await this.ensureSession();
        await p.play();
        await this.ensureBackground();
        this.startTimer();
      }
    } catch (e) {
      Log.warn('toggle failed');
    }
  }

  private async seekTo(ms: number): Promise<void> {
    const p = this.player;
    if (p === null) {
      return;
    }
    try {
      await p.seek(Math.floor(ms));
      this.positionMs = ms;
    } catch (e) {
      Log.warn('seek failed');
    }
  }

  private indexOfSelected(): number {
    for (let i = 0; i < this.files.length; i++) {
      if (this.files[i] === this.selected) {
        return i;
      }
    }
    return -1;
  }

  private async next(): Promise<void> {
    if (this.files.length === 0) {
      return;
    }
    const i = this.indexOfSelected();
    const n = i < 0 ? 0 : (i + 1) % this.files.length;
    await this.loadAndPlay(this.files[n]);
  }

  private async prev(): Promise<void> {
    if (this.files.length === 0) {
      return;
    }
    const i = this.indexOfSelected();
    const n = i <= 0 ? this.files.length - 1 : i - 1;
    await this.loadAndPlay(this.files[n]);
  }

  private async importFiles(): Promise<void> {
    try {
      const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 10;
      opts.fileSuffixFilters = ['.wav', '.mp3', '.m4a', '.flac', '.ogg', '.opus', '.aac', '.mp4', '.mkv', '.ts'];
      const vp: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await vp.select(opts);
      const dir = this.mediaDir();
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const segs = uri.split('/');
        let name = segs[segs.length - 1];
        if (name.length === 0) {
          name = 'picked_' + i;
        }
        const dst = dir + '/' + name;
        try {
          copyByFd(uri, dst);
        } catch (e) {
          try {
            fs.copyFileSync(uri, dst);
          } catch (e2) {
            Log.warn('import failed ' + name);
          }
        }
      }
      this.refreshFiles();
    } catch (e) {
      Log.info('picker cancelled');
    }
  }

  private isAudioOnly(name: string): boolean {
    return !isVideo(name);
  }

  build() {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text('媒体')
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor('#F3F7FF')
          Text('本地音乐 · 后台播放')
            .fontSize(12)
            .fontColor('#7E8FA8')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('导入')
          .fontSize(13)
          .height(34)
          .backgroundColor('#223047')
          .fontColor('#DCE7F7')
          .margin({ right: 8 })
          .onClick(() => {
            this.importFiles();
          })
        Button('刷新')
          .fontSize(13)
          .height(34)
          .backgroundColor('#223047')
          .fontColor('#DCE7F7')
          .onClick(() => {
            this.refreshFiles();
          })
      }
      .width('100%')

      Column({ space: 8 }) {
        Text(this.selected.length > 0 ? this.selected : '未选择曲目')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF1FB')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          Text(humanMs(this.positionMs))
            .fontSize(11)
            .fontColor('#8FA3BD')
          Slider({
            value: this.positionMs,
            min: 0,
            max: this.durationMs > 0 ? this.durationMs : 1,
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .onChange((value: number) => {
              this.seekTo(value);
            })
          Text(humanMs(this.durationMs))
            .fontSize(11)
            .fontColor('#8FA3BD')
        }
        .width('100%')

        Row({ space: 18 }) {
          Button('⏮')
            .fontSize(20)
            .width(64)
            .height(44)
            .backgroundColor('#1B2534')
            .fontColor('#DCE7F7')
            .onClick(() => {
              this.prev();
            })
          Button(this.playState === 'playing' ? '⏸' : '▶')
            .fontSize(22)
            .width(84)
            .height(48)
            .backgroundColor('#3D7BFF')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.toggle();
            })
          Button('⏭')
            .fontSize(20)
            .width(64)
            .height(44)
            .backgroundColor('#1B2534')
            .fontColor('#DCE7F7')
            .onClick(() => {
              this.next();
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)

        Text(this.playState + (this.bgInfo.length > 0 ? ' · ' + this.bgInfo : ''))
          .fontSize(11)
          .fontColor('#7E8FA8')
      }
      .width('100%')
      .padding(14)
      .margin({ top: 14 })
      .backgroundColor('#141A23')
      .borderRadius(14)

      Row() {
        Text('媒体库')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#DCE7F7')
          .layoutWeight(1)
        Text(this.files.length + ' 个文件')
          .fontSize(11)
          .fontColor('#7E8FA8')
      }
      .width('100%')
      .margin({ top: 16, bottom: 6 })

      List({ space: 4 }) {
        ForEach(this.files, (name: string) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(extOf(name).toUpperCase())
                .fontSize(10)
                .fontColor('#93B4FF')
                .width(46)
              Text(name)
                .fontSize(13)
                .fontColor(name === this.selected ? '#FFFFFF' : '#D5E0EF')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.isAudioOnly(name) ? 'audio' : 'video')
                .fontSize(10)
                .fontColor('#6E8098')
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 10, bottom: 10 })
            .backgroundColor(name === this.selected ? '#1E2B40' : '#111720')
            .borderRadius(10)
            .onClick(() => {
              this.loadAndPlay(name);
            })
          }
        }, (name: string) => name)
      }
      .width('100%')
      .layoutWeight(1)

      Text('支持 wav/mp3/m4a/flac/ogg/opus' + (this.videoCount > 0 ? ('；已隐藏 ' + this.videoCount + ' 个视频（M3 支持）') : ''))
        .fontSize(10)
        .fontColor('#5E6E85')
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 18, bottom: 12 })
    .backgroundColor('#0B0F16')
  }
}
