#!/usr/bin/env bash
# setup-named-tunnel.sh
# 在 InstaBox 机器（Debian / Ubuntu）上一键搭建 Cloudflare 命名隧道，
# 把本地服务以「固定域名」发布出去，替代地址会随机器暂停失效的快速隧道。
#
# 前置条件：
#   1. 一个已经托管到 Cloudflare 的域名（免费域名也可，需能改 NS、
#      后缀在公共后缀名单 PSL 里）；
#   2. 一台能打开浏览器登录 Cloudflare 的设备（授权要用）。
#
# 用法： sudo bash setup-named-tunnel.sh
# 脚本会依次询问：隧道名、要绑定的子域名、本地服务端口。

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 sudo 运行： sudo bash setup-named-tunnel.sh"
  exit 1
fi

CF_DIR=/root/.cloudflared
BIN=/usr/local/bin/cloudflared
mkdir -p "$CF_DIR"

echo "=== 参数 ==="
read -r -p "隧道名（默认 instabox）: " TUNNEL_NAME
TUNNEL_NAME=${TUNNEL_NAME:-instabox}

HOSTNAME=""
while [ -z "$HOSTNAME" ]; do
  read -r -p "要绑定的子域名（如 tun.example.com）: " HOSTNAME
done

read -r -p "本地服务端口（默认 8080）: " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8080}

echo
echo "隧道名:   $TUNNEL_NAME"
echo "子域名:   $HOSTNAME"
echo "本地服务: http://localhost:$LOCAL_PORT"
echo

echo "=== 1/6 检查 cloudflared ==="
if [ ! -x "$BIN" ]; then
  case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
  echo "正在下载 cloudflared ($ARCH) ..."
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH" -o "$BIN"
  chmod +x "$BIN"
fi
"$BIN" --version

echo "=== 2/6 证书（cert.pem）==="
if [ -f "$CF_DIR/cert.pem" ]; then
  echo "已存在 cert.pem，跳过授权。"
else
  cat <<'EOF'
接下来会显示一个授权链接（https://dash.cloudflare.com/argotunnel?...）。
在任意设备的浏览器里打开它，登录 Cloudflare，选择你托管的域名并授权，
证书会自动下载到本机。授权完成后回到这里继续。
EOF
  "$BIN" tunnel login
fi

echo "=== 3/6 创建 / 复用命名隧道 ==="
if "$BIN" tunnel info "$TUNNEL_NAME" >/dev/null 2>&1; then
  echo "隧道 $TUNNEL_NAME 已存在，复用。"
else
  "$BIN" tunnel create "$TUNNEL_NAME"
fi
TUNNEL_ID=$("$BIN" tunnel info "$TUNNEL_NAME" | awk '/^ID:/ {print $2}')
CRED="$CF_DIR/$TUNNEL_ID.json"
echo "隧道 ID: $TUNNEL_ID"
echo "凭据文件: $CRED"

echo "=== 4/6 写配置并校验 ==="
if [ -f "$CF_DIR/config.yml" ]; then
  cp "$CF_DIR/config.yml" "$CF_DIR/config.yml.bak.$(date +%Y%m%d%H%M%S)"
  echo "旧 config.yml 已备份。"
fi
cat > "$CF_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED
ingress:
  - hostname: $HOSTNAME
    service: http://localhost:$LOCAL_PORT
  - service: http_status:404
EOF
"$BIN" tunnel --config "$CF_DIR/config.yml" ingress validate

echo "=== 5/6 配置 DNS 路由 ==="
if ! "$BIN" tunnel route dns "$TUNNEL_NAME" "$HOSTNAME"; then
  echo "警告：DNS 路由添加失败，多半是该子域名已有冲突的 DNS 记录。"
  echo "到 Cloudflare 后台删掉 $HOSTNAME 的旧记录后，手动重跑："
  echo "  cloudflared tunnel route dns $TUNNEL_NAME $HOSTNAME"
fi

echo "=== 6/6 安装 systemd 服务 ==="
cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=Cloudflare Named Tunnel ($TUNNEL_NAME)
After=network.target

[Service]
Type=simple
ExecStart=$BIN tunnel --no-autoupdate --config $CF_DIR/config.yml run $TUNNEL_NAME
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cf-tunnel
sleep 5
systemctl is-active cf-tunnel

echo
"$BIN" tunnel info "$TUNNEL_NAME" || true
echo
echo "完成。在浏览器打开 https://$HOSTNAME 验证你的本地服务。"
echo "提示：机器闲置暂停后，先访问一次官方公开端口地址把机器唤醒，"
echo "      等十几秒，固定地址会自动恢复（地址不会变）。"
