#!/usr/bin/env bash
#===============================================================================
# install-wg-access.sh  v1.0.0
# 一键安装：Docker + wg-access-server（WireGuard VPN 服务端 + Web UI 管理面板）
#
#   用法：sudo bash install-wg-access.sh [选项]      （--help 查看全部选项）
#
# 支持系统：Debian / Ubuntu 及衍生版（apt）
#           RHEL / CentOS Stream / Rocky / Alma / Fedora（dnf）
# 目标架构：x86_64 / arm64 / armv7
#===============================================================================
set -Eeuo pipefail

SCRIPT_NAME="install-wg-access.sh"
SCRIPT_VERSION="1.0.0"

# ---- 默认配置（均可用同名环境变量或命令行参数覆盖）-------------------------
WG_IMAGE_REPO="${WG_IMAGE_REPO:-place1/wg-access-server}"
# 该镜像 2021 年后不再更新；master 是多架构（amd64/arm64/armv7）且最新的一版
WG_IMAGE_TAG="${WG_IMAGE_TAG:-master}"
CONTAINER_NAME="${WG_CONTAINER_NAME:-wg-access-server}"
VOLUME_NAME="${WG_VOLUME_NAME:-wg-access-server-data}"
DATA_DIR="${WG_DATA_DIR:-/opt/wg-access-server}"
WEB_PORT="${WG_WEB_PORT:-8000}"
WG_PORT="${WG_WIREGUARD_PORT:-51820}"
ADMIN_USERNAME="${WG_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${WG_ADMIN_PASSWORD:-As100200.com}"
EXTERNAL_HOST="${WG_EXTERNAL_HOST:-}"

PASSWORD_FROM_CLI=0
RECREATE=0
DRY_RUN=0
UNINSTALL=0
PURGE=0
USE_CN_MIRROR=0

WG_PRIVATE_KEY=""
ENV_FILE=""
IMAGE=""
HTTP_TARGET=""
RUN_CMD=()

# ---- 输出辅助 ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[0;36m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log()  { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
  local code=$1 line=$2
  printf '%s[x]%s 第 %s 行执行失败（退出码 %s），安装中止。\n' "$C_RED" "$C_RESET" "$line" "$code" >&2
  printf '    排查提示：查看上面的报错原文；如已装好容器可执行 %sdocker logs %s%s 看服务日志。\n' \
    "$C_CYAN" "$CONTAINER_NAME" "$C_RESET" >&2
  exit "$code"
}
trap 'on_error $? $LINENO' ERR

usage() {
  cat <<'EOF'
用法: sudo bash install-wg-access.sh [选项]

选项:
  -p, --password <密码>      管理面板密码（默认 As100200.com；已有安装会复用旧密码）
      --user <用户名>        管理面板用户名（默认 admin）
      --web-port <端口>      Web UI 对外端口（默认 8000）
      --wg-port <端口>       WireGuard 对外 UDP 端口（默认 51820）
      --external-host <URL>  客户端配置里使用的服务器地址，例如 http://1.2.3.4:8000
                             不填则自动探测公网 IP
      --data-dir <目录>      存放凭据文件（密码/私钥）的目录（默认 /opt/wg-access-server）
      --tag <镜像标签>       镜像标签（默认 master，可换 latest / v0.4.6）
      --cn                   使用阿里云镜像站安装 docker-ce（国内 VPS 用）
      --recreate             容器已存在时删除并重建（数据卷保留，设备不用重新注册）
      --dry-run              只打印将要执行的命令，不做任何改动
      --uninstall            停止并删除容器（保留数据卷/设备与凭据）
      --purge                与 --uninstall 一起用：连数据卷和凭据目录一起删除
  -h, --help                 显示本帮助

示例:
  sudo bash install-wg-access.sh
  sudo bash install-wg-access.sh --password 'MyPass123' --cn
  sudo bash install-wg-access.sh --web-port 8080 --external-host http://vpn.example.com
  sudo bash install-wg-access.sh --uninstall --purge
EOF
}

