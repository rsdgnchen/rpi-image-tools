# rpi-image-flash.sh

> 📀 一个为异地无头树莓派设计系统镜像刷写脚本

在**无法物理接触树莓派、没有桌面环境**的情况下，安全地将 Raspberry Pi OS 烧录到 SD卡 / USB SSD / NVMe 等存储设备，并完成 **SSH、用户密码、WiFi** 等无头预配置。

✅ 全程交互式引导  
✅ 自动获取最新镜像列表（仅支持64位）  
✅ 自动安装 `rpi-imager` 依赖  
✅ 多重安全保护：禁止覆盖当前系统盘  
✅ 支持 SD 卡、USB SSD、NVMe 等设备  
✅ 镜像缓存复用，省时省流量  

---

## 📋 前置要求

- **树莓派系统**：Raspberry Pi OS (64-bit)，架构为 `arm64` 或 `aarch64`
- **网络连接**：需要能够访问外网（用于下载镜像和依赖）
- **附加存储**：至少一个容量 >1GB 的 USB SSD / NVMe / SD 卡
- **基础工具**：`curl`、`wget`、`openssl`、`lsblk`、`findmnt`（通常已预装）

---

## 🚀 快速开始

```bash
# 1. 下载脚本
curl -O http://192.168.31.8:3000/yaha/rpi-image-tools/raw/branch/main/rpi-image-flash.sh

# 2. 赋予执行权限
chmod +x rpi-image-flash.sh

# 3. 以 root 权限运行
sudo ./rpi-image-flash.sh
```

接下来按照提示选择镜像、目标设备并配置账号即可。

---

## 📖 详细流程说明

1. **系统架构检查**  
   脚本会强制要求 64 位系统，32 位不支持。

2. **依赖安装**  
   自动检测并安装 `rpi-imager` 和 `libopengl0`（如果缺失）。

3. **选择镜像**  
   - 优先在线获取官方最新 64 位镜像列表（按发布日期排序）
   - 如果网络失败，自动回退到内置的两个镜像（Lite / Full）
   - 支持输入**自定义镜像 URL**

4. **选择目标设备**  
   脚本会列出所有容量大于 1GB 的存储设备，并**用红色标记当前系统盘**，防止误操作。

5. **最终确认**  
   需要输入大写的 `YES` 才能继续，避免误触。

6. **下载与烧录**  
   镜像下载到 `/tmp` 并缓存，下次使用可直接跳过下载。烧录使用官方 `rpi-imager`，安全可靠。

7. **预配置**  
   烧录完成后自动挂载 boot 分区，写入：
   - `ssh`（空文件，启用 SSH）
   - `userconf.txt`（用户名 + 加密密码）
   - `wpa_supplicant.conf`（可选，WiFi 配置）

8. **切换启动介质**  
```bash
curl -O http://192.168.31.8:3000/yaha/rpi-image-tools/raw/branch/main/rpi-boot-switch.sh && chmod +x rpi-boot-switch.sh && sudo ./rpi-boot-switch.sh
```

---

## ⚙️ 预配置参数说明

| 配置项 | 说明 |
|--------|------|
| SSH 开启 | 自动创建 `ssh` 文件，开机即启用 SSH 服务 |
| 用户与密码 | 交互式输入，密码使用 SHA-512 加密（`openssl passwd -6`） |
| WiFi | 可选，支持 2.4G / 5G，需输入 SSID、密码及国家码（默认 CN） |

---
## 启动顺序编码说明

| 选项 | 编码 | 启动顺序 |
| :--- | :--- | :--- |
| 1 | `0xf41` | SD 卡 → USB → 重试 |
| 2 | `0xf14` | USB → SD 卡 → 重试 |
| 3 | `0xf12` | 网络 → SD 卡 → 重试 |

- **0xf41**: 优先从 SD 卡启动，若失败则尝试 USB，再失败则循环重试。
- **0xf14**: 优先从 USB 设备启动，若失败则尝试 SD 卡，再失败则循环重试。
- **0xf12**: 优先从网络启动，若失败则尝试 SD 卡，再失败则循环重试。

## 注意事项

- 修改后必须**重启**才能生效。
- 切换启动介质脚本仅用于树莓派 4B。
- 需提前安装 `rpi-eeprom` 工具：
  ```bash
  sudo apt update && sudo apt install rpi-eeprom
  ```

---

## 🔒 安全特性

- **禁止覆盖当前系统盘**
  自动识别运行系统的磁盘并在菜单中禁用，无需担心误刷。
- **二次确认**
  最终确认时必须输入大写 `YES`，任何其他输入都会取消。
- **依赖官方工具**
  烧录使用 `rpi-imager`，避免 `dd` 误操作风险。

---

## ❓ 常见问题

<details>
<summary><b>提示“rpi-imager 未找到”或安装失败？</b></summary>

手动执行：
```bash
sudo apt update
sudo apt install rpi-imager libopengl0
```
如果仍然失败，请确认系统为 64 位，并已启用 apt 源。
</details>

<details>
<summary><b>如何确认新系统的 SSH 配置是否正确？</b></summary>

烧录完成后，脚本会挂载 boot 分区，你可以手动检查：
```bash
ls /mnt
# 应该看到 ssh、userconf.txt、wpa_supplicant.conf（如果配置了 WiFi）
```
</details>

<details>
<summary><b>忘记手动生成密码哈希怎么办？</b></summary>

脚本已自动使用 `openssl passwd -6` 生成，无需手动操作。若需自行生成：
```bash
echo -n '你的密码' | openssl passwd -6 -stdin
```
</details>

<details>
<summary><b>提示“设备未出现”或挂载失败？</b></summary>

脚本内置了 15 秒等待和 5 次挂载重试。如果仍然失败，请检查目标设备的连接和供电。
</details>

---

## 🛠 脚本依赖（自动安装）

| 工具 | 用途 | 安装方式 |
|------|------|----------|
| `rpi-imager` | 镜像烧录 | `sudo apt install rpi-imager` |
| `libopengl0` | rpi-imager 依赖 | 同上 |
| `curl`, `wget` | 网络下载 | 系统通常已预装 |
| `openssl` | 密码加密 | 系统通常已预装 |
| `lsblk`, `findmnt` | 磁盘信息 | 系统通常已预装 |

---

## 📂 仓库文件

- `rpi-image-flash.sh` – 主脚本（完整功能）
- `README.md` – 本说明文档

---

## 📜 许可证

MIT License © 2026

---

## ✍️ 致谢

基于树莓派官方 `rpi-imager` 工具构建，感谢 Raspberry Pi Foundation。
脚本由 DeepSeek-v4 协助生成。
