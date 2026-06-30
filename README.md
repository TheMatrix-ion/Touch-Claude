# Claude Touch Bar

当你在终端里打开 Claude Code 时，Touch Bar 上显示一个像素小人；Claude 每次执行完毕时，小人会跳两下提醒你回来。

一个极简的原生 macOS 后台 helper（Swift + AppKit），无 Dock 图标、无菜单栏。

## 工作原理

```
LaunchAgent 常驻 helper
  ├─ 每 1.5s 轮询：有没有名为 `claude` 的进程？(pgrep -x claude)
  │    ├─ 有  → Touch Bar 显示像素小人 + "Claude"
  │    └─ 没  → 从 Touch Bar 撤掉
  └─ 监听 ~/.claude-touchbar/poke 的修改时间
       └─ 变新了 → 小人跳两下

Claude Code 执行完毕
  └─(Stop hook)→ touch ~/.claude-touchbar/poke
```

- **进程检测**用 `pgrep -x claude`（按进程名精确匹配，区分大小写）：只命中终端里的 Claude CLI，不会误命中 Claude.app 桌面版（进程名是大写 `Claude`）或命令行里带 "claude" 字样的工具（如 cmux）。
- **完成提醒**靠 Claude Code 的 `Stop` hook：每次 Claude 停下等输入时触发，往 poke 文件写一下时间戳，helper 检测到就播放跳动动画（手动逐帧重绘，兼容 Touch Bar 远程渲染）。
- 像素小人 PNG 以 base64 内嵌进二进制（`ClaudePixelImage.swift`），单文件自包含，最近邻缩放保持像素清晰。

## 安装

```bash
# 1. 编译 + 安装开机自启的 helper
./scripts/install_launch_agent.sh

# 2. 安装 Claude 完成提醒的 Stop hook（写入 ~/.claude/settings.json，自动备份）
python3 scripts/configure_stop_hook.py
```

> Stop hook 在 **新开的 Claude 会话**里才生效（Claude Code 在会话启动时读取 hooks）。装好后请新开一个 `claude` 终端测试。

## 常用命令

```bash
./scripts/build.sh                              # 仅编译到 ./bin/
./bin/ClaudeTouchBar --once                     # 打印当前是否检测到 claude 进程
CLAUDE_TB_DEBUG=1 ./bin/ClaudeTouchBar          # 前台运行 + 调试日志(到 stderr)
launchctl kickstart -k gui/$(id -u)/com.zhihu.claude-touchbar  # 重启常驻实例

./scripts/uninstall_launch_agent.sh             # 卸载 helper
python3 scripts/configure_stop_hook.py --remove # 移除 Stop hook
```

## 自定义

- **小人图**：替换 `assets/claude-pixel.png` 后，用 `python3` 重新生成 `Sources/ClaudeTouchBar/ClaudePixelImage.swift` 的 base64，再 `./scripts/build.sh`。
- **跳动幅度/次数**：改 `ClaudeLogoView.swift` 里 `PixelImageView` 的 `bounceAmplitude` / `bounceHops` / `bounceDuration`。
- **要不要 "Claude" 字**：改 `ClaudeLogoView.setupViews()`。

## 注意

- 需要带 Touch Bar 的 MacBook Pro，且 `系统设置 → 键盘 → 触控栏 → 触控栏显示` 设为 `App 控制`。
- 用的是 macOS 私有 Touch Bar API（`presentSystemModalTouchBar`），和其它「往 Touch Bar 推内容」的工具（如 codex-quota-widget）会互相抢占，建议同一时间只跑一个。