# ---- 参数解析 ---------------------------------------------------------------
validate_port() {
  local value="$1" flag="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$flag 不是合法端口: $value"
  (( value >= 1 && value <= 65535 )) || die "$flag 超出范围 1-65535: $value"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--password)     [[ $# -ge 2 ]] || die "$1 需要一个值"; ADMIN_PASSWORD="$2"; PASSWORD_FROM_CLI=1; shift 2 ;;
      --user)            [[ $# -ge 2 ]] || die "$1 需要一个值"; ADMIN_USERNAME="$2"; shift 2 ;;
      --web-port)        [[ $# -ge 2 ]] || die "$1 需要一个值"; WEB_PORT="$2"; shift 2 ;;
      --wg-port)         [[ $# -ge 2 ]] || die "$1 需要一个值"; WG_PORT="$2"; shift 2 ;;
      --external-host)   [[ $# -ge 2 ]] || die "$1 需要一个值"; EXTERNAL_HOST="$2"; shift 2 ;;
      --data-dir)        [[ $# -ge 2 ]] || die "$1 需要一个值"; DATA_DIR="$2"; shift 2 ;;
      --tag)             [[ $# -ge 2 ]] || die "$1 需要一个值"; WG_IMAGE_TAG="$2"; shift 2 ;;
      --cn)              USE_CN_MIRROR=1; shift ;;
      --recreate)        RECREATE=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --uninstall)       UNINSTALL=1; shift ;;
      --purge)           PURGE=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *)                 die "未知参数: $1（用 --help 查看用法）" ;;
    esac
  done

  IMAGE="${WG_IMAGE_REPO}:${WG_IMAGE_TAG}"

  validate_port "$WEB_PORT" "--web-port"
  validate_port "$WG_PORT" "--wg-port"
  [[ "$ADMIN_PASSWORD" =~ ^[A-Za-z0-9._@%:+=/-]+$ ]] \
    || die "密码只允许字母、数字和 ._@%:+=/- （含空格、引号、\$ 或反斜杠请换一个）"
  if (( PURGE )) && (( ! UNINSTALL )); then
    die "--purge 必须和 --uninstall 一起使用"
  fi
}

# ---- 环境准备 ---------------------------------------------------------------
ensure_root() {
  if [[ $EUID -eq 0 ]]; then return 0; fi
  if [[ -f "$0" ]] && command -v sudo >/dev/null 2>&1; then
    info "需要 root 权限，自动切换到 sudo 重新执行…"
    exec sudo -E -- bash "$0" "$@"
  fi
  die "请用 root 运行：sudo bash $SCRIPT_NAME"
}

detect_distro() {
  [[ -r /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_LIKE="${ID_LIKE:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID}"

  if [[ "$OS_ID" == "ubuntu" || "$OS_LIKE" == *ubuntu* ]]; then
    DOCKER_REPO_DISTRO="ubuntu"
    [[ -n "${UBUNTU_CODENAME:-}" ]] && OS_CODENAME="$UBUNTU_CODENAME"
    PKG_FAMILY="apt"
  elif [[ "$OS_ID" == "debian" || "$OS_LIKE" == *debian* || "$OS_ID" == "kali" ]]; then
    DOCKER_REPO_DISTRO="debian"
    PKG_FAMILY="apt"
  elif [[ "$OS_ID" =~ ^(rhel|centos|rocky|almalinux|fedora|ol)$ || "$OS_LIKE" == *rhel* || "$OS_LIKE" == *fedora* ]]; then
    DOCKER_REPO_DISTRO="centos"
    PKG_FAMILY="dnf"
  else
    # 未知系统：先按包管理器兜底；Docker 若已可用则无需发行版支持
    if command -v apt-get >/dev/null 2>&1; then
      PKG_FAMILY="apt"; DOCKER_REPO_DISTRO="debian"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
      PKG_FAMILY="dnf"; DOCKER_REPO_DISTRO="centos"
    else
      PKG_FAMILY="none"; DOCKER_REPO_DISTRO="unknown"
    fi
  fi
  info "系统识别：${OS_PRETTY}（包管理 ${PKG_FAMILY} / docker 仓库 ${DOCKER_REPO_DISTRO} / 代号 ${OS_CODENAME:-n/a}）"
}

docker_ready() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

install_docker_apt() {
  local repo_base codename pkg_arch
  export DEBIAN_FRONTEND=noninteractive
  log "更新 apt 索引并安装依赖…"
  apt-get update -y -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release

  repo_base="https://download.docker.com/linux/${DOCKER_REPO_DISTRO}"
  (( USE_CN_MIRROR )) && repo_base="https://mirrors.aliyun.com/docker-ce/linux/${DOCKER_REPO_DISTRO}"
  codename="${OS_CODENAME:-}"
  [[ -n "$codename" ]] || codename="$(lsb_release -cs 2>/dev/null || true)"
  [[ -n "$codename" ]] || die "无法确定系统代号（VERSION_CODENAME），请手动安装 docker 后重跑"
  pkg_arch="$(dpkg --print-architecture)"

  log "添加 Docker 官方 GPG key 与软件源（$repo_base，$codename）…"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "${repo_base}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] %s %s stable\n' \
    "$pkg_arch" "$repo_base" "$codename" > /etc/apt/sources.list.d/docker.list

  log "安装 docker-ce…"
  apt-get update -y -qq
  if ! apt-get install -y -qq docker-ce docker-ce-cli containerd.io; then
    warn "官方仓库安装失败，回退到发行版自带 docker.io（版本较旧，但可正常跑本容器）"
    apt-get install -y -qq docker.io
  fi
}

install_docker_dnf() {
  local repo_url
  repo_url="https://download.docker.com/linux/${DOCKER_REPO_DISTRO}/docker-ce.repo"
  (( USE_CN_MIRROR )) && repo_url="https://mirrors.aliyun.com/docker-ce/linux/${DOCKER_REPO_DISTRO}/docker-ce.repo"

  local dnf_bin="dnf"
  command -v dnf >/dev/null 2>&1 || dnf_bin="yum"

  log "添加 Docker 仓库（$repo_url）…"
  $dnf_bin install -y -q dnf-plugins-core || $dnf_bin install -y -q yum-utils || true
  $dnf_bin config-manager --add-repo "$repo_url"

  log "安装 docker-ce…"
  if ! $dnf_bin install -y -q docker-ce docker-ce-cli containerd.io; then
    warn "官方仓库安装失败，尝试用发行版自带的 docker/podman-docker 包"
    $dnf_bin install -y -q docker || die "docker 安装失败，请手动安装后重跑本脚本"
  fi
}

ensure_docker() {
  if docker_ready; then
    info "已检测到可用的 Docker：$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "未安装 Docker，开始安装…"
    case "$PKG_FAMILY" in
      apt) install_docker_apt ;;
      dnf) install_docker_dnf ;;
      *)   die "系统 ${OS_PRETTY} 不支持自动安装 Docker（没有 apt/dnf/yum），请先手动装好 docker 再重跑本脚本" ;;
    esac
  else
    warn "docker 命令存在但守护进程未就绪，尝试启动…"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker >/dev/null 2>&1 || warn "systemctl 启动 docker 失败，稍后仍会重试"
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || warn "service 启动 docker 失败"
  fi

  local _i
  for _i in $(seq 1 30); do
    docker_ready && break
    sleep 1
  done
  docker_ready || die "Docker 守护进程未就绪，请检查 'systemctl status docker' 与 'systemctl status containerd'"
  log "Docker 就绪：$(docker version --format '{{.Server.Version}}')"
}

ensure_tun() {
  [[ -c /dev/net/tun ]] && return 0
  log "/dev/net/tun 不存在，尝试创建（容器需要 TUN 设备）…"
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
  [[ -c /dev/net/tun ]] || die "无法创建 /dev/net/tun：当前环境（如 OpenVZ/LXC 无 TUN 权限）不支持 WireGuard，请换 KVM 虚拟机或支持 TUN 的 VPS"
}

ensure_wireguard_module() {
  if [[ -d /sys/module/wireguard ]]; then
    info "WireGuard 内核模块已加载"
    return 0
  fi
  modprobe wireguard 2>/dev/null || true
  if [[ -d /sys/module/wireguard ]]; then
    info "WireGuard 内核模块已加载（本次 modprobe）"
  else
    warn "WireGuard 内核模块未加载：内核 < 5.6 需装 wireguard-dkms，否则容器内 wg0 起不来"
  fi
}

# ---- 凭据持久化 -------------------------------------------------------------
gen_private_key() {
  if command -v wg >/dev/null 2>&1; then
    wg genkey
    return 0
  fi
  docker run --rm --entrypoint wg "$IMAGE" genkey
}

load_or_create_secrets() {
  ENV_FILE="${DATA_DIR}/wg.env"
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"

  if [[ -f "$ENV_FILE" ]]; then
    local prev_password prev_key
    # shellcheck disable=SC1090
    prev_password="$(sed -n 's/^WG_ADMIN_PASSWORD=//p' "$ENV_FILE" | head -n1)"
    prev_key="$(sed -n 's/^WG_WIREGUARD_PRIVATE_KEY=//p' "$ENV_FILE" | head -n1)"
    (( PASSWORD_FROM_CLI )) || ADMIN_PASSWORD="${prev_password:-$ADMIN_PASSWORD}"
    WG_PRIVATE_KEY="$prev_key"
    [[ -n "$WG_PRIVATE_KEY" ]] && info "复用已有 WireGuard 私钥（$(basename "$ENV_FILE")），已注册设备无需重登"
  fi

  if [[ -z "$WG_PRIVATE_KEY" ]]; then
    log "生成 WireGuard 私钥…"
    WG_PRIVATE_KEY="$(gen_private_key)"
  fi
  # 32 字节 base64 → 43 个字符 + 1 个 '=' 填充，共 44 字符
  [[ "$WG_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die "私钥格式异常（应为 44 字符 base64），请删除 $ENV_FILE 后重跑"

  umask 077
  {
    printf '# wg-access-server 凭据，请勿外泄；私钥一旦变更，所有设备都需要重新注册\n'
    printf 'WG_ADMIN_USERNAME=%s\n' "$ADMIN_USERNAME"
    printf 'WG_ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD"
    printf 'WG_WIREGUARD_PRIVATE_KEY=%s\n' "$WG_PRIVATE_KEY"
  } > "$ENV_FILE"
  umask 022
  chmod 600 "$ENV_FILE"
  info "凭据已保存：$ENV_FILE"
}

resolve_external_host() {
  [[ -n "$EXTERNAL_HOST" ]] && return 0
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
      ip="$(curl -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
      [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] && break
      ip=""
    done
  fi
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$ip" ]] && warn "公网 IP 探测失败，改用本机地址 $ip（客户端可能在外部连不上，可用 --external-host 手动指定）"
  fi
  [[ -n "$ip" ]] || die "无法确定服务器地址，请用 --external-host 指定，例如 --external-host http://1.2.3.4:${WEB_PORT}"
  EXTERNAL_HOST="http://${ip}:${WEB_PORT}"
  info "客户端使用的服务器地址：$EXTERNAL_HOST"
}

# ---- 容器操作 ---------------------------------------------------------------
container_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)" == "true" ]]
}

build_run_command() {
  RUN_CMD=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    --cap-add NET_ADMIN
    --device /dev/net/tun:/dev/net/tun
    -v "${VOLUME_NAME}:/data"
    -e "WG_ADMIN_USERNAME=${ADMIN_USERNAME}"
    -e "WG_ADMIN_PASSWORD=${ADMIN_PASSWORD}"
    -e "WG_WIREGUARD_PRIVATE_KEY=${WG_PRIVATE_KEY}"
    -e "WG_WIREGUARD_PORT=${WG_PORT}"
    -e "WG_EXTERNAL_HOST=${EXTERNAL_HOST}"
    -e "WG_LOG_LEVEL=info"
    -p "${WEB_PORT}:8000/tcp"
    -p "${WG_PORT}:${WG_PORT}/udp"
    "$IMAGE"
  )
}

