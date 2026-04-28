# 树莓派异地无头系统管理套件

> 📀 专为**异地/无头环境**设计的系统刷写与启动管理工具

在**无法物理接触树莓派、没有桌面环境**的情况下，仅通过 SSH 完成系统远程重装和启动介质切换。

---

## 📦 套件组成

| 脚本 | 功能 | 使用场景 |
|------|------|----------|
| `rpi-image-flash.sh` | 烧录系统到目标介质并预配置 SSH/WiFi | 准备新系统盘 |
| `rpi-boot-switch.sh` | 修改 EEPROM 启动顺序 | 切换启动介质 |

**两个脚本配合，可实现：**
- TF 卡 → USB SSD → NVMe 无缝迁移
- 系统损坏后远程恢复
- 批量部署相同配置设备

---

## 🚀 快速开始

```bash
# 1. 下载烧录脚本
curl -O https://raw.githubusercontent.com/CHERISHTOBY/rpi-image-tools/main/rpi-image-flash.sh

# 2. 赋予执行权限
chmod +x rpi-image-flash.sh

# 3. 以 root 权限运行
sudo ./rpi-image-flash.sh

# 4. 切换启动介质
curl -O https://raw.githubusercontent.com/CHERISHTOBY/rpi-image-tools/main/rpi-boot-switch.sh && chmod +x rpi-boot-switch.sh && sudo ./rpi-boot-switch.sh
```

---

## 🔧 脚本一：rpi-image-flash.sh (v4.3)

### 功能特性

| 特性 | 说明 |
|------|------|
| 架构检测 | 仅支持 arm64/aarch64，拒绝 32 位系统 |
| 自动安装依赖 | 自动安装 `rpi-imager`、`libopengl0` |
| 镜像缓存复用 | 缓存至 `/tmp/rpi_image_cache`，避免重复下载 |
| SHA1 校验 | 官方提供校验文件，自动验证完整性 |
| 安全保护 | 识别当前系统盘并禁止向其写入 |
| 多设备支持 | SD 卡、eMMC、NVMe 驱动器 |
| 在线镜像列表 | 从官方 JSON 实时获取 64 位镜像，按日期排序 |
| 离线备用 | 网络不可用时使用内置镜像地址 |
| 自定义镜像 | 支持手动输入任意镜像 URL |
| 无头预配置 | SSH、用户密码、WiFi（NetworkManager 格式） |
| firstrun.sh | 首次启动自动配置并自毁，支持自动重启 |

### 镜像类型

| 类型 | 说明 |
|------|------|
| Raspberry Pi OS Lite (64-bit) | 无桌面，服务器/嵌入式场景 |
| Raspberry Pi OS Full (64-bit) | 桌面版，含推荐软件 |
| 自定义 URL | 第三方镜像 |

> ⚠️ **兼容性说明**：预配置机制基于 Raspberry Pi OS 特有规范，仅适用于官方 Raspberry Pi OS 及其衍生版。不兼容 Ubuntu Server、Arch Linux ARM 等非树莓派 OS 衍生系统。

### 预配置文件

烧录完成后自动写入 boot 分区：

| 文件 | 作用 |
|------|------|
| `ssh` | 空文件，启用 SSH 服务 |
| `userconf.txt` | 格式 `用户名:加密密码` |
| `wifi-connection.nmconnection` | NetworkManager WiFi 配置 |
| `firstrun.sh` | 首次启动执行，完成后自毁并重启 |

### firstrun.sh 执行内容

1. 启用并启动 SSH 服务
2. 为首个普通用户配置免密 sudo
3. 删除树莓派首次启动向导
4. 若配置 WiFi：设置国家码、部署配置文件、重载网络
5. 清理触发参数及临时文件
6. 重启系统

---

## 🔀 脚本二：rpi-boot-switch.sh

### 功能特性

| 特性 | 说明 |
|------|------|
| 安全检测 | 检查 `rpi-eeprom-config` 是否可用 |
| 当前状态显示 | 显示当前 BOOT_ORDER 及对应模式 |
| 智能菜单 | 仅显示可切换的模式，排除当前模式 |
| 二次确认 | 修改前请求确认 |
| 可选重启 | 修改成功后询问是否立即重启 |

### 启动顺序编码

