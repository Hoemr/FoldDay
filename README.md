# FoldDay · 折昼

**Keep your MacBook awake with the lid closed and the built-in backlight off.**

FoldDay is a native macOS menu bar app for unattended tasks and computer-use agents. When the lid is open, selected Bluetooth devices can lock your Mac as you leave and unlock your session when you return.

[Build & install](#install) · [Quick start](#quick-start) · [简体中文](README.zh-CN.md)

<img src="docs/settings.png" alt="FoldDay settings showing battery-powered clamshell keep-awake and per-device Bluetooth signal strength" width="880">

The preview shows sample devices and signal readings.

## What FoldDay does

- **Closed-lid keep-awake.** Keep macOS running on battery with the built-in backlight at zero. Reopening the lid restores its prior brightness. FoldDay is designed for use without an external display.
- **Bluetooth proximity lock and unlock.** Add BLE devices in FoldDay, see each device’s RSSI, and tune thresholds and departure delay. Closed-lid mode pauses proximity actions.
- **Battery protection and launch at login.** Pause keep-awake below a configurable battery level, set to 20% by default. Turning keep-awake off or quitting restores the normal sleep policy.

## Install

Build on **macOS 14 or later** with Apple Command Line Tools.

```sh
git clone https://github.com/Hoemr/FoldDay.git
cd FoldDay
zsh build.sh "$PWD/dist/FoldDay.app"
```

Move `dist/FoldDay.app` to **Applications**, open it, and choose **折昼 设置…** from its menu bar icon.

## Quick start

### Keep your Mac awake with the lid closed

1. Open **合盖保活** and click **授权电源组件…** to complete the one-time administrator setup.
2. Turn on **启用合盖保活** and choose your backlight and battery options. Wait for **等待合盖** before closing the lid.
3. When using a computer-use agent, verify that it can still take a screenshot and click while the lid is closed.

### Lock when you leave and unlock when you return

1. Open **蓝牙锁屏** and use **添加蓝牙设备…** to select a nearby BLE device.
2. For auto-unlock, use **设置解锁密码…** and grant Accessibility access. FoldDay stores the password in your local Keychain.
3. Enable proximity sensing, confirm that the device is detected, then test leaving and returning. Each device displays its own signal strength.

## Compatibility

FoldDay uses macOS power settings for clamshell keep-awake and the private `DisplayServices` interface for brightness. Closed-lid GUI availability depends on your MacBook, macOS version, and screen-lock policy. Test your setup on battery and without an external display before relying on it.

<details>
<summary>Power helper, troubleshooting, and uninstall</summary>

The administrator setup installs a helper restricted to sleep control. If macOS already has a sleep override, **接管并启用** hands responsibility for that override to FoldDay. On a later launch, FoldDay checks for a leftover override from an interrupted helper.

```sh
/Applications/FoldDay.app/Contents/MacOS/FoldDay --diagnostics
log show --last 15m --style compact --predicate 'subsystem == "local.lidawake"'
```

To uninstall, turn off **登录后自动启动**, remove the power helper with **移除电源组件…** if installed, then quit and trash the app. You can remove the stored password in Keychain Access by deleting the FoldDay entry with service name `local.lidawake.proximity`.

For repeat builds, set `FOLDDAY_SIGNING_IDENTITY` to the local signing certificate’s SHA-1 fingerprint and optionally set `FOLDDAY_SIGNING_KEYCHAIN`. Using the same signing identity preserves permissions associated with that identity.

</details>

## Credits

FoldDay’s Bluetooth proximity detection reuses MIT-licensed code from [BLEUnlock](https://github.com/Skyearn/BLEUnlock). [MIT notice](LICENSE-BLEUnlock)
