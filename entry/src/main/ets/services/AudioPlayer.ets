import { media } from '@kit.MediaKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Thin wrapper around AVPlayer for local audio.
 *
 * The file is opened as an fd and handed over as `fdSrc`; the fd must stay open
 * for the whole playback, so it is owned here and closed on release. Playback
 * only lives while the app is in the foreground - this device refuses every
 * continuous-task mode, so there is no background audio by design.
 */
export class AudioPlayer {
  private player: media.AVPlayer | null = null;
  private file: fs.File | null = null;
  private prepared: boolean = false;

  onState: (state: string) => void = () => {
  };
  onTime: (positionMs: number, durationMs: number) => void = () => {
  };
  onError: (message: string) => void = () => {
  };
  onComplete: () => void = () => {
  };

  async open(realPath: string, size: number): Promise<void> {
    await this.release();
    try {
      this.file = fs.openSync(realPath, fs.OpenMode.READ_ONLY);
      const player: media.AVPlayer = await media.createAVPlayer();
      this.player = player;
      this.prepared = false;
      player.on('stateChange', (state: media.AVPlayerState) => {
        if (state === 'initialized') {
          player.prepare();
        } else if (state === 'prepared') {
          this.prepared = true;
          this.onState('prepared');
          this.onTime(player.currentTime, player.duration);
          player.play();
        } else if (state === 'playing') {
          this.onState('playing');
          this.onTime(player.currentTime, player.duration);
        } else if (state === 'paused') {
          this.onState('paused');
        } else if (state === 'completed') {
          this.onState('completed');
          this.onComplete();
        } else if (state === 'error') {
          this.onState('error');
        }
      });
      player.on('timeUpdate', (time: number) => {
        this.onTime(time, player.duration);
      });
      player.on('durationUpdate', (duration: number) => {
        this.onTime(player.currentTime, duration);
      });
      player.on('error', (err: BusinessError) => {
        hilog.warn(0x0100, 'WatchAudio', 'player error %{public}s', `${err.code} ${err.message}`);
        this.onError(`${err.code}`);
      });
      player.fdSrc = { fd: this.file.fd, offset: 0, length: size };
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(0x0100, 'WatchAudio', 'open failed %{public}s', `${err.code} ${err.message}`);
      this.onError(err.message !== undefined ? err.message : '无法打开');
      await this.release();
    }
  }

  async toggle(): Promise<void> {
    if (this.player === null || !this.prepared) {
      return;
    }
    if (this.player.state === 'playing') {
      await this.player.pause();
    } else if (this.player.state === 'paused' || this.player.state === 'completed') {
      await this.player.play();
    }
  }

  seekMs(positionMs: number): void {
    if (this.player !== null && this.prepared) {
      this.player.seek(Math.max(0, positionMs));
    }
  }

  async release(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    this.player = null;
    this.prepared = false;
    if (player !== null) {
      try {
        await player.release();
      } catch (e) {
      }
    }
    const file: fs.File | null = this.file;
    this.file = null;
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (e) {
      }
    }
  }
}

export function fmtClock(ms: number): string {
  if (ms <= 0) {
    return '0:00';
  }
  const total: number = Math.floor(ms / 1000);
  const m: number = Math.floor(total / 60);
  const s: number = total % 60;
  return `${m}:${`${s}`.padStart(2, '0')}`;
}
