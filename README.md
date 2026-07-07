# Touch Claude

让 Claude Code 住进你的 Touch Bar。当你在终端里运行 Claude Code 时，Touch Bar 上会出现一个像素小人；每当 Claude 干完活、停下来等你时，小人会跳两下提醒你回来。

![Touch Claude 在 Touch Bar 上](assets/hero.png)

一个极简的原生 macOS 后台小工具：无 Dock 图标、无菜单栏，装好就忘，安静地待在 Touch Bar 一角。

## 功能

- 🟥 **状态指示** — 终端里有 Claude Code 在跑时，Touch Bar 显示像素小人 + “Claude”；退出后自动消失。
- 👋 **完成提醒** — Claude 每次执行完毕、停下等待输入时，小人跳两下，让你不用一直盯着屏幕。
- 🎛️ **随手开关** — 一句 `clawd wake` / `clawd sleep` 想开就开、想关就关，不跟系统的亮度、音量抢 Touch Bar。
- 🪶 **极简常驻** — 开机自启、占用极低，不打扰你的工作流。

## 项目结构

```
Touch-Claude/
├─ Sources/        小工具的源码（Swift + AppKit）
├─ scripts/        安装 / 卸载 / 构建脚本
├─ assets/         像素小人等图片素材
└─ README.md
```

## 快速开始

> 需要一台带 Touch Bar 的 MacBook Pro。

```bash
# 1. 编译并安装开机自启的后台小工具
./scripts/install_launch_agent.sh

# 2. 安装“完成提醒”（写入 Claude Code 配置，自动备份）
python3 scripts/configure_stop_hook.py
```

装好后，**新开一个 `claude` 终端**即可看到 Touch Bar 上的小人。

### 手动控制小人

安装脚本会顺带装好 `clawd` 命令，让你随时开关小人（不必等 Claude 启动或退出）：

```bash
clawd wake    # 一直显示小人
clawd sleep   # 藏起小人（点系统的亮度、音量都不会再被它抢走）
clawd auto    # 恢复默认：跟着 Claude 走，在跑就显示、退出就消失
clawd jump    # 让小人跳一下（测试“完成提醒”的动画）
```

> 小提示：如果你用 Touch Bar 上的 `✕` 把小人关掉了，`clawd wake` 就能把它叫回来。

### 卸载

```bash
./scripts/uninstall_launch_agent.sh
python3 scripts/configure_stop_hook.py --remove
```

## 提示

把 `系统设置 → 键盘 → 触控栏 → 触控栏显示` 设为 **App 控制**，小人才会出现。
