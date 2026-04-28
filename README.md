# cmatrix-screensaver

一个轻量的 Linux 终端屏保脚本：当当前 shell 长时间停在空命令行提示符时，自动启动 `cmatrix -s -r`。

它不是系统级 daemon，也不会尝试抢占其他进程正在使用的 TTY。脚本只在当前交互式 shell 会话内工作，因此行为更可控，也更适合放进个人终端配置里。

## 工作方式

脚本会在当前 shell 中跟踪 prompt 状态和输入活动。只有同时满足下面这些条件时，才会认为终端处于可触发屏保的空闲状态：

- shell 已经回到 prompt
- 当前没有前台命令在运行
- 当前命令行输入缓冲区为空
- 在 `CMSS_TIMEOUT` 秒内没有新的 prompt 或编辑活动
- 如果运行在 `tmux` 中，当前 pane 对已附着的客户端可见

当空闲条件持续足够久后，后台计时器会向当前 shell 发送唤醒信号。`zsh`/`fish` 使用 `SIGUSR1`；`bash` 使用 `SIGWINCH`，这样可以在 Readline 停在提示符等待输入时立即唤醒。shell 收到信号后会再次检查状态，确认仍然空闲才会执行 `CMSS_COMMAND`。

## 项目结构

- `bash/cmatrix-screensaver.bash`：bash adapter，基于 `PROMPT_COMMAND` 和 `SIGWINCH` 跟踪状态（要求 Bash 4+）
- `zsh/cmatrix-screensaver.zsh`：zsh adapter，基于 `precmd`、`preexec` 和 `zle` widget 跟踪状态
- `fish/cmatrix-screensaver.fish`：fish adapter，基于 fish 事件和常用 key binding 包装跟踪状态
- `bin/cmss-core`：POSIX sh 共享核心；三个 adapter 调用它来 fork 后台计时器和查询 tmux pane 可见性
- `bin/install.sh` / `bin/uninstall.sh`：把 `source` 语句写入 / 移出对应 shell 的配置文件
- `tests/install-roundtrip.sh`：install + uninstall 的端到端回归测试，CI 和本地都用同一份
- `.github/workflows/ci.yml`：每次 push / PR 跑 shellcheck + 三种 shell 的 parse 检查 + 上面的 round-trip 测试

## 安装

先确认系统里已经安装 `cmatrix`：

```bash
cmatrix -V
```

然后在项目目录运行安装脚本：

```bash
cd ~/cmatrix-screensaver
./bin/install.sh
```

如果不指定参数，安装脚本会读取当前环境变量 `$SHELL`，并安装到对应的 shell。

例如当前 `$SHELL=/usr/bin/zsh` 时，上面的命令就等价于安装到 `zsh`。如果要显式安装到 `fish`：

```bash
cd ~/cmatrix-screensaver
./bin/install.sh fish
```

如果要安装到 `bash`：

```bash
cd ~/cmatrix-screensaver
./bin/install.sh bash
```

如果所有支持的 shell 都要安装：

```bash
cd ~/cmatrix-screensaver
./bin/install.sh all
```

安装脚本会检查两件事：

- 对应 shell 是否已安装并且能在 `PATH` 中找到
- 对应配置文件是否已经存在

如果你显式指定了某个 shell，但它不存在，或者配置文件还不存在，脚本会直接报错退出，不会创建一个空配置文件。

`all` 模式下，脚本只会安装到“shell 已安装且配置文件已存在”的目标，其余会跳过。

可能被修改的配置文件：

- `bash`：`~/.bashrc`
- `zsh`：`~/.zshrc`
- `fish`：`~/.config/fish/config.fish`

安装后重启 shell，或手动加载：

```bash
source ~/cmatrix-screensaver/bash/cmatrix-screensaver.bash
```

```zsh
source ~/cmatrix-screensaver/zsh/cmatrix-screensaver.zsh
```

```fish
source ~/cmatrix-screensaver/fish/cmatrix-screensaver.fish
```

## 配置

建议在 shell 配置文件中先设置变量，再 `source` 脚本。

`bash` 示例：

```bash
export CMSS_TIMEOUT=180
export CMSS_COMMAND='cmatrix -s -r'
export CMSS_REQUIRE_VISIBLE_PANE=1
source ~/cmatrix-screensaver/bash/cmatrix-screensaver.bash
```

`zsh` 示例：

```zsh
export CMSS_TIMEOUT=180
export CMSS_COMMAND='cmatrix -s -r'
export CMSS_REQUIRE_VISIBLE_PANE=1
source ~/cmatrix-screensaver/zsh/cmatrix-screensaver.zsh
```

