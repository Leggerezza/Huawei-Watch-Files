# Continuous task findings (background execution)

The app currently asks for a `DATA_TRANSFER` continuous task and the watch answers `BusinessError 9800005 - Continuous task verification failed`. This note records what the SDK actually requires, read from `@ohos.resourceschedule.backgroundTaskManager.d.ts` (API 26 SDK), and what that means for a file server.

## What the platform requires

From the API docs for `startBackgroundRunning(context, bgMode, wantAgent)`:

| Requirement | Detail |
| --- | --- |
| Permission | `ohos.permission.KEEP_BACKGROUND_RUNNING` (we declare it) |
| Caller | stage-model `UIAbility` only (we are) |
| Notification | the task is announced by a notification without a sound; the want agent decides where tapping it goes |
| One task per ability | until the newer API-21 `ContinuousTaskRequest` form; we use the single-task form |

`BackgroundMode.DATA_TRANSFER = 1`, and the enum documentation adds two requirements that matter more than the error code:

> During data transfer, the application needs to update the progress. If the progress is not updated for more than **10 minutes**, the continuous task of the **DATA_TRANSFER** type will be **canceled**. The notification type of the progress update must be **live view**.

So even if the task were granted, our current code would lose it after ten minutes of no progress updates, because we never call `updateBackgroundRunning`.

Error codes the same call can raise: `201` permission, `9800001` memory, `9800002` parcel, `9800003` internal, `9800004` service, `9800005` verification, `9800006` notification verification, `9800007` storage. We get `9800005`, the generic verification failure, not `9800006` (notification) — so the refusal happens before or independently of the notification path.

## Hypotheses, in order of likelihood

1. **The wearable product does not grant DATA_TRANSFER to third-party apps.** Continuous-task availability is a product policy, not only an API question. A watch that never runs browser downloads has little reason to allow it.
2. **Our want agent is not acceptable.** We build it from `ctx.abilityInfo.bundleName` / `.name`. If the verifier wants a `START_ABILITY` agent whose ability is the same UIAbility *and* exported, a mismatch would surface as a generic verification failure.
3. **Notification enablement.** If the app has never been granted notification permission, some builds fail with 9800006, but a stricter build could fold that into 9800005.
4. **DATA_TRANSFER specifically.** The mode might be rejected while other modes (e.g. `MULTI_DEVICE_CONNECTION` or `BLUETOOTH_INTERACTION`) are allowed.

## Diagnostic plan (needs a device or the wearable emulator)

Run these on a build that logs each result, in one start:

```ts
for (const mode of [BackgroundMode.DATA_TRANSFER, BackgroundMode.MULTI_DEVICE_CONNECTION,
                    BackgroundMode.BLUETOOTH_INTERACTION, BackgroundMode.AUDIO_PLAYBACK]) {
  try {
    await backgroundTaskManager.startBackgroundRunning(ctx, mode, agent);
    log(`mode ${mode}: granted`);
    await backgroundTaskManager.stopBackgroundRunning(ctx);
  } catch (e) {
    log(`mode ${mode}: ${e.code} ${e.message}`);
  }
}
```

Outcomes and what they mean:

- all four fail with 9800005 → the product blocks continuous tasks for this app; stop trying, document it;
- only DATA_TRANSFER fails → mode policy; pick an allowed mode only if it is honest (a file server is not "multi-device connection");
- all succeed after the app has been launched once from the watch face and notifications enabled → the earlier failure was an ordering/permission issue, and the fix is to request notification enablement first.

Also worth measuring: `notificationManager.isNotificationEnabled()` before the call, and `requestEnableNotification()` once.

## If a task is granted

`DATA_TRANSFER` then requires progress upkeep, so the design would be:

- on every transfer start/progress/eend, call `updateBackgroundRunning` with the current byte count (or the newer `ContinuousTaskRequest` with progress fields, API 21+);
- a timer that pushes a keep-alive progress update at least every 9 minutes while any FTP/HTTP connection is open;
- stop the task when the last connection closes, so the watch does not show a permanent notification for an idle server.

That is real work, and it only makes sense **after** a mode is proven grantable. Until then the honest position is: transfers happen while the page is on screen.

## Current status

- FAIL on the watch (`9800005`), reproduced twice on different builds.
- Not yet tried: other modes, notification enablement first, API-21 `ContinuousTaskRequest`.
- The wearable emulator image `HarmonyOS 6.1.0(23)` exists in the SDK's image list and is being downloaded so the same diagnostic can run without the physical watch.
