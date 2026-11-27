import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Continuous-task diagnostics.
 *
 * `DATA_TRANSFER` fails on this watch with 9800005 (verification failed). The
 * SDK does not say which check failed, so the only way to learn whether it is
 * the mode, the notification, or the product is to ask the system one mode at a
 * time and log the answer for each.
 *
 * Each successful request is stopped immediately, so nothing is left running.
 * Runs once per launch; flip PROBE to false when the question is answered.
 */
const PROBE: boolean = true;

export async function probeBackgroundModes(ctx: common.UIAbilityContext): Promise<void> {
  if (!PROBE) {
    return;
  }
  let enabled: boolean = false;
  try {
    enabled = await notificationManager.isNotificationEnabled();
  } catch (e) {
    enabled = false;
  }
  hilog.info(0x0100, 'WatchBg', 'notifications enabled: %{public}s', `${enabled}`);

  const modes: backgroundTaskManager.BackgroundMode[] = [
    backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
    backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION,
    backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION,
    backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK
  ];
  const names: string[] = ['DATA_TRANSFER', 'MULTI_DEVICE_CONNECTION', 'BLUETOOTH_INTERACTION', 'AUDIO_PLAYBACK'];

  for (let i = 0; i < modes.length; i++) {
    const info: wantAgent.WantAgentInfo = {
      wants: [{
        bundleName: ctx.abilityInfo.bundleName,
        abilityName: ctx.abilityInfo.name
      }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 100 + i,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    try {
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(ctx, modes[i], agent);
      hilog.info(0x0100, 'WatchBg', '%{public}s: GRANTED', names[i]);
      try {
        await backgroundTaskManager.stopBackgroundRunning(ctx);
      } catch (e) {
        hilog.warn(0x0100, 'WatchBg', '%{public}s: granted but stop failed', names[i]);
      }
    } catch (e) {
      const be: BusinessError = e as BusinessError;
      const detail: string = be !== undefined && be.code !== undefined ? `code=${be.code} ${be.message}` : `${e}`;
      hilog.info(0x0100, 'WatchBg', '%{public}s: %{public}s', names[i], detail);
    }
  }
  hilog.info(0x0100, 'WatchBg', 'probe finished');
}