| 编码 | 启动顺序 | 适用场景 |
|------|----------|----------|
| `0xf41` | SD 卡 → USB → 重试 | 默认，从 TF 卡启动 |
| `0xf14` | USB → SD 卡 → 重试 | 从 USB SSD/NVMe 启动 |
| `0xf12` | 网络 → SD 卡 → 重试 | PXE 网络启动 |

### EEPROM 说明

- 启动顺序存储在 SPI 闪存芯片中，**与存储介质无关**
- 修改后需重启生效
- 系统损坏后仍可根据 BOOT_ORDER 回退到备用介质

---

## 📋 系统要求

| 项目 | 要求 |
|------|------|
| 架构 | arm64 / aarch64（64 位） |
| 硬件 | 树莓派 4B 或 5 |
| 存储 | 至少一个 >1GB 附加存储设备 |
| 网络 | 下载镜像需要网络连接 |

---

## 📖 典型使用场景

### 从 TF 卡迁移到 USB SSD

```bash
sudo ./rpi-image-flash.sh     # 烧录系统到 USB SSD
sudo ./rpi-boot-switch.sh     # 切换为 USB 优先 (0xf14)
sudo reboot                   # 重启后从 USB SSD 启动
```

### 从 USB SSD 回退到 TF 卡

```bash
# 当前系统运行在 USB SSD
# 通过 SSH 连接到 USB SSD 上的系统
sudo ./rpi-boot-switch.sh     # 切换为 SD 卡优先（0xf41）
sudo reboot                   # 重启后从 TF 卡启动
```

> 💡 **注意**：回退操作需要当前系统可通过 SSH 访问。建议始终保留一个可启动的 TF 卡作为应急备份。

---

## 🔒 安全特性

- **禁止覆盖当前系统盘**：自动识别并在菜单中标记为红色，无法选择
- **二次确认**：需输入大写 `YES` 才能继续
- **SHA1 校验**：下载后自动验证镜像完整性
- **官方工具**：使用 `rpi-imager` 烧录，避免 `dd` 误操作风险

---

## ❓ 常见问题

<details>
<summary>提示"仅支持 64 位系统"？</summary>

```bash
dpkg --print-architecture  # 应为 arm64
```
如为 32 位，需重新安装 64 位系统。
</details>

<details>
<summary>rpi-imager 安装失败？</summary>

```bash
sudo apt update
sudo apt install rpi-imager libopengl0
```
</details>

<details>
<summary>烧录后无法 SSH 连接？</summary>

手动检查 boot 分区配置：
```bash
sudo mount /dev/sda1 /mnt
ls -la /mnt/  # 应看到 ssh、userconf.txt、firstrun.sh
cat /mnt/userconf.txt
sudo umount /mnt
```
</details>

<details>
<summary>rpi-eeprom-config 未找到？</summary>

```bash
sudo apt install rpi-eeprom
```
</details>

<details>
<summary>手动生成密码哈希？</summary>

```bash
echo -n "你的密码" | openssl passwd -6 -stdin
```
</details>

<details>
<summary>WiFi 连接失败？</summary>

- 确认国家码正确（CN、US 等）
- 检查 SSID/密码特殊字符
- 查看日志：`sudo journalctl -u NetworkManager`
</details>

---

## 🛠 依赖说明

| 工具 | 用途 | 安装 |
|------|------|------|
| `rpi-imager` | 镜像烧录 | `sudo apt install rpi-imager` |
| `libopengl0` | rpi-imager 依赖 | 同上 |
| `curl`、`wget` | 下载 | 系统预装 |
| `openssl` | 密码加密 | 系统预装 |
| `lsblk`、`findmnt` | 磁盘检测 | 系统预装 |
| `rpi-eeprom` | EEPROM 配置 | `sudo apt install rpi-eeprom` |

---

## 📂 文件清单

| 文件 | 说明 |
|------|------|
| `rpi-image-flash.sh` | 系统刷写脚本 v4.3 |
| `rpi-boot-switch.sh` | 启动介质切换脚本 |
| `README.md` | 本说明文档 |

---

## 📜 许可证

MIT License

---

## ✍️ 致谢

基于树莓派官方 `rpi-imager` 构建，感谢 Raspberry Pi Foundation。
脚本由 DeepSeek 协助生成。