# Claude Touch Bar

当你在终端里打开 Claude Code 时，Touch Bar 上显示一个像素小人；Claude 每次执行完毕时，小人会跳两下提醒你回来。

一个极简的原生 macOS 后台 helper（Swift + AppKit），无 Dock 图标、无菜单栏。

## 工作原理

```
LaunchAgent 常驻 helper（每 1.5s 轮询一次）
  ├─ 有没有名为 `claude` 的进程？(pgrep -x claude)
  ├─ ~/.claude-touchbar/mode 里的手动开关？(auto|wake|sleep)
  │    └─ 由 auto/wake/sleep + 进程状态算出「应不应该显示」
  │         └─ 只在「应不应该显示」发生变化时才 present / dismiss
  │            （绝不每轮重新抢占，否则会顶掉系统亮度/音量条）
  └─ ~/.claude-touchbar/poke 的修改时间变新了 → 小人跳两下

Claude Code 执行完毕 ─(Stop hook)→ touch ~/.claude-touchbar/poke
clawd wake/sleep/auto ──────────→ 写 mode 文件
clawd jump ─────────────────────→ touch poke 文件
```

- **进程检测**用 `pgrep -x claude`（按进程名精确匹配，区分大小写）：只命中终端里的 Claude CLI，不会误命中 Claude.app 桌面版（进程名是大写 `Claude`）或命令行里带 "claude" 字样的工具（如 cmux）。
- **呈现是边沿触发的**：helper 记住上一次「应不应该显示」的结果，只在结果变化（或刚收到一条 `clawd` 命令）时才调用私有 API `presentSystemModalTouchBar` / `dismissSystemModalTouchBar`。早期版本每轮无条件重新 present，会在你点亮度/音量时把 Touch Bar 抢回去、也让系统的 `✕` 关闭键失效——现在不会了。
- **手动开关**：`clawd` 写 `~/.claude-touchbar/mode`，helper 靠该文件的修改时间识别「刚下了命令」，从而强制重放一次 present/dismiss——这样即便你用系统 `✕` 把小人最小化了（此时 helper 并不知情），`clawd wake` 也能把它拉回来。
- **完成提醒**靠 Claude Code 的 `Stop` hook：每次 Claude 停下等输入时触发，往 poke 文件写一下时间戳，helper 检测到就播放跳动动画（手动逐帧重绘，兼容 Touch Bar 远程渲染）。`clawd jump` 走同一条链路，用于测试。
- 像素小人 PNG 以 base64 内嵌进二进制（`ClaudePixelImage.swift`），单文件自包含，最近邻缩放保持像素清晰。

## 安装

```bash
# 1. 编译 + 安装开机自启的 helper
./scripts/install_launch_agent.sh

# 2. 安装 Claude 完成提醒的 Stop hook（写入 ~/.claude/settings.json，自动备份）
python3 scripts/configure_stop_hook.py
```

> Stop hook 在 **新开的 Claude 会话**里才生效（Claude Code 在会话启动时读取 hooks）。装好后请新开一个 `claude` 终端测试。

## 手动控制（clawd）

安装脚本会把 `clawd` 命令软链到 PATH（优先 `~/bin`，回退 `/opt/homebrew/bin`、`/usr/local/bin`）。它和 helper 是同一个二进制：带子命令时只写一下信号文件就退出，常驻实例在下一轮轮询时生效。

```bash
clawd wake    # 强制常显
clawd sleep   # 强制隐藏（此时点系统亮度/音量不会再被抢走）
clawd auto    # 恢复默认：跟随 claude 进程
clawd jump    # touch poke 文件，让小人跳一下（测试完成提醒动画）
```

`wake` / `sleep` / `auto` 写入 `~/.claude-touchbar/mode` 并**持久化**（重启 helper 后仍生效）；`jump` 复用完成提醒的 poke 链路。

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
