import media from '@ohos.multimedia.media';
import fs from '@ohos.file.fs';
import picker from '@ohos.file.picker';
import avSession from '@ohos.multimedia.avsession';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import Want from '@ohos.app.ability.Want';
import { BusinessError } from '@ohos.base';
import { Log } from '../common/Logger';
import { MatrixRow, listMedia, isVideo, extOf, humanMs, copyByFd } from '../common/MediaLib';

const BUNDLE: string = 'com.local.media';
const ABILITY: string = 'EntryAbility';
const DOMAIN_HELP: string = 'M0 media verification app';

@Entry
@Component
struct Index {
  @State files: string[] = [];
  @State logLines: string[] = [];
  @State rawfileNote: string = '';
  @State matrixRunning: boolean = false;
  @State selected: string = '';
  @State playState: string = 'idle';
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State bgInfo: string = 'bg: 未启动';
  @State surfaceInfo: string = 'surface: -';

  private player: media.AVPlayer | null = null;
  private playFd: number = -1;
  private posLogTimer: number = -1;
  private session: avSession.AVSession | null = null;
  private bgStarted: boolean = false;
  private playStartedAt: number = 0;
  private xc: XComponentController = new XComponentController();

  aboutToAppear(): void {
    this.loadRawfileNote();
    this.refreshFiles();
  }

  aboutToDisappear(): void {
    this.stopPositionLog();
  }