run_container() {
  build_run_command

  if container_exists; then
    if (( RECREATE )); then
      log "删除旧容器（数据卷 ${VOLUME_NAME} 保留）…"
      docker rm -f "$CONTAINER_NAME" >/dev/null
    else
      info "容器 $CONTAINER_NAME 已存在，沿用；如需应用新参数请加 --recreate"
      container_running || { log "启动已存在的容器…"; docker start "$CONTAINER_NAME" >/dev/null; }
      return 0
    fi
  fi

  log "拉取镜像 $IMAGE（首次约 25MB）…"
  if ! docker pull "$IMAGE"; then
    warn "镜像拉取失败。国内网络常见原因：Docker Hub 被墙/超时。"
    warn "两种办法：① 给 dockerd 配 HTTP 代理；② 配 registry-mirror（如阿里云个人镜像加速器）后重启 docker，再重跑本脚本。"
    die "docker pull $IMAGE 失败"
  fi

  log "创建并启动容器…"
  "${RUN_CMD[@]}" >/dev/null
}

http_code() {
  curl -s -o /dev/null -m 3 -w '%{http_code}' "$1" 2>/dev/null || true
}

http_ok() {
  case "$1" in 2[0-9][0-9]|3[0-9][0-9]|401) return 0 ;; *) return 1 ;; esac
}

