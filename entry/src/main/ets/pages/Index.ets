import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import picker from '@ohos.file.picker';
import avSession from '@ohos.multimedia.avsession';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hevcdec from 'libhevcdec.so';
import { BusinessError } from '@ohos.base';
import { Log } from '../common/Logger';
import { listMedia, isVideo, isAudio, extOf, humanMs, copyByFd } from '../common/MediaLib';

const BUNDLE: string = 'com.local.media';
const ABILITY: string = 'EntryAbility';

interface SoftInfo {
  width: number;
  height: number;
  fps: number;
  durationMs: number;
  frames: number;
}

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
  @State isVideoMode: boolean = false;
  @State fullscreen: boolean = false;
  @State boxW: number = 0;
  @State boxH: number = 0;
  private videoW: number = 0;
  private videoH: number = 0;
  private xc: XComponentController = new XComponentController();
  @State softMode: boolean = false;
  @State softPixel: image.PixelMap | null = null;
  private softTimer: number = -1;
  private softW: number = 0;
  private softH: number = 0;
  private softBusy: boolean = false;
  private softTicks: number = 0;
  private softStart: number = 0;

  private player: media.AVPlayer | null = null;
  private playFd: number = -1;
  private timer: number = -1;
  private session: avSession.AVSession | null = null;
  private bgStarted: boolean = false;

  aboutToAppear(): void {
    try {
      Log.info('hevc module v=' + hevcdec.version());
      this.refreshFiles();
    } catch (e) {
      Log.warn('hevc module load failed');
    }
  }

  private mediaDir(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return ctx.filesDir + '/media';
  }

  private refreshFiles(): void {
    const d: string = this.mediaDir();
    this.files = listMedia(d);
    this.videoCount = 0;
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

  private startSoftTimer(): void {
    this.stopSoftTimer();
    this.softTimer = setInterval(() => {
      if (!this.softMode || this.player === null || this.softW <= 0 || this.softBusy) {
        return;
      }
      try {
        const buf: ArrayBuffer | null = hevcdec.frameAt(this.positionMs) as ArrayBuffer | null;
        if (buf === null) {
          return;
        }
        const opt: image.InitializationOptions = {
          size: { width: this.softW, height: this.softH },
          pixelFormat: image.PixelMapFormat.RGBA_8888,
          editable: false
        };
        this.softBusy = true;
        image.createPixelMap(buf, opt).then((pm: image.PixelMap) => {
          if (this.softPixel !== null) {
            this.softPixel.release();
          }
            this.softPixel = pm;
          this.softBusy = false;
          if (this.softTicks === 0) {
            this.softStart = Date.now();
          }
          this.softTicks++;
          if (this.softTicks % 25 === 0) {
            const dt = Date.now() - this.softStart;
            Log.info('soft render fps ~' + (dt > 0 ? (this.softTicks * 1000 / dt).toFixed(1) : '0'));
          }
        }).catch(() => {
          this.softBusy = false;
        });
      } catch (e) {
      }
    }, 80);
  }

  private stopSoftTimer(): void {
    if (this.softTimer >= 0) {
      clearInterval(this.softTimer);
      this.softTimer = -1;
    }
  }

  private closePlayer(): void {
    this.stopTimer();
    this.stopSoftTimer();
    try {
      hevcdec.close();
    } catch (e) {
    }
    this.softMode = false;
    if (this.softPixel !== null) {
      try {
        this.softPixel.release();
      } catch (e) {
      }
      this.softPixel = null;
    }
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

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private async waitSurface(timeoutMs: number): Promise<string> {
    const start: number = Date.now();
    while (Date.now() - start < timeoutMs) {
      const sid: string = this.xc.getXComponentSurfaceId();
      if (sid.length > 0) {
        return sid;
      }
      await this.delay(50);
    }
    return '';
  }

  private async setFullscreen(on: boolean): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const win: window.Window = await window.getLastWindow(ctx);
      await win.setPreferredOrientation(window.Orientation.PORTRAIT);
      await win.setWindowLayoutFullScreen(on);
      if (on) {
        await win.setWindowSystemBarEnable([]);
        win.setWindowBackgroundColor('#000000');
        const rect = win.getWindowProperties().windowRect;
        const sw = px2vp(rect.width);
        const sh = px2vp(rect.height);
        let w = sw;
        let h = sh;
        const vw = this.softMode ? this.softW : this.videoW;
        const vh = this.softMode ? this.softH : this.videoH;
        if (vw > 0 && vh > 0) {
          const ar = vw / vh;
          if (sw / sh > ar) {
            h = sh;
            w = sh * ar;
          } else {
            w = sw;
            h = sw / ar;
          }
        }
        this.boxW = w;
        this.boxH = h;
        await this.delay(200);
        if (!this.softMode) {
          this.xc.setXComponentSurfaceSize({ surfaceWidth: vp2px(w), surfaceHeight: vp2px(h) });
        }
        Log.info('fit box ' + Math.round(w) + 'x' + Math.round(h));
      } else {
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      }
      this.fullscreen = on;
    } catch (e) {
      Log.warn('fullscreen failed ' + JSON.stringify(e));
      this.fullscreen = on;
    }
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
          if (this.isAudioOnly(this.selected)) {
            this.next();
          } else if (this.softMode) {
            this.stopSoftTimer();
          }
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
      let soft: boolean = false;
      if (isVideo(name)) {
        try {
          const sf = fs.openSync(path, fs.OpenMode.READ_ONLY);
          const meta: string = hevcdec.openFd(sf.fd) as string;
          fs.closeSync(sf);
          if (meta.length > 1) {
            const mi: SoftInfo = JSON.parse(meta) as SoftInfo;
            soft = mi.width > 0 && mi.height > 0;
            if (soft) {
              this.softMode = true;
              this.softW = mi.width;
              this.softH = mi.height;
              Log.info('soft hevc ' + meta);
            }
          }
        } catch (e) {
          Log.warn('soft probe failed');
        }
        if (!soft) {
          hevcdec.close();
        }
        if (this.fullscreen) {
          await this.setFullscreen(false);
        }
        this.isVideoMode = true;
        if (!soft) {
          await this.delay(200);
          const sid: string = await this.waitSurface(4000);
          if (sid.length === 0) {
            throw new Error('no surface');
          }
          p.surfaceId = sid;
        }
      } else {
        hevcdec.close();
        this.softMode = false;
        if (this.fullscreen) {
          await this.setFullscreen(false);
        }
        this.isVideoMode = false;
      }
      await p.prepare();
      if (isVideo(name)) {
        p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
        if (this.softMode) {
          this.videoW = this.softW;
          this.videoH = this.softH;
        } else if (p.width > 0 && p.height > 0) {
          this.videoW = p.width;
          this.videoH = p.height;
        }
        Log.info('video size ' + this.videoW + 'x' + this.videoH);
      }
      this.durationMs = p.duration;
      await this.ensureSession();
      await p.play();
      await this.ensureBackground();
      this.startTimer();
      if (this.softMode) {
        this.startSoftTimer();
      }
    } catch (e) {
      const err = e as BusinessError;
      this.playState = 'error';
      Log.warn('load failed ' + name + ' code=' + err.code + ' ' + err.message);
    }
    this.busy = false;
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
      if (!this.fullscreen) {
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
      }

      if (this.isVideoMode) {
        Stack() {
          Stack({ alignContent: Alignment.TopEnd }) {
            if (this.softMode) {
              if (this.softPixel !== null) {
                Image(this.softPixel)
                  .width('100%')
                  .height('100%')
                  .objectFit(ImageFit.Contain)
                  .backgroundColor('#000000')
              } else {
                Column()
                  .width('100%')
                  .height('100%')
                  .backgroundColor('#000000')
              }
            } else {
              XComponent({ id: 'videoSurface', type: 'surface', controller: this.xc })
                .width('100%')
                .height('100%')
                .backgroundColor('#000000')
                .onLoad(() => {
                  Log.info('surface ready id=' + this.xc.getXComponentSurfaceId());
                })
            }
            if (this.softMode) {
              Text('HEVC 软解')
                .fontSize(10)
                .fontColor('#CFE0FF')
                .backgroundColor('#B3223047')
                .borderRadius(6)
                .padding({ left: 6, right: 6, top: 3, bottom: 3 })
                .margin({ left: 8, bottom: 8 })
                .align(Alignment.BottomStart)
            }
            Button(this.fullscreen ? '退出全屏' : '全屏')
              .fontSize(11)
              .height(34)
              .margin({ top: this.fullscreen ? 52 : 8, right: 8 })
              .backgroundColor('#B3223047')
              .onClick(() => {
                this.setFullscreen(!this.fullscreen);
              })
          }
          .width(this.fullscreen ? this.boxW : '100%')
          .height(this.fullscreen ? this.boxH : 220)
          .borderRadius(this.fullscreen ? 0 : 12)
          .clip(true)
        }
        .width('100%')
        .height(this.fullscreen ? '100%' : 220)
        .alignContent(Alignment.Center)
        .clip(true)
        .margin({ top: this.fullscreen ? 0 : 12 })
      }

      if (!this.fullscreen) {
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

      Text('支持音频与 H264；HEVC 走应用内软解（实验）')
        .fontSize(10)
        .fontColor('#5E6E85')
        .width('100%')
        .margin({ top: 6 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: this.fullscreen ? 0 : 16, right: this.fullscreen ? 0 : 16, top: this.fullscreen ? 0 : 18, bottom: this.fullscreen ? 0 : 12 })
    .backgroundColor('#0B0F16')
  }
}
