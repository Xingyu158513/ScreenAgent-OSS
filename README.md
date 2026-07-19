# ScreenAgent

Windows 上面向普通用户的 OBS 自动录屏与安全归档工具。

ScreenAgent 启动 OBS 录制，为视频添加标题和分类，并在录制结束后将稳定文件归档到本地或上传到 WebDAV。公开版坚持“先验证、后移动、永不自动永久删除”。

后台归档不再随 Windows 登录常驻运行。每次开始录制时，ScreenAgent 会隐藏启动一个只属于本次会话的 worker；处理完成、启动后未发现录像或达到最长会话期限时，worker 会自动退出。异常遗留在 `recordings\raw` 的文件由桌面“恢复未归档录像”快捷方式进行一次性恢复，不会启动常驻扫描。

## 适用场景

- 游戏录像与复盘
- 课程、演示和会议留档
- 内容创作者的 OBS 文件自动整理
- 将大体积录像安全归档到坚果云或通用 WebDAV

## 安全承诺

- 默认只在 `%USERPROFILE%\ScreenAgent` 内工作。
- 不会自动永久删除录像。
- 上传失败、远程检查失败或文件大小不一致时，本地文件保持原位。
- 只有远程同名文件存在且大小一致，才允许将本地文件移动到 `recordings\uploaded`。
- 拒绝处理 `recordings\raw` 以外的文件、目录、符号链接和重解析点。
- 卸载器不会删除录像、日志或配置。
- WebDAV 密码通过标准输入交给 `rclone obscure -`，不会作为明文命令行参数传递。
- 云端连接使用 ScreenAgent 独占的 `%USERPROFILE%\ScreenAgent\config\rclone.conf`，不会修改用户的全局 rclone remote；该文件只授权当前 Windows 用户访问。
- 通用 WebDAV 地址必须使用 HTTPS。

`rclone obscure` 只是防止配置文件中直接出现明文，不是强加密。专用 rclone 配置仍然属于敏感文件，不能上传到 GitHub 或发给他人。详见 [SECURITY.md](SECURITY.md) 和 [PRIVACY.md](PRIVACY.md)。

## 环境要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更高版本
- [OBS Studio](https://obsproject.com/)
- 云端模式需要 [rclone](https://rclone.org/downloads/) 和可用的 WebDAV 账号

## 快速开始

1. 下载并完整解压发行包。
2. 双击 `01_检查电脑环境.bat`。
3. 按需安装 OBS 和 rclone。
4. 双击 `03_安装ScreenAgent.bat`。
5. 按向导选择本地保存、坚果云 WebDAV 或通用 WebDAV。
6. 在 OBS 中把录制目录设为 `%USERPROFILE%\ScreenAgent\recordings\raw`。
7. 使用桌面快捷方式开始录制。

安装器不会创建登录计划任务。录制时的会话 worker 会自动启动并在完成后退出；若上传失败或异常退出，先保留 `raw` 中的文件，再运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\ScreenAgent\app\recover_pending.ps1"
```

## 本地处理策略

- `move_after_verified_upload`（默认）：云端验证成功后移动到 `recordings\uploaded`。
- `keep_local`：云端验证成功后仍保留在 `recordings\raw`。

旧配置中的 `delete_after_verified_upload` 会自动降级为安全移动，不会触发删除。

## 测试

测试只使用临时目录，不启动 OBS、不访问 WebDAV，也不创建计划任务：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run_tests.ps1
```

当前覆盖：

- PowerShell 语法解析
- 未验证时保持原文件
- 验证后移动与防覆盖
- 保留本地模式
- 路径逃逸与相邻前缀攻击
- 旧永久删除模式安全降级
- rclone 密码标准输入边界
- 独占 rclone 配置与 Windows 文件权限
- 卸载器不删除用户数据

## 项目结构

```text
lib/                         归档、安全边界与旧版本迁移模块
tests/                       无外部依赖的 PowerShell 测试
config_wizard.ps1            交互式配置向导
start_recording.ps1          创建录制会话并启动 OBS
session_worker.ps1           有明确期限的单会话处理器
recover_pending.ps1          用户主动执行的一次性遗留文件恢复
install.ps1                  当前用户安装与旧常驻任务迁移
uninstall.ps1                保留用户数据的卸载流程
docs/                        使用和安全文档
```

## 维护方式

真实问题请通过 GitHub Issues 提交，附带日志前必须删除账号、远程路径和文件名中的隐私信息。修复应关联 Issue、补充测试并记录到 [CHANGELOG.md](CHANGELOG.md)。参见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
