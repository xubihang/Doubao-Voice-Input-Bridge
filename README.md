<p align="center">
  <img src="Sources/assets/appicon.png" alt="DoubaoVoiceBridge icon" width="128" height="128">
</p>

<h1 align="center">DoubaoVoiceBridge</h1>

DoubaoVoiceBridge 是一个本地 macOS 菜单栏工具。它把一个全局快捷键做成按住说话的开关：平时保留你习惯的输入法，按住触发快捷键时切到豆包输入法进行语音输入，松开后自动恢复回日常输入法。默认触发键是右 `Command`，也可以在配置文件里自由调整为自己习惯的快捷键组合。

从 `1.0.5` 开始，应用会检测豆包输入法版本：豆包 `0.9.2` 及以后按新版“免按模式”触发，只向豆包发送一次语音快捷键；更早版本或无法读取版本时，继续使用旧版预热后长按方案。

## 前置条件

- macOS
- 需要使用豆包输入法
- 首次使用要授予两个系统权限：
  - Accessibility
  - Input Monitoring

## 快速开始

### 1. 下载 Release 版

如果你只是想直接用，优先去 GitHub Release 下载打包好的应用：

[`Releases`](https://github.com/xubihang/Doubao-Voice-Input-Bridge/releases)

下载后把 `DoubaoVoiceBridge.app` 放到 `Applications` 或任意常用目录，直接打开即可。

### 2. 首次打开后授权

第一次启动后，系统会提示或需要你手动到系统设置里授权：

- 系统设置 -> 隐私与安全性 -> 辅助功能
- 系统设置 -> 隐私与安全性 -> 输入监控

授权完成后，退出并重新打开应用。

### 3. 开始使用

1. 确认豆包输入法已安装
2. 豆包 `0.9.2` 及以后建议在豆包设置里使用“免按模式”
3. 切到你当前想正常使用的输入法
4. 在任意可输入文本的地方，按住触发快捷键，默认是右 `Command`
5. 说话结束后松开触发快捷键
6. 应用会自动切回按下触发快捷键前的输入法

菜单栏里可以：

- `Disable Key Capture` / `Enable Key Capture`：临时停用或启用触发快捷键接管，应用和守护仍保持运行
- `Open Log`：打开日志
- `Open Config`：用 Finder 定位到用户配置文件
- `Reload Config`：重新读取配置文件，改完快捷键或延迟后可直接生效
- `Check Permissions`：重新检查权限
- `Quit and Disable Auto Restart`：退出应用，并关闭 LaunchAgent 自动重启

## 配置说明

用户配置文件放在当前用户的 Application Support 目录。首次启动时，如果用户配置不存在，应用会自动创建一份。

路径：

```text
~/Library/Application Support/DoubaoVoiceBridge/config.json
```

支持部分覆盖，没写的项会自动沿用默认值。

示例：

```json
{
  "launchAtLogin": false,
  "restoreDelay": 0.2,
  "postSwitchSettleDelay": 0.5,
  "switchWaitTimeout": 2.0,
  "switchPollInterval": 0.05,
  "focusBounceBackDelay": 0.16,
  "focusBounceSettleDelay": 0.16,
  "triggerHoldDelay": 0.25,
  "optionWarmupTapDuration": 0.05,
  "optionWarmupToHoldDelay": 0.22,
  "tapDuration": 0.15,
  "triggerHotkey": "RightCommand",
  "voiceHotkey": "LeftOption"
}
```

各项含义：

- `launchAtLogin`：旧版 Login Item 配置保留项，当前版本不再使用；应用会自动使用 LaunchAgent 守护运行
- `restoreDelay`：松开触发快捷键后，延迟多久恢复输入法，默认 `0.2`
- `postSwitchSettleDelay`：切到豆包后，等待语音模块稳定的时间，推荐 `0.5`；如果连续呼起时偶尔失败，可以逐步调大，最高先试到 `1.0` 左右
- `switchWaitTimeout`：等待目标输入法确认成功的超时，默认 `2.0`
- `switchPollInterval`：轮询当前输入法的间隔，默认 `0.05`
- `focusBounceBackDelay`：做焦点回弹时，切走后多久切回原应用，默认 `0.16`
- `focusBounceSettleDelay`：切回原应用后，再等多久再触发语音，默认 `0.16`
- `triggerHoldDelay`：触发快捷键需要按住多久才开始语音流程，默认 `0.25`；短按或普通组合键会继续交给当前应用处理
- `optionWarmupTapDuration`：左 `Option` 预热按下的持续时间，默认 `0.05`
- `optionWarmupToHoldDelay`：预热结束到正式按住之间的等待时间，默认 `0.22`
- `tapDuration`：单次点按语音快捷键的持续时间，默认 `0.05`；豆包 0.9.2 及以后免按模式下使用，模拟真实按键的按下-释放时长
- `triggerHotkey`：用户按下的触发键，默认 `RightCommand`，支持 `RightCommand+Space` 这类加号组合
- `voiceHotkey`：应用发给豆包的语音快捷键，默认 `LeftOption`，同样支持加号组合；豆包 `0.9.2` 及以后会单次点按，旧版会预热后长按

热键名称大小写不敏感，空格可省略。固定名称包括 `LeftShift`、`RightShift`、`Shift`、`LeftControl`、`RightControl`、`Control`、`LeftOption`、`RightOption`、`Option`、`LeftCommand`、`RightCommand`、`Command`、`Tab`、`Space`。字母、数字和常见符号按键可以直接写基础输入，例如数字键写 `1`，不写 Shift 后的 `!`。

## 构建

如果你想自己编译：

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open build/DoubaoVoiceBridge.app
```

项目根目录的 `config.json` 是默认模板。打包时，`scripts/build-app.sh` 会把这份模板复制进应用包；用户第一次运行 app 时，再从模板生成自己的用户配置。后续维护请改用户目录里的配置文件，不要改 `/Applications/DoubaoVoiceBridge.app` 包内文件。

脚本会优先使用 `CODE_SIGN_IDENTITY` 指定的签名身份；未指定时会自动选本机第一个有效的代码签名证书，找不到证书才使用 ad-hoc 签名。反复本地验证时建议使用稳定签名身份，macOS 权限记录更容易沿用。

## LaunchAgent 守护运行

应用首次启动时会自动安装用户级 LaunchAgent。用户直接双击 `DoubaoVoiceBridge.app` 后，应用会把当前 app 包内的可执行文件注册到：

```text
~/Library/LaunchAgents/local.doubao-voice-bridge.keepalive.plist
```

这个 LaunchAgent 使用 `RunAtLoad` 和 `KeepAlive`，由 `launchd` 在当前用户的 Aqua 图形会话中托管应用：

```text
DoubaoVoiceBridge.app/Contents/MacOS/DoubaoVoiceBridge
```

如果应用被移动到新的目录，下次手动打开新的 app 时会自动更新 LaunchAgent 指向的新路径。

菜单里的 `Quit and Disable Auto Restart` 会卸载 LaunchAgent 并退出应用。之后再次手动打开应用时，会重新安装并启用 LaunchAgent。

菜单里的 `Disable Key Capture` 只暂停触发快捷键接管，不会退出应用，也不会关闭 LaunchAgent。这个开关适合临时不想让应用接管按键时使用。

开发时也可以用脚本查看或手动调整 LaunchAgent：

查看状态：

```bash
./scripts/launch-agent-status.sh
```

卸载：

```bash
./scripts/uninstall-launch-agent.sh
```

LaunchAgent 的标准输出和错误日志在：

```text
~/Library/Logs/DoubaoVoiceBridge/launch-agent.out.log
~/Library/Logs/DoubaoVoiceBridge/launch-agent.err.log
```

## 下载版注意事项

- Release 版和本地编译版都需要重新授权权限
- 豆包 `0.9.2` 及以后会自动走免按模式触发；如果日志里读不到豆包版本，会保守回退到旧版长按触发
- 第一次打开如果被 macOS 拦截，去系统设置里允许，或者从 Finder 右键打开一次
- 应用运行时只在内存中记录按键前的输入法，不会修改配置文件来保存恢复目标
- 日志在：

```text
~/Library/Logs/DoubaoVoiceBridge/app.log
```

## Release 1.0.6

- 重写 HotkeySender 事件模拟：修饰键按下/释放时补发 `flagsChanged` 事件，`keyUp` 时 flags 反映剩余修饰键状态而非清零，与真实硬件行为一致
- 新增 `tap(duration:completion:)` 方法封装完整点按序列，替代手动拼 `down()` + `asyncAfter` + `up()`
- 新增 `tapDuration` 配置项，控制免按模式下点按持续时间，默认 `0.15` 秒
- 修复豆包 0.9.2+ 偶尔触发"触发方式调整"弹窗的问题
- app bundle 版本提升到 `1.0.6`

## Release 1.0.5

- 适配豆包输入法 `0.9.2` 的“免按模式”：切到豆包后只发送一次语音快捷键，避免新版豆包把旧版长按模拟误判为不稳定触发
- 保留旧版兼容：豆包低于 `0.9.2` 或无法读取版本时，仍使用原来的预热后长按方案
- 新增版本策略与状态机测试，覆盖 `0.9.1`、`0.9.2`、`0.10.0` 和未知版本
- app bundle 版本提升到 `1.0.5`
