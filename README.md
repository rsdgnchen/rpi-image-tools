# rpi-image-tools

树莓派异地无头系统刷写工具

## 脚本说明

用于异地无头环境下，将 Raspberry Pi OS 镜像烧录至 USB SSD/NVMe 等介质，并自动完成 SSH、用户密码、WiFi 等预配置。解决无法物理接触树莓派、无桌面环境时的系统重装问题。

**运行环境要求：**

- Raspberry Pi OS (64-bit) / arm64 或 aarch64 架构
- 系统已连接网络
- 至少有一个 >1GB 的附加存储设备（USB SSD、NVMe 等）

## 快速使用

```bash
# 下载j脚本
curl -O http://192.168.31.8:3000/yaha/rpi-image-tools/raw/branch/main/rpi-image-flash.sh

# 赋予可执行权限
chmod +x rpi-image-flash.sh

# 以 root 权限执行脚本
sudo ./rpi-image-flash.sh
```

## 功能特性

| 特性 | 说明 |
|------|------|
| 自动安装依赖 | 检测并安装 `rpi-imager` 和 `libopengl0` |
| 镜像缓存复用 | 下载的镜像缓存至 `/tmp`，避免重复下载 |
| 安全保护 | 自动识别当前系统盘，禁止向其写入 |
| 多设备支持 | 支持 SD 卡 (`sd*`)、eMMC (`mmcblk*`)、NVMe (`nvme*`) |
| 无头预配置 | 烧录后自动配置 SSH、用户名密码、WiFi |
| 交互式选择 | 镜像类型、目标设备、预配置参数均可交互输入 |

## 镜像类型说明

| 选项 | 镜像 | 用途 |
|------|------|------|
| 1 | Raspberry Pi OS Lite (64-bit) | 无桌面版，适合服务器/嵌入式场景 |
| 2 | Raspberry Pi OS Full (64-bit) | 桌面版，包含推荐软件 |

## 预配置参数说明

脚本烧录完成后会自动挂载 boot 分区并写入以下配置文件：

| 配置文件 | 作用 |
|----------|------|
| `ssh` | 空文件，启用 SSH 服务 |
| `userconf.txt` | 格式 `用户名:加密密码`，首次启动创建用户 |
| `wpa_supplicant.conf` | WiFi 配置（SSID、密码、国家码） |

## 注意事项

- 必须使用 `sudo` 或以 root 身份运行
- 选择目标设备时**仔细核对**，避免误写当前系统盘
- 最终确认需要输入大写 `YES`，防止误操作
- 密码加密使用 `openssl passwd -6` (SHA-512)
- 烧录完成后需要**重启**并从新介质启动

## 常见问题排查

**安装 rpi-imager 失败：**

```bash
sudo apt update
sudo apt install rpi-imager libopengl0
```

**手动挂载 boot 分区检查配置：**

```bash
# 查看目标设备的分区
lsblk

# 挂载 boot 分区（假设 /dev/sda1）
sudo mount /dev/sda1 /mnt
ls /mnt/  # 应看到 ssh、userconf.txt 等文件
sudo umount /mnt
```

**手动生成密码哈希：**

```bash
echo -n "你的密码" | openssl passwd -6 -stdin
```

**查看当前系统运行磁盘：**

```bash
findmnt -n -o SOURCE /
lsblk -no PKNAME $(findmnt -n -o SOURCE /)
```

## 典型使用场景

当前系统运行在 TF 卡 (Lite 版)，需要将 USB SSD 重写为桌面版并预配置 SSH 便于异地登录：

1. 确认当前从 TF 卡启动（SSH 可连）
2. 上传脚本并执行 `sudo ./rpi-image-flash.sh`
3. 选择镜像类型 `2` (Full 桌面版)
4. 选择目标设备 USB SSD（避开 TF 卡）
5. 输入用户名、密码（可选 WiFi）
6. 等待烧录完成
7. 重启并从 USB SSD 启动
8. 通过 SSH 登录桌面版系统

## 脚本源码

完整的脚本内容请查看 [rpi-image-flash.sh](rpi-image-flash.sh)。

---

_创建日期：2026年4月24日_