container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$CONTAINER_NAME" 2>/dev/null \
    | awk '{print $1}'
}

wait_http() {
  command -v curl >/dev/null 2>&1 || return 0
  local _i code ip
  ip="$(container_ip)"
  for _i in $(seq 1 40); do
    # 面板根路径会 307 跳到 /signin，所以 2xx/3xx/401 都算服务已起来
    code="$(http_code "http://127.0.0.1:${WEB_PORT}/")"
    http_ok "$code" && { HTTP_TARGET="http://127.0.0.1:${WEB_PORT}/"; return 0; }
    if [[ -n "$ip" ]]; then
      code="$(http_code "http://${ip}:8000/")"
      http_ok "$code" && { HTTP_TARGET="http://${ip}:8000/（容器内网地址）"; return 0; }
    fi
    container_running || return 1
    sleep 1
  done
  return 1
}

wg_state() {
  docker exec "$CONTAINER_NAME" wg show 2>/dev/null || true
}

verify() {
  log "检查容器状态…"
  local _i
  for _i in $(seq 1 20); do
    container_running && break
    sleep 1
  done
  if ! container_running; then
    docker logs --tail 40 "$CONTAINER_NAME" 2>&1 || true
    die "容器启动后立即退出，日志见上（常见原因：NET_ADMIN/TUN 权限不足、内核无 wireguard 模块）"
  fi
  info "容器状态：$(docker inspect -f '{{.State.Status}}（重启策略 {{.HostConfig.RestartPolicy.Name}}）' "$CONTAINER_NAME")"

  # VPN 侧证据：容器内 wg0 是否真起来了
  local wg_out
  wg_out="$(wg_state)"
  if [[ "$wg_out" == *"interface: wg0"* ]]; then
    log "WireGuard 接口已就绪：$(printf '%s\n' "$wg_out" | grep -E 'listening port|public key' | tr -s ' ' | paste -sd' | ' -)"
  else
    warn "容器内 wg0 未就绪，可能缺少 NET_ADMIN/TUN 或内核无 wireguard 模块；日志如下："
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
  fi

  # Web 侧证据
  if wait_http; then
    log "Web 面板已响应：${HTTP_TARGET}"
  else
    warn "容器在运行但 Web 面板 40 秒内未响应，最近日志如下："
    docker logs --tail 30 "$CONTAINER_NAME" 2>&1 || true
  fi

  # 端口映射由 docker 自己报告，比在宿主机查 socket 更可靠
  info "端口映射：$(docker port "$CONTAINER_NAME" 2>/dev/null | tr '\n' ' ')"
}

