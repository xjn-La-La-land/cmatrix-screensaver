# cmatrix-screensaver

一个轻量的 `zsh` 原型工具：当当前终端的 `prompt` 长时间处于空闲状态时，自动启动 `cmatrix -s`。

## 设计思路

这个原型刻意运行在当前交互式 `zsh` 会话内部，而不是做成一个系统级 daemon。这样可以避开最难处理的稳定性问题：

- 不需要猜测某个 PTY 是否真的空闲
- 不需要强行向别的进程占用的终端写内容
- 不需要内核模块、`ptrace` 或 `/proc` 级别的技巧

只有同时满足下面这些条件时，原型才会认为当前 shell 处于“空闲”状态：

- `zsh` 已经回到 `prompt`
- 当前没有前台命令在运行
- 当前命令行输入缓冲区为空
- 在 `CMSS_TIMEOUT` 秒内没有新的 `prompt` 活动
- 如果运行在 `tmux` 中，则当前 `pane` 仍然对已附着的客户端可见

当这些条件持续满足足够长时间后，一个很轻的后台计时器会向当前 shell 发送 `SIGUSR1`，然后由 shell 自己再次检查状态，并决定是否执行 `cmatrix -s`。

## 项目结构

- `zsh/cmatrix-screensaver.zsh`：核心实现
- `bin/install.sh`：把 `source` 语句追加到 `~/.zshrc`

## 安装

```bash
cd ~/cmatrix-screensaver
./bin/install.sh
```

或者手动加载：

```bash
source ~/cmatrix-screensaver/zsh/cmatrix-screensaver.zsh
```

## 配置

建议在 `~/.zshrc` 中先设置变量，再 `source` 脚本：

```zsh
export CMSS_TIMEOUT=180
export CMSS_COMMAND='cmatrix -s'
export CMSS_REQUIRE_VISIBLE_PANE=1
source ~/cmatrix-screensaver/zsh/cmatrix-screensaver.zsh
```

`CMSS_REQUIRE_VISIBLE_PANE` 默认值为 `1`，也就是默认开启“仅在当前 `pane` 可见时触发”的检查。如果你想恢复旧行为，可以把它设成 `0`。

脚本加载后可以使用这些辅助命令：

```zsh
cmss_status
cmss_disable
cmss_enable
```

如果需要调试，可以打开 debug 输出：

```zsh
export CMSS_DEBUG=1
source ~/cmatrix-screensaver/zsh/cmatrix-screensaver.zsh
```

## 当前限制

- 这是一个按 shell 会话生效的原型，不是系统级屏保 daemon。
- 当前优先支持 `zsh`，还没有接入 `fish` 或 `bash`。
- 退出 `cmatrix` 的第一下按键，可能会被 `cmatrix` 自己消费掉。
- 它依赖 `zsh` line editor 的 redraw hook；如果你的 prompt 框架或自定义 widget 很特殊，可能需要微调。
- “pane 可见性检查”是面向 `tmux` 设计的；如果不在 `tmux` 中，则默认认为当前终端可见。

## 后续可扩展方向

- 增加 `fish` 适配层，复用同一套状态机
- 为 shell 状态切换补测试
- 在 `cmatrix` 退出后，增加可选的锁屏集成
