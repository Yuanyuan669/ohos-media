import fs from '@ohos.file.fs';

export interface MatrixRow {
  name: string;
  ok: boolean;
  durationMs: number;
  positionMs: number;
  errCode: number;
  errMsg: string;
  note: string;
}

const VIDEO_EXT: string[] = ['mp4', 'mkv', 'ts', 'mov', 'webm', 'm4v'];
const AUDIO_EXT: string[] = ['wav', 'mp3', 'm4a', 'flac', 'ogg', 'opus', 'aac', 'amr'];

export function extOf(name: string): string {
  const i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

export function isVideo(name: string): boolean {
  return VIDEO_EXT.indexOf(extOf(name)) >= 0;
}

export function isAudio(name: string): boolean {
  return AUDIO_EXT.indexOf(extOf(name)) >= 0;
}

export function listMedia(dir: string): string[] {
  const out: string[] = [];
  try {
    if (!fs.accessSync(dir)) {
      return out;
    }
    const names = fs.listFileSync(dir);
    for (let i = 0; i < names.length; i++) {
      const full = dir + '/' + names[i];
      try {
        const st = fs.statSync(full);
        if (st.isFile()) {
          out.push(names[i]);
        }
      } catch (e) {
        // skip unreadable entry
      }
    }
  } catch (e) {
    // directory missing: empty list
  }
  out.sort();
  return out;
}

export function humanMs(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  const m = Math.floor(total / 60);
  const s = total % 60;
  return (m < 10 ? '0' + m : '' + m) + ':' + (s < 10 ? '0' + s : '' + s);
}

export function copyByFd(src: string, dst: string): number {
  const inFile = fs.openSync(src, fs.OpenMode.READ_ONLY);
  const outFile = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  let written = 0;
  try {
    const buf = new ArrayBuffer(64 * 1024);
    let read = 0;
    do {
      read = fs.readSync(inFile.fd, buf, { offset: written });
      if (read > 0) {
        fs.writeSync(outFile.fd, buf, { offset: written, length: read });
        written += read;
      }
    } while (read > 0);
  } finally {
    fs.closeSync(inFile);
    fs.closeSync(outFile);
  }
  return written;
}
