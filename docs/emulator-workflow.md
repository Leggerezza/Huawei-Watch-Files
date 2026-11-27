# Emulator workflow

The physical watch is often asleep or disconnected. A HarmonyOS emulator with a **wearable** image gives the same device type and the same API level (23) on this machine, so stages 2+ can be developed and regression-tested without the watch.

## What is installed

- Emulator CLI: `D:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe`
- Image: `HarmonyOS 6.1.0(23)`, deviceType `Wearable`, ~934 MB, downloaded with
  `Emulator.exe -install -deviceType Wearable -osVersion "HarmonyOS 6.1.0(23)" -force`
  (the license must be accepted once: `Emulator.exe -license accept`)
- Instance: `watch_dev`, screen 466x466 - identical to the watch

## Lifecycle

```powershell
$emu = 'D:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe'

# create (names allow letters, digits, spaces, underscore and '+'; no hyphen)
& $emu -create watch_dev -deviceType Wearable -osVersion "HarmonyOS 6.1.0(23)"

# boot headless on a fixed hdc port; cold boot takes ~40 s
& $emu -start watch_dev -noWindow -hdcPort 10001 -bootMode coldboot

# the device then appears to hdc
hdc list targets -v      # 127.0.0.1:10001  TCP  Connected

# stop
& $emu -stop watch_dev
```

## Install and run

```powershell
hdc -t 127.0.0.1:10001 install -r entry\build\default\outputs\default\entry-default-signed.hap
hdc -t 127.0.0.1:10001 shell "aa start -a EntryAbility -b io.github.leggerezza.files"
```

The normal debug-signed HAP installs without registering the emulator's UDID, so no extra signing step is needed.

## Reaching the servers from the PC

The app listens inside the emulator's NAT, so ports must be forwarded:

```powershell
hdc -t 127.0.0.1:10001 fport tcp:34069 tcp:34069   # FTP control
hdc -t 127.0.0.1:10001 fport tcp:45800 tcp:45800   # HTTP
```

**FTP needs more than that**: `PASV` opens a fresh ephemeral data port per transfer, and each one has to be forwarded too. `Test-Ftp-Suite.ps1 -HdcDevice 127.0.0.1:10001` does it automatically, forwarding before connect and removing the rule immediately after the transfer - hdc stops accepting new forwards once a couple of dozen accumulate, which is exactly how a suite of thirty transfers fails halfway.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-Ftp-Suite.ps1 -WatchIp 127.0.0.1 -Port 34069 `
    -User <u> -Pass <p> -LargeMb 8 -HdcDevice 127.0.0.1:10001
powershell -ExecutionPolicy Bypass -File .\Test-Http.ps1 -WatchIp 127.0.0.1 -Port 45800 -Code <code>
```

Both suites pass this way: FTP 65/65, HTTP 22/22.

## Seeing and driving the screen

```powershell
# screenshot (the requested path is ignored unless the directory exists; the
# file lands in F:\User\Pictures by default)
& $emu -instance watch_dev -screenshot -screenshotPath F:\User\Pictures

# widget tree, clicks, swipes, text input - the automation channel stage 2 needs
& $emu -instance watch_dev -uiLayout -i
& $emu -instance watch_dev -click "100 200"
& $emu -instance watch_dev -slide "100 up"
& $emu -instance watch_dev -fill "<widgetId> text"
```

`-uiLayout` writes `<instance>/uiLayout/analysis.md`; combine it with `-i` to keep only interactive widgets.

## Differences from the watch that matter

| Item | Emulator | Watch |
| --- | --- | --- |
| IP inside the app | `10.0.2.15` (NAT) | real LAN address |
| Continuous tasks | rejected: `9800005 ... The bgMode is invalid` | same |
| Notifications | `isNotificationEnabled()` false by default | user-controlled |
| Storage | 6 GB data partition | ~13.5 GB total |
| Performance | x86 host CPU, not representative | ARM, throttled |

Performance numbers measured on the emulator say nothing about the watch. Protocol behaviour and UI layout do transfer.