  private mediaDir(): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    return ctx.filesDir + '/media';
  }

  private appendLog(line: string): void {
    Log.info(line);
    const next = this.logLines.concat([line]);
    this.logLines = next.length > 300 ? next.slice(next.length - 300) : next;
  }

  private async loadRawfileNote(): Promise<void> {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const data = await ctx.resourceManager.getRawFileContent('README.txt');
      const text = util.TextDecoder.create('utf-8').decodeWithStream(data);
      const first = text.split('\n')[0];
      this.rawfileNote = 'rawfile/README.txt (' + data.length + 'B): ' + first;
      Log.info('rawfile note bytes=' + data.length);
    } catch (e) {
      const err = e as BusinessError;
      this.rawfileNote = 'rawfile 为空或读取失败: ' + err.message;
    }
  }

  private refreshFiles(): void {
    const dir = this.mediaDir();
    this.files = listMedia(dir);
    this.appendLog('scan ' + dir + ' -> ' + this.files.length + ' file(s)');
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
    let timer: number = -1;
    const guard = new Promise<T>((resolve, reject) => {
      timer = setTimeout(() => {
        reject(new Error('timeout(' + what + ')'));
      }, ms);
    });
    return Promise.race([p, guard]).then((v: T) => {
      clearTimeout(timer);
      return v;
    }).catch((e: Error) => {
      clearTimeout(timer);
      throw e as Error;
    });
  }

  private waitState(p: media.AVPlayer, target: string, timeoutMs: number): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let done = false;
      const timer = setTimeout(() => {
        if (!done) {
          done = true;
          resolve(false);
        }
      }, timeoutMs);
      p.on('stateChange', (state: string) => {
        if (!done && state === target) {
          done = true;
          clearTimeout(timer);
          resolve(true);
        }
      });
    });
  }

  private async waitSurface(timeoutMs: number): Promise<string> {
    const start = Date.now();
    while (Date.now() - start < timeoutMs) {
      const sid = this.xc.getXComponentSurfaceId();
      if (sid.length > 0) {
        return sid;
      }
      await this.delay(100);
    }
    return '';
  }

  private errText(row: MatrixRow): string {
    return 'code=' + row.errCode + ' msg=' + row.errMsg;
  }

  private async probeOne(dir: string, name: string, idx: number): Promise<MatrixRow> {
    const path = dir + '/' + name;
    const video = isVideo(name);
    const row: MatrixRow = {
      name: name, ok: false, durationMs: 0, positionMs: 0,
      errCode: 0, errMsg: '', note: video ? 'video' : 'audio'
    };
    let fd = -1;
    let p: media.AVPlayer | null = null;
    try {
      fd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      p = await media.createAVPlayer();
      p.on('error', (err: BusinessError) => {
        row.errCode = err.code;
        row.errMsg = err.message;
      });
      p.fdSrc = { fd: fd };
      if (video) {
        const sid = await this.waitSurface(3000);
        if (sid.length > 0) {
          p.surfaceId = sid;
          row.note = 'video+surface';
        } else {
          row.note = 'video,no-surface';
        }
      }
      const inited = await this.waitState(p, 'initialized', 4000);
      if (!inited) {
        if (row.errCode === 0) {
          row.errMsg = 'not initialized, state=' + p.state;
        }
        throw new Error('initialized failed');
      }
      await this.withTimeout(p.prepare(), 6000, 'prepare');
      row.durationMs = p.duration;
      await this.withTimeout(p.play(), 5000, 'play');
      await this.delay(2000);
      row.positionMs = p.currentTime;
      row.ok = true;
    } catch (e) {
      const err = e as BusinessError;
      if (row.errCode === 0) {
        row.errCode = err.code === undefined ? 0 : err.code;
      }
      if (row.errMsg.length === 0) {
        row.errMsg = err.message === undefined ? '' + e : err.message;
      }
    } finally {
      if (p !== null) {
        try {
          await p.release();
        } catch (e) {
          Log.warn('release failed: ' + JSON.stringify(e));
        }
      }
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          Log.warn('close fd failed');
        }
      }
    }
    const line = '#' + (idx + 1) + (row.ok ? ' [OK] ' : ' [FAIL] ') + name +
      ' dur=' + row.durationMs + 'ms pos=' + row.positionMs + 'ms ' + row.note +
      (row.ok ? '' : ' ' + this.errText(row));
    this.appendLog(line);
    return row;
  }

  private async runMatrix(): Promise<void> {
    if (this.matrixRunning) {
      return;
    }
    this.matrixRunning = true;
    this.logLines = [];
    const dir = this.mediaDir();
    const names = listMedia(dir);
    this.appendLog('MATRIX start files=' + names.length + ' dir=' + dir);
    let ok = 0;
    let bad = 0;
    for (let i = 0; i < names.length; i++) {
      const row = await this.probeOne(dir, names[i], i);
      if (row.ok) {
        ok++;
      } else {
        bad++;
      }
    }
    this.appendLog('MATRIX SUMMARY ok=' + ok + ' fail=' + bad + ' total=' + names.length);
    this.matrixRunning = false;
    this.refreshFiles();
  }

  private async importViaPicker(): Promise<void> {
    try {
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 10;
      opts.fileSuffixFilters = ['.wav', '.mp3', '.m4a', '.flac', '.ogg', '.opus', '.aac', '.mp4', '.mkv', '.ts'];
      const viewPicker = new picker.DocumentViewPicker();
      this.appendLog('picker: opening DocumentViewPicker ...');
      const uris = await viewPicker.select(opts);
      this.appendLog('picker: selected ' + uris.length + ' uri(s)');
      const dir = this.mediaDir();
      for (let i = 0; i < uris.length; i++) {
        const uri = uris[i];
        const segs = uri.split('/');
        let name = segs[segs.length - 1];
        if (name.length === 0) {
          name = 'picked_' + i;
        }
        const dst = dir + '/' + name;
        let srcFd = -1;
        try {
          srcFd = fs.openSync(uri, fs.OpenMode.READ_ONLY).fd;
          this.appendLog('picker: open ok fd=' + srcFd + ' uri=' + uri);
        } catch (e) {
          const err = e as BusinessError;
          this.appendLog('picker: open FAIL code=' + err.code + ' msg=' + err.message + ' uri=' + uri);
        }
        if (srcFd >= 0) {
          try {
            fs.closeSync(srcFd);
          } catch (e) {
            Log.warn('close picked fd failed');
          }
        }
        try {
          const n = copyByFd(uri, dst);
          this.appendLog('picker: copied ' + name + ' (' + n + 'B) <- ' + uri);
        } catch (e) {
          const err = e as BusinessError;
          this.appendLog('picker: fd-copy FAIL ' + name + ' code=' + err.code + ' msg=' + err.message);
          try {
            fs.copyFileSync(uri, dst);
            this.appendLog('picker: copyFileSync ok ' + name);
          } catch (e2) {
            const err2 = e2 as BusinessError;
            this.appendLog('picker: copyFileSync FAIL code=' + err2.code + ' msg=' + err2.message);
          }
        }
      }
      if (uris.length > 0) {
        await this.probeUri(uris[0]);
      }
      this.refreshFiles();
    } catch (e) {
      const err = e as BusinessError;
      this.appendLog('picker: cancelled/failed code=' + err.code + ' msg=' + err.message);
    }
  }

  private async probeUri(uri: string): Promise<void> {
    let p: media.AVPlayer | null = null;
    let code = 0;
    let msg = '';
    try {
      p = await media.createAVPlayer();
      p.on('error', (err: BusinessError) => {
        code = err.code;
        msg = err.message;
      });
      p.url = uri;
      const inited = await this.waitState(p, 'initialized', 4000);
      if (!inited) {
        throw new Error('not initialized state=' + p.state);
      }
      await this.withTimeout(p.prepare(), 6000, 'prepare');
      await this.withTimeout(p.play(), 5000, 'play');
      await this.delay(1500);
      this.appendLog('picker: URL-PLAY OK dur=' + p.duration + ' pos=' + p.currentTime + ' uri=' + uri);
    } catch (e) {
      const err = e as BusinessError;
      this.appendLog('picker: URL-PLAY FAIL code=' + (code !== 0 ? code : err.code) +
        ' msg=' + (msg.length > 0 ? msg : err.message) + ' uri=' + uri);
    } finally {
      if (p !== null) {
        try {
          await p.release();
        } catch (e) {
          Log.warn('probeUri release failed');
        }
      }
    }
  }

  private async closePlayer(): Promise<void> {
    this.stopPositionLog();
    if (this.player !== null) {
      try {
        await this.player.reset();
      } catch (e) {
        Log.warn('reset failed');
      }
      try {
        await this.player.release();
      } catch (e) {
        Log.warn('release failed');
      }
      this.player = null;
    }
    if (this.playFd >= 0) {
      try {
        fs.closeSync(this.playFd);
      } catch (e) {
        Log.warn('close play fd failed');
      }
      this.playFd = -1;
    }
    this.playState = 'idle';
    this.positionMs = 0;
    this.durationMs = 0;
  }

  private async loadFile(name: string): Promise<void> {
    const path = this.mediaDir() + '/' + name;
    await this.closePlayer();
    this.selected = name;
    try {
      this.playFd = fs.openSync(path, fs.OpenMode.READ_ONLY).fd;
      const p = await media.createAVPlayer();
      this.player = p;
      p.on('stateChange', (state: string, reason: number) => {
        this.playState = state;
        Log.info('state=' + state + ' reason=' + reason + ' file=' + name);
      });
      p.on('timeUpdate', (t: number) => {
        this.positionMs = t;
      });
      p.on('error', (err: BusinessError) => {
        this.playState = 'error';
        this.appendLog('PLAYER ERROR file=' + name + ' code=' + err.code + ' msg=' + err.message);
      });
      p.fdSrc = { fd: this.playFd };
      if (isVideo(name)) {
        const sid = await this.waitSurface(3000);
        if (sid.length > 0) {
          p.surfaceId = sid;
        }
      }
      const inited = await this.waitState(p, 'initialized', 5000);
      if (!inited) {
        throw new Error('not initialized before prepare, state=' + p.state);
      }
      this.playState = 'initialized';
      await this.withTimeout(p.prepare(), 8000, 'prepare');
      this.playState = 'prepared';
      p.loop = true;
      this.durationMs = p.duration;
      this.appendLog('loaded ' + name + ' dur=' + p.duration + 'ms fd=' + this.playFd +
        ' loop=' + p.loop);
    } catch (e) {
      const err = e as BusinessError;
      this.playState = 'error';
      this.appendLog('load FAIL ' + name + ' code=' + err.code + ' msg=' + err.message);
    }
  }

  private seekAsync(p: media.AVPlayer, ms: number): void {
    p.seek(ms);
  }

  private startPositionLog(): void {
    this.stopPositionLog();
    this.posLogTimer = setInterval(() => {
      const p = this.player;
      if (p === null) {
        return;
      }
      const pos = p.currentTime;
      const dur = p.duration;
      this.playState = p.state;
      this.positionMs = pos;
      const elapsed = this.playStartedAt > 0 ? Math.floor((Date.now() - this.playStartedAt) / 1000) : 0;
      this.appendLog('POSITION ' + this.selected + ' pos=' + pos + '/' + dur +
        ' elapsed=' + elapsed + 's state=' + p.state + ' bg=' + (this.bgStarted ? 'yes' : 'no'));
      if (p.state === 'completed') {
        p.seek(0);
        this.delay(200).then(() => {
          return p.play();
        }).then(() => {
          Log.info('loop restart after completed');
        }).catch((e: Error) => {
          Log.warn('loop restart failed: ' + e.message);
        });
      }
    }, 2000);
  }

  private stopPositionLog(): void {
    if (this.posLogTimer >= 0) {
      clearInterval(this.posLogTimer);
      this.posLogTimer = -1;
    }
  }

  private async ensureSession(): Promise<void> {
    if (this.session !== null) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const s = await avSession.createAVSession(ctx, 'media-m0-audio', 'audio');
      this.session = s;
      await s.setAVMetadata({ assetId: this.selected, title: this.selected, artist: 'local', duration: this.durationMs });
      await s.activate();
      this.appendLog('avsession: created+activated tag=media-m0-audio');
    } catch (e) {
      const err = e as BusinessError;
      this.appendLog('avsession FAIL code=' + err.code + ' msg=' + err.message);
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
      await backgroundTaskManager.startBackgroundRunning(
        ctx, backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      this.bgStarted = true;
      this.bgInfo = 'bg: RUNNING (AUDIO_PLAYBACK)';
      this.appendLog('backgroundTaskManager: startBackgroundRunning OK mode=AUDIO_PLAYBACK');
    } catch (e) {
      const err = e as BusinessError;
      this.bgInfo = 'bg: FAIL code=' + err.code;
      this.appendLog('backgroundTaskManager FAIL code=' + err.code + ' msg=' + err.message);
    }
  }

  private async stopBackground(): Promise<void> {
    if (!this.bgStarted) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
      this.appendLog('backgroundTaskManager: stopped');
    } catch (e) {
      const err = e as BusinessError;
      this.appendLog('stopBackgroundRunning FAIL code=' + err.code);
    }
    this.bgStarted = false;
    this.bgInfo = 'bg: stopped';
  }

  private async togglePlay(): Promise<void> {
    const p = this.player;
    if (p === null) {
      this.appendLog('togglePlay: no file loaded');
      return;
    }
    try {
      const st = p.state;
      this.appendLog('togglePlay: state=' + st);
      if (st === 'playing') {
        await p.pause();
        this.playState = 'paused';
        this.stopPositionLog();
        this.appendLog('paused at ' + p.currentTime + 'ms');
      } else {
        if (st === 'completed' || st === 'stopped') {
          await p.seek(0);
        }
        await this.ensureSession();
        await this.ensureBackground();
        await p.play();
        this.playStartedAt = Date.now();
        this.playState = 'playing';
        this.startPositionLog();
        this.appendLog('playing ' + this.selected + ' from ' + p.currentTime + 'ms');
      }
    } catch (e) {
      const err = e as BusinessError;
      this.appendLog('togglePlay FAIL code=' + err.code + ' msg=' + err.message);
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
      const err = e as BusinessError;
      this.appendLog('seek FAIL code=' + err.code);
    }
  }

  private async stopAll(): Promise<void> {
    await this.closePlayer();
    await this.stopBackground();
    if (this.session !== null) {
      try {
        await this.session.destroy();
      } catch (e) {
        Log.warn('session destroy failed');
      }
      this.session = null;
    }
    this.appendLog('stopped, resources released');
  }

  @Builder
  actionButton(label: string, bg: string, cb: () => void) {
    Button(label)
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .backgroundColor(bg)
      .fontColor('#0B1220')
      .height(44)
      .borderRadius(10)
      .margin({ right: 8 })
      .onClick(cb)
  }

  build() {
    Column() {
      Row() {
        Text('媒体 M0').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#F6F9FF')
        Blank()
        Text(this.matrixRunning ? '矩阵测试中...' : '就绪')
          .fontSize(13).fontColor(this.matrixRunning ? '#F2B45C' : '#6EE7B7')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 8 })

      Text(this.rawfileNote)
        .fontSize(10).fontColor('#8EA0BF').width('100%')
        .padding({ left: 16, right: 16 }).maxLines(2)

      Row() {
        this.actionButton('导入文件', '#57D3EA', () => {
          this.importViaPicker();
        })
        this.actionButton('刷新列表', '#8EA0BF', () => {
          this.refreshFiles();
        })
        this.actionButton('格式矩阵测试', '#F2B45C', () => {
          this.runMatrix();
        })
        this.actionButton('释放', '#FF7B7B', () => {
          this.stopAll();
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })

      Row() {
        Column() {
          Text('当前: ' + (this.selected.length > 0 ? this.selected : '-'))
            .fontSize(13).fontColor('#F6F9FF').width('100%').maxLines(1)
          Text(humanMs(this.positionMs) + ' / ' + humanMs(this.durationMs) + '  ' + this.playState + '  ' + this.bgInfo)
            .fontSize(11).fontColor('#8EA0BF').width('100%').maxLines(1)
          Slider({
            value: this.positionMs,
            min: 0,
            max: this.durationMs > 0 ? this.durationMs : 1,
            step: 1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.seekTo(value);
              }
            })
          Row() {
            Button(this.playState === 'playing' ? '暂停' : '播放')
              .fontSize(14).height(38).borderRadius(8)
              .backgroundColor('#6EE7B7').fontColor('#0B1220')
              .onClick(() => {
                this.togglePlay();
              })
            Text(' ' + this.surfaceInfo).fontSize(10).fontColor('#8EA0BF')
          }.width('100%')
        }
        .layoutWeight(1)

        XComponent({ id: 'videoSurface', type: 'surface', controller: this.xc })
          .width(112).height(84)
          .margin({ left: 8 })
          .onLoad(() => {
            this.surfaceInfo = 'surface: ready';
            Log.info('XComponent surface ready id=' + this.xc.getXComponentSurfaceId());
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 6 })

      Text('文件列表 (' + this.files.length + ')')
        .fontSize(12).fontColor('#8EA0BF').width('100%')
        .padding({ left: 16, top: 2 })

      List({ space: 4 }) {
        ForEach(this.files, (name: string) => {
          ListItem() {
            Row() {
              Text(extOf(name).toUpperCase())
                .fontSize(11).fontColor('#57D3EA').width(52)
              Text(name).fontSize(13).fontColor('#F6F9FF').layoutWeight(1).maxLines(1)
              Text(isVideo(name) ? 'video' : 'audio').fontSize(10).fontColor('#8EA0BF')
            }
            .width('100%').padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor(this.selected === name ? '#153B48' : '#121B2C')
            .borderRadius(8)
            .onClick(() => {
              this.loadFile(name);
            })
          }
        }, (name: string) => name)
      }
      .width('100%')
      .height(250)
      .padding({ left: 16, right: 16, top: 2, bottom: 4 })

      Text('日志 (hilog TAG MediaM0)')
        .fontSize(12).fontColor('#8EA0BF').width('100%')
        .padding({ left: 16, top: 2 })

      Scroll() {
        Column() {
          ForEach(this.logLines, (line: string, i: number) => {
            Text(line)
              .fontSize(10)
              .fontColor(line.indexOf('[FAIL]') >= 0 || line.indexOf('ERROR') >= 0 ? '#FF7B7B'
                : (line.indexOf('[OK]') >= 0 ? '#6EE7B7' : '#B8C6DE'))
              .width('100%')
              .margin({ bottom: 2 })
          }, (line: string, i: number) => '' + i + ':' + line)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 2, bottom: 8 })
      .backgroundColor('#0A111E')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#070C16')
  }
}