firewall_hints() {
  local opened=0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "检测到 ufw 已启用，放行端口需要执行："
    printf '    ufw allow %s/tcp\n    ufw allow %s/udp\n' "$WEB_PORT" "$WG_PORT"
    opened=1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    info "检测到 firewalld 正在运行，放行端口需要执行："
    printf '    firewall-cmd --permanent --add-port=%s/tcp\n    firewall-cmd --permanent --add-port=%s/udp\n    firewall-cmd --reload\n' \
      "$WEB_PORT" "$WG_PORT"
    opened=1
  fi
  if (( opened )); then
    warn "脚本不会自动改防火墙；如为云服务器，还需在控制台安全组放行 TCP ${WEB_PORT} 与 UDP ${WG_PORT}"
  else
    info "未检测到本机防火墙规则；云服务器记得在安全组放行 TCP ${WEB_PORT} 与 UDP ${WG_PORT}"
  fi
}

print_summary() {
  local ip_hint="$EXTERNAL_HOST"
  printf '\n%s================ 安装完成 ================%s\n' "$C_GREEN" "$C_RESET"
  printf '  Web 管理面板 : %s%s%s\n' "$C_CYAN" "$ip_hint" "$C_RESET"
  printf '  面板用户名   : %s\n' "$ADMIN_USERNAME"
  printf '  面板密码     : %s%s%s\n' "$C_YELLOW" "$ADMIN_PASSWORD" "$C_RESET"
  printf '  WireGuard    : UDP %s\n' "$WG_PORT"
  printf '  凭据文件     : %s（含私钥，权限 600）\n' "$ENV_FILE"
  printf '  数据卷       : %s\n' "$VOLUME_NAME"
  printf '  常用命令     : docker logs -f %s | docker restart %s | docker exec -it %s wg show\n' \
    "$CONTAINER_NAME" "$CONTAINER_NAME" "$CONTAINER_NAME"
  printf '%s==========================================%s\n' "$C_GREEN" "$C_RESET"
  if [[ "$ADMIN_PASSWORD" == "As100200.com" ]]; then
    warn "当前使用的是脚本内置默认密码，暴露在公网上风险很高，建议改成自己的："
    printf '    sudo bash %s --password '"'"'你的新密码'"'"' --recreate\n' "$SCRIPT_NAME"
  fi
  cat <<EOF

下一步：
  1. 浏览器打开上面的面板地址，用上述用户名/密码登录；
  2. 「Devices」里新增设备，下载配置或直接扫码（手机 WireGuard App）；
  3. 客户端配置里的 Endpoint 取自 WG_EXTERNAL_HOST，若域名/端口变了：
     sudo bash $SCRIPT_NAME --external-host http://新地址:${WEB_PORT} --recreate
  4. 忘记密码：直接改 $ENV_FILE 里的 WG_ADMIN_PASSWORD 后 --recreate 重建。

EOF
}

