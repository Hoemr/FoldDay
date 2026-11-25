# FoldDay · 折昼

**macOS clamshell keep-awake, internal backlight off, and Bluetooth proximity lock/unlock.**

FoldDay is a native Swift menu bar app for MacBooks. It is designed to keep an unlocked desktop available to computer-use agents with the lid closed, including on battery power. Open the lid to restore the internal display brightness. When the lid is open, selected Bluetooth LE devices can lock the Mac as you leave and unlock the current session when you return.

折昼是一款 macOS 菜单栏工具，把合盖保活、内置屏背光归零和蓝牙距离锁屏/解锁放在同一个设置窗口。合盖保活适用于无外接显示器的使用场景，开盖后恢复原亮度。

## Features · 功能

| 功能 | 折昼如何处理 |
| --- | --- |
| **Clamshell keep-awake · 合盖保活** | 在合盖前启用系统保活，支持电池供电，供已解锁的 Computer Use 桌面继续运行。合盖时暂停蓝牙自动锁屏和解锁。 |
| **Backlight off · 内置屏背光归零** | 合盖时把内置屏亮度设为 0，开盖后恢复原亮度。 |
| **Bluetooth proximity lock/unlock · 蓝牙距离锁屏** | 在折昼内扫描、添加或移除 BLE 设备。每台设备独立显示 RSSI（dBm），可以分别设置靠近解锁、离开锁屏、亮屏、信号阈值和离开延迟。 |
| **Battery protection · 低电量保护** | 支持可调电量阈值，默认低于 20% 暂停合盖保活。 |
| **Launch at login · 登录自启** | 登录 macOS 后沿用已保存的设置。关闭保活或退出应用时恢复正常系统睡眠策略。 |

## Build · 构建

需要 macOS 14 或更新版本及 Apple Command Line Tools。脚本构建当前 Mac 架构的应用并签名。

```sh
git clone https://github.com/Hoemr/FoldDay.git
cd FoldDay
zsh build.sh "$PWD/dist/FoldDay.app"
```

把构建好的 `FoldDay.app` 移到「应用程序」，打开后从菜单栏进入设置。

## Setup · 设置

### 合盖保活

1. 在「合盖保活」中点击「授权电源组件」，完成一次 macOS 管理员授权，再打开「启用合盖保活」。
2. 如果机器已有系统睡眠覆盖设置，页面会提供「接管并启用」。接管后，折昼负责在退出或暂停时恢复正常睡眠。
3. 按需开启背光归零、电池供电、低电量保护和登录自启。合盖前确认状态为「等待合盖」。

电源组件使用 macOS 的 `pmset` 管理睡眠开关。管理员安装为当前用户添加一条仅允许运行该组件的 sudoers 规则。退出或强制结束图形应用会让组件撤销覆盖设置。组件本身异常退出时，折昼会在下次启动时检查残留记录。

### 蓝牙锁屏

1. 在「蓝牙锁屏」里点击「添加蓝牙设备」，允许 macOS 蓝牙权限，再从扫描列表添加设备。硬件需要系统配对时，从扫描页打开「系统蓝牙设置」。
2. 启用自动解锁时，在「设置解锁密码」输入本机账户密码，并授予折昼辅助功能权限。折昼将密码保存于本机钥匙串。
3. 打开「启用蓝牙感应」。先确认设备显示为附近，再携设备离开并返回，验证锁屏和解锁。设备信号中断时，折昼会等待下一次可用测量。

自动解锁需要先测得设备离开，再测得返回。重启后的首次登录由 macOS 处理。

## Compatibility · 兼容性

背光控制通过 macOS 私有 `DisplayServices` 接口实现。合盖后的显示状态和 Computer Use 可用性取决于 Mac 型号、macOS 版本以及当前会话的锁屏设置。升级系统或换机器后，可用下面的命令检查状态，并用实际合盖、截图和点击验证桌面可用性。

```sh
/Applications/FoldDay.app/Contents/MacOS/FoldDay --diagnostics
log show --last 15m --style compact --predicate 'subsystem == "local.lidawake"'
```

## Uninstall · 卸载

关闭「登录后自动启动」。如已授权电源组件，点击「移除电源组件」并完成 macOS 授权。退出折昼，再把应用移到废纸篓。如果需要清理解锁密码，可在「钥匙串访问」中删除服务为 `local.lidawake.proximity` 的 FoldDay 条目。

## Signing and credits · 签名与致谢

通过 `FOLDDAY_SIGNING_IDENTITY` 指定本机代码签名证书的 SHA-1 指纹，可选用 `FOLDDAY_SIGNING_KEYCHAIN` 指定钥匙串。重复构建时沿用同一签名身份，可保留基于该身份的系统授权。

蓝牙距离判定沿用了 BLEUnlock 的 MIT 许可代码。 [BLEUnlock](https://github.com/Skyearn/BLEUnlock) · [MIT notice](LICENSE-BLEUnlock)
