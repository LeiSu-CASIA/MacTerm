<p align="center"><img src="docs/assets/icon.png" width="128" alt="MacTerm icon"></p>

# MacTerm

面向 macOS 的轻量终端工作台。使用 AppKit、WebKit、xterm.js 与系统 OpenSSH，提供 SSH、多标签终端、会话管理和 SFTP 文件浏览 / 传输。

当前版本：**0.3.43**。

## 功能

- 本地 shell、SSH 和多标签，支持会话保存、分组、导入导出、SSH config 导入与跳板机。
- 左侧 SFTP 文件浏览、上传下载、目录传输、传输队列、目录书签与远程文本编辑。
- 终端查找、主题 / 字号、输出日志、命令宏、广播、正则高亮与规则组。
- FTP / 显式与隐式 FTPS、串口、Telnet，以及内嵌 VNC / RDP 首版。

## 界面展示

### 多标签终端与会话库

顶部工具栏集中放置常用操作，左侧管理收藏、分组和保存的会话，右侧使用多标签终端。

![MacTerm 多标签终端与会话库](docs/assets/main-window.png)

### 文件工作区

支持浏览、筛选、上传下载和传输队列。下图展示 FTP / FTPS 文件列表。通过 SSH 连接时，SFTP 文件栏位于左侧会话区域下方。

![MacTerm 文件工作区（示例数据）](docs/assets/file-browser.png)

### 终端高亮

可配置关键词或正则表达式、颜色和规则组，在保留原始终端文本的同时突出错误、警告与连接状态。

![MacTerm 终端高亮预览](docs/assets/terminal-highlights.png)

## 从源码构建

部署目标为 macOS 12，主要验证平台为 Apple Silicon Mac。构建需要 Apple Command Line Tools（含 Swift 和 clang）、Node.js 18 或更新版本、npm 和 Python 3。

```sh
npm ci
./build.sh
open build/MacTerm.app
```

首次构建会下载指定版本的 FreeRDP、OpenSSL 和 cJSON，并在项目内准备 CMake。

构建产物位于 `build.noindex/`，也可通过 `build/` 访问。应用使用本机临时签名，尚未通过 Apple 公证。

## 基础使用

1. 启动 App，点击新建 SSH 会话，填写主机、用户名和端口。
2. 在左侧双击会话连接，按 SSH 提示输入密码或私钥口令。
3. 登录成功后使用左侧 SFTP 文件栏浏览、上传或下载文件。
4. 添加会话可打开新标签。

会话数据保存在 `~/Library/Application Support/MacTerm/`。

## 验证

```sh
./test.sh
# 可选的完整本机 SSH / SFTP 端到端验证
python3 Tests/ssh_options_integration.py
# 可选的 FTP / FTPS 验证，需要独立虚拟环境安装测试依赖
python3 -m venv build/ftp-test-env
build/ftp-test-env/bin/pip install -r Tests/ftp-requirements.txt
build/ftp-test-env/bin/python Tests/ftp_integration.py
```

集成测试使用本机临时服务和示例数据。部分界面测试需要访问 macOS WebKit 服务。

## 已知限制

- 暂未集成 X Server / XDMCP。
- FTP / FTPS 需要服务器支持标准 MLSD 和 UTF-8。FTP 文件在校验和改名之间仍可能被其他客户端修改。
- RDP 首版不包含音频、磁盘 / 打印机重定向、网关或多显示器支持。

详细说明：[RDP](docs/RDP接入.md)、[VNC](docs/VNC接入.md)。

## 开源许可

Copyright (C) 2026 LeiSu-CASIA.

本项目原创代码按 **GPL-3.0-only** 发布，见 [LICENSE](LICENSE)。第三方组件保留各自许可证和版权，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