# ---- 卸载 -------------------------------------------------------------------
do_uninstall() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker，无法卸载容器"
  if container_exists; then
    log "停止并删除容器 $CONTAINER_NAME…"
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    info "容器 $CONTAINER_NAME 不存在，跳过"
  fi
  if (( PURGE )); then
    warn "删除数据卷 $VOLUME_NAME（所有已注册设备与配置将丢失）"
    docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || info "数据卷不存在或仍被占用"
    if [[ -d "$DATA_DIR" ]]; then
      rm -rf "$DATA_DIR"
      info "已删除凭据目录 $DATA_DIR"
    fi
  else
    info "数据卷 $VOLUME_NAME 与凭据目录 $DATA_DIR 已保留"
  fi
  log "卸载完成"
}

# ---- dry-run ----------------------------------------------------------------
print_dry_run() {
  printf '%s[dry-run]%s 不做任何改动，仅展示将要执行的步骤：\n\n' "$C_CYAN" "$C_RESET"
  cat <<EOF
 1) 确认 root 权限（非 root 时自动 sudo 重跑）
 2) 识别系统 → 需要时安装 docker-ce + containerd.io 并启动 docker
 3) 确保 /dev/net/tun 存在、尝试 modprobe wireguard
 4) 读取或生成凭据：$DATA_DIR/wg.env
      WG_ADMIN_USERNAME=$ADMIN_USERNAME
      WG_ADMIN_PASSWORD=$ADMIN_PASSWORD
      WG_WIREGUARD_PRIVATE_KEY=<已有则复用，否则新生成>
 5) 创建容器（镜像 $IMAGE）：
EOF
  # 私钥不打印内容，只展示占位
  RUN_CMD=(
    docker run -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    --cap-add NET_ADMIN
    --device /dev/net/tun:/dev/net/tun
    -v "${VOLUME_NAME}:/data"
    -e "WG_ADMIN_USERNAME=${ADMIN_USERNAME}"
    -e "WG_ADMIN_PASSWORD=${ADMIN_PASSWORD}"
    -e "WG_WIREGUARD_PRIVATE_KEY=<43 字节 base64 私钥>"
    -e "WG_WIREGUARD_PORT=${WG_PORT}"
    -e "WG_EXTERNAL_HOST=${EXTERNAL_HOST:-http://<公网IP>:${WEB_PORT}}"
    -e "WG_LOG_LEVEL=info"
    -p "${WEB_PORT}:8000/tcp"
    -p "${WG_PORT}:${WG_PORT}/udp"
    "$IMAGE"
  )
  printf '    '; printf '%q ' "${RUN_CMD[@]}"; printf '\n\n'
  printf ' 6) 校验容器状态、wg0 接口与 http://127.0.0.1:%s/ 的响应\n' "$WEB_PORT"
  printf ' 7) 打印面板地址/密码与防火墙放行提示\n\n'
  printf '国内镜像站（--cn）：%s\n' "$( (( USE_CN_MIRROR )) && echo 已启用 || echo 未启用 )"
  printf '重用已有容器（--recreate）：%s\n' "$( (( RECREATE )) && echo 是 || echo 否 )"
}

# ---- 主流程 -----------------------------------------------------------------
main() {
  parse_args "$@"

  if (( UNINSTALL )); then
    ensure_root "$@"
    do_uninstall
    exit 0
  fi

  if (( DRY_RUN )); then
    print_dry_run
    exit 0
  fi

  ensure_root "$@"
  log "$SCRIPT_NAME v$SCRIPT_VERSION 开始执行"
  detect_distro
  ensure_docker
  ensure_tun
  ensure_wireguard_module
  load_or_create_secrets
  resolve_external_host
  run_container
  verify
  firewall_hints
  print_summary
}

main "$@"
