import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Keeps the display awake while a reader or viewer is open.
 *
 * `window.setWindowKeepScreenOn(true)` is available to normal apps - the SDK
 * only asks that it be used "in necessary scenarios (navigation, video playback,
 * drawing, ...)". A reading page qualifies; a file list does not, so this is
 * reference counted and only held while a full-screen media page is visible.
 *
 * There is no API to *postpone* the screen-off timeout, and none to wake a
 * sleeping device; this is the whole capability.
 */
let refCount: number = 0;
let current: window.Window | null = null;

export async function acquireScreen(ctx: common.UIAbilityContext): Promise<void> {
  refCount += 1;
  if (refCount > 1) {
    return;
  }
  try {
    current = await window.getLastWindow(ctx);
    await current.setWindowKeepScreenOn(true);
    hilog.info(0x0100, 'WatchScreen', 'keep screen on: true');
  } catch (e) {
    hilog.warn(0x0100, 'WatchScreen', 'keep screen on failed: %{public}s', `${(e as Error).message}`);
  }
}

export async function releaseScreen(): Promise<void> {
  refCount = Math.max(0, refCount - 1);
  if (refCount > 0) {
    return;
  }
  try {
    if (current !== null) {
      await current.setWindowKeepScreenOn(false);
      hilog.info(0x0100, 'WatchScreen', 'keep screen on: false');
    }
  } catch (e) {
  }
  current = null;
}