`fish` 示例：

```fish
set -g CMSS_TIMEOUT 180
set -g CMSS_COMMAND 'cmatrix -s -r'
set -g CMSS_REQUIRE_VISIBLE_PANE 1
source ~/cmatrix-screensaver/fish/cmatrix-screensaver.fish
```

可用配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `CMSS_TIMEOUT` | `30` | prompt 空闲多少秒后触发 |
| `CMSS_COMMAND` | `cmatrix -s -r` | 触发时执行的命令 |
| `CMSS_REQUIRE_VISIBLE_PANE` | `1` | 在 `tmux` 中只允许可见 pane 触发；设为 `0` 可关闭 |
| `CMSS_DEBUG` | 未设置 | 设置为任意值后输出调试日志 |

## 可替换的屏保命令

`CMSS_COMMAND` 可以换成其他终端像素风格或 ASCII 动画工具。比较适合作为屏保的有：

| 工具 | 风格 | 示例 |
| --- | --- | --- |
| [`cmatrix`](https://github.com/abishekvashok/cmatrix) | Matrix 数字雨 | `cmatrix -s -r` |
| [`pipes.sh`](https://github.com/pipeseroni/pipes.sh) | 经典管道屏保 | `pipes.sh -r 0 -t 1 -p 3 -f 35` |
| [`cbonsai`](https://gitlab.com/jallbrit/cbonsai) | ASCII 盆栽生长动画 | `cbonsai -S` |
| [`asciiquarium`](https://pypi.org/project/asciiquarium/) | 终端水族箱 | `asciiquarium` |
| [`aafire`](https://aa-project.sourceforge.net/aalib/) | ASCII 火焰 | `aafire -driver curses` |
| [`nyancat`](https://github.com/klange/nyancat) | 彩虹像素动画 | `nyancat -n -s` |
| [`termsaver`](https://pypi.org/project/termsaver/) | Python 终端屏保集合 | `termsaver matrix` |
| [`drift`](https://github.com/phlx0/drift) | 现代终端动画屏保 | `drift --scene pipes` |

例如：

```bash
export CMSS_COMMAND='cbonsai -S'
```

## 使用命令

脚本加载后会自动启用屏保逻辑，也可以手动控制：

```sh
cmss_status
cmss_disable
cmss_enable
cmss_now
```

`cmss_status` 会输出当前状态、超时时间、tmux pane 可见性和后台 timer pid。

`cmss_now` 会立即启动 `CMSS_COMMAND`，绕过空闲计时和 prompt 状态检查，方便演示和调试。命令不存在或已经在跑时，它会把错误打到 stderr 并以非零退出。

## 卸载

```bash
cd ~/cmatrix-screensaver
./bin/uninstall.sh
```

跟 `install.sh` 对称：不指定参数时按 `$SHELL` 自动检测；显式指定 shell 名（`bash` / `zsh` / `fish` / `all`）也可以。

它会从对应 rc 文件中删除安装时写入的 `# cmatrix-screensaver` 标记和 `source` 行——通过 `mktemp` + 原子 `mv` 替换原文件，避免中途中断把 rc 写坏，并保留原文件权限。

执行 `uninstall.sh` 只是改 rc 文件，对**当前**已经加载脚本的会话没有影响。所以建议：

```sh
# 1. 在当前会话里禁用屏保逻辑
cmss_disable

# 2. 从 rc 文件里移除 source 行（影响今后启动的新会话）
~/cmatrix-screensaver/bin/uninstall.sh
```

或者直接重启 shell，新会话从干净的 rc 启动。

## 当前限制

- 这是按 shell 会话生效的脚本，不是系统级锁屏或后台 daemon。
- `bash` 版本只在 `PROMPT_COMMAND` 时刻更新空闲计时。如果你在 prompt 上慢慢敲一行命令、超过 `CMSS_TIMEOUT` 还没敲回车，屏保会启动；按任意键 cmatrix 退出，readline 恢复你的输入，没有内容丢失。
- `bash` 版本要求 Bash 4+（`declare -g` / `BASHPID`）；macOS 自带的 Bash 3.2 不支持，请用 Homebrew 装新版 Bash。
- `zsh` 版本依赖 `zle` hook；如果 prompt 框架或自定义 widget 很特殊，可能需要微调。
- `fish` 版本依赖事件和一组常用 key binding 包装；复杂 vi-normal 模式编辑动作下，空闲计时可能不如 `zsh` 精确。
- `tmux` pane 可见性检查只面向 `tmux`；不在 `tmux` 中时默认认为当前终端可见。
