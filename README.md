# install-wg-access

一键在 Linux 服务器上装好 **Docker + [wg-access-server](https://github.com/place1/wg-access-server)**（WireGuard VPN 服务端 + Web 管理面板）。

## 一行安装

```bash
curl -fsSL https://raw.githubusercontent.com/TikTok365/install-wg-access/main/install-wg-access.sh | sudo bash
```

不带参数时：面板密码 `As100200.com`，Web 面板 `8000/tcp`，WireGuard `51820/udp`，服务器地址自动探测公网 IP。

> 默认密码只是为了能立刻登录，装完请换掉。建议按下面的方式带参数调用。

## 推荐：先下载再看，再执行

```bash
curl -fsSLO https://raw.githubusercontent.com/TikTok365/install-wg-access/main/install-wg-access.sh
less install-wg-access.sh          # 建议过一眼
sudo bash install-wg-access.sh --password '你的强密码'
```

## 常用参数

```bash
# 国内 VPS：docker 走阿里云镜像站
sudo bash install-wg-access.sh --password 'YourPass' --cn

# 自定义端口 + 指定客户端连接地址（有域名时用域名）
sudo bash install-wg-access.sh \
  --password 'YourPass' \
  --web-port 8080 \
  --wg-port 51821 \
  --external-host http://vpn.example.com:8080

# 只看看会做什么，不改系统
bash install-wg-access.sh --dry-run

# 改配置后重建容器（数据卷保留，已注册设备不掉线）
sudo bash install-wg-access.sh --password 'NewPass' --recreate

# 卸载
sudo bash install-wg-access.sh --uninstall          # 保留设备与凭据
sudo bash install-wg-access.sh --uninstall --purge  # 全部删除
```

| 参数 | 说明 | 默认 |
|---|---|---|
| `-p, --password <密码>` | 面板密码 | `As100200.com` |
| `--user <用户名>` | 面板用户名 | `admin` |
| `--web-port <端口>` | Web 面板端口 | `8000` |
| `--wg-port <端口>` | WireGuard UDP 端口 | `51820` |
| `--external-host <URL>` | 客户端配置里的服务器地址 | 自动探测公网 IP |
| `--data-dir <目录>` | 凭据文件目录 | `/opt/wg-access-server` |
| `--tag <标签>` | 镜像标签 | `master` |
| `--cn` | 用阿里云镜像站装 docker-ce | 关闭 |
| `--recreate` | 删除并重建容器（数据卷保留） | 关闭 |
| `--dry-run` | 只打印命令不执行 | 关闭 |
| `--uninstall` / `--purge` | 卸载 / 连数据一起删 | 关闭 |

## 装完之后

1. 浏览器打开 `http://<服务器IP>:8000`，用安装时打印的用户名/密码登录。
2. 面板里 **Devices → 新增设备**，下载 `.conf` 或直接扫码（手机 WireGuard App）。
3. 客户端配置里的 `Endpoint` 来自 `WG_EXTERNAL_HOST`。地址或端口变了，用 `--external-host ... --recreate` 重跑。

凭据存在 `/opt/wg-access-server/wg.env`（权限 600）：

```
WG_ADMIN_USERNAME=admin
WG_ADMIN_PASSWORD=...
WG_WIREGUARD_PRIVATE_KEY=...
```

私钥一旦变更，**所有已注册设备都要重新注册**。脚本重跑时会自动复用这个文件里的私钥，不用手动管。

## 支持范围

- **系统**：Debian / Ubuntu 及衍生版（apt），RHEL / CentOS Stream / Rocky / Alma / Fedora（dnf）。其他系统只要已经装好 Docker 也能直接跑。
- **架构**：amd64 / arm64 / armv7（对应镜像标签 `master`）。`--tag latest` 只有 amd64。
- **需要 root**，非 root 会自动 `sudo` 重跑。
- **需要 TUN 支持**。OpenVZ 等无 TUN 的容器型 VPS 跑不了 WireGuard，脚本会提前报错而不是装到一半失败。

## 常见问题

**面板打不开？** 云服务器要在控制台安全组放行 TCP 8000 与 UDP 51820；本机 ufw/firewalld 也要放行，脚本会打印对应命令但不会自动改防火墙。

**`docker pull` 失败？** Docker Hub 在国内常被墙。给 dockerd 配 HTTP 代理，或配 registry-mirror（如阿里云个人镜像加速器）后重启 docker，再重跑脚本。

**容器起来了但 wg0 没就绪？** 多半是内核 `< 5.6` 且没装 `wireguard-dkms`，或者缺 `NET_ADMIN` / `/dev/net/tun`。看 `docker logs wg-access-server`。

**忘记密码？** 直接改 `/opt/wg-access-server/wg.env` 里的 `WG_ADMIN_PASSWORD`，然后 `--recreate`。

## 与常见教程的差异

网上流传的教程一般是这条：

```bash
docker run -it --rm ... place1/wg-access-server
```

它有几个硬伤，本脚本都修了：

- `-it --rm`：前台交互运行，SSH 一断开容器就没了 → 改成 `-d --restart unless-stopped`。
- `wg genkey` 依赖宿主机装了 wireguard-tools → 改成用镜像里的 `wg`。
- 私钥不落盘，重跑就变，**所有设备掉线** → 落盘复用。
- 没设 `WG_EXTERNAL_HOST`，客户端配置里的 Endpoint 是错的，连不上 → 自动探测或手动指定。
- `latest` 标签 2021 年后停更，且只有 amd64 → 默认用多架构的 `master`。

## 许可

脚本本身随你使用。`wg-access-server` 由其作者 [place1](https://github.com/place1/wg-access-server) 维护，注意该项目已多年未更新。
