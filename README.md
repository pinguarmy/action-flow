# ActionFlow · 动作流

原生 macOS 自动化工具。将快捷键、鼠标、滚动、应用事件或定时器连接到动作链，在一个工作区里创建、预览和管理规则。

[下载](https://github.com/pinguarmy/action-flow/releases) · [MIT 许可证](LICENSE) · [隐私与安全](SECURITY.md)

## 功能

- **触发规则：** 快捷键、双击快捷键、鼠标按钮、滚动、应用激活/启动/退出和定时器。
- **组合动作：** 窗口布局、键盘快捷键、文本输入、应用菜单命令、打开应用或链接、延时、通知和可选 Shell 脚本。
- **管理规则：** 搜索与分组、模板、冲突提示、动作预览、执行进度、暂停与取消。
- **保存配置：** 本地 JSON、导入导出、备份和快照恢复。导入的规则默认禁用。
- **双语界面：** 英文与简体中文，跟随系统语言。

输入观察是被动的，原始按键和鼠标操作仍会传递给当前应用。手势实验室仅识别应用内的滑动、缩放和旋转，不提供全局多指手势触发。

## 安装

需要 macOS 14 或更新版本。在 [Releases](https://github.com/pinguarmy/action-flow/releases) 选择 Apple Silicon 或 Intel 下载包，将 `ActionFlow.app` 拖入“应用程序”后打开。

当前为 Alpha 预发布，采用 ad-hoc 签名，尚未经过 Apple 公证。请核对校验和，并使用 macOS 正常的打开流程，不要关闭 Gatekeeper 或 SIP。

## 开始使用

1. 创建规则，选择触发器、条件和动作。
2. 检查动作预览及所需权限，只授权自己需要的能力。
3. 启用规则，再从菜单栏恢复自动化。
4. 随时从菜单栏暂停自动化或停止当前动作链。

全局自动化与 Shell 脚本默认关闭。输入监控和辅助功能权限需要你在系统设置中授予，应用不会自行授权。暂停或取消不会撤销已经发生的动作。

## 本地与可控

不含遥测、账户、远程控制服务或云同步。规则与备份保存在 `~/Library/Application Support/ActionFlow/`，运行记录只在内存保留。链接和脚本可以在你运行规则时访问网络，脚本也能读写文件，请勿启用不可信规则。

窗口、菜单和文本动作取决于目标应用提供的辅助功能接口。目标应用可能拒绝操作，焦点检查不能消除所有时序风险。首次使用请从低风险动作开始。

## 构建

需要 Swift 6 和 Xcode Command Line Tools，无第三方包依赖。

```bash
swift build
swift run ActionFlowChecks
bash scripts/check-cli.sh
bash scripts/check-runtime.sh
bash scripts/build-app.sh release
open dist/ActionFlow.app
```

完整 Xcode 环境可运行 `swift test`。构建 Intel 版本可使用 `ARCH=x86_64 bash scripts/build-app.sh release`。

## 离线 CLI

`actionflow-cli` 只检查配置，不执行规则。

```bash
swift run actionflow-cli validate examples/window-basics.json
swift run actionflow-cli summarize examples/window-basics.json
swift run actionflow-cli plan examples/window-basics.json
```

配置可能含私人文本、链接或脚本，分享前请检查内容。详见 [隐私说明](PRIVACY.md) 和 [安全说明](SECURITY.md)。
