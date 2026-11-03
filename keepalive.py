#!/usr/bin/env python3
"""InstaBox 活动租约保活（单次运行版，配合 cron 使用）。

原理：InstaBox 免费机闲置一段时间会被平台自动暂停。平台提供官方
「活动租约」(activity lease) 接口：只要有一份有效租约，机器就被
视为在使用中；租约还能按平台规则唤醒已被闲置暂停的机器。

注意租约的边界（平台规则）：
- 不取消手动暂停 / 停止；
- 不取消单次连续运行上限（免费档 480 分钟）与之后的强制冷却；
- 不取消归档 / 回收规则。
所以保活是「减少日常暂停」，不是「永不下线」。

用法（在任意一台常开的机器上，如家里的 NAS）：
    export INSTABOX_API_KEY=ibk_xxx        # 控制台创建的 API Key
    export INSTABOX_MACHINE_ID=m_xxx       # 可选，不填则自动取第一台机器
    python3 keepalive.py

配合 cron 每 5 分钟跑一次：
    */5 * * * * INSTABOX_API_KEY=ibk_xxx /usr/bin/python3 /path/keepalive.py >> /var/log/instabox-keepalive.log 2>&1

API Key 建议用受限权限创建（机器读 + 写即可，不要给删除权），
并且只保存在控制端本机，不要提交到任何仓库。

接口口径（2026-11 实测，来自平台官方 API）：
- 基址 https://api.instabox.sh，鉴权头 X-API-Key（不是 Bearer）
- 续租/建租 PUT /v1/machines/{machineId}/activity-leases/{leaseId}
  body {"ttlSeconds": 900}，TTL 允许 30-3600 秒
- 401 = Key 失效；403 = 权限不足（需 machines:write）；
  409 = 平台操作进行中，下一轮再试；429 = 限流，下一轮再试
"""

import hashlib
import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone

API_BASE = os.environ.get("INSTABOX_API_BASE", "https://api.instabox.sh")
API_KEY = os.environ.get("INSTABOX_API_KEY", "")
TTL = int(os.environ.get("INSTABOX_LEASE_TTL", "900"))
TTL = max(30, min(3600, TTL))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """拒绝重定向：避免 X-API-Key 被带到其他域名。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


opener = urllib.request.build_opener(NoRedirect)


def log(msg):
    now = datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S %z")
    print(f"{now} {msg}", flush=True)


def call(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API_BASE + path, data=data, method=method)
    req.add_header("X-API-Key", API_KEY)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with opener.open(req, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            payload = json.loads(e.read().decode() or "{}")
        except Exception:
            payload = {}
        return e.code, payload


def pick_machine_id():
    mid = os.environ.get("INSTABOX_MACHINE_ID", "")
    if mid:
        return mid
    status, payload = call("GET", "/v1/machines")
    if status != 200:
        log(f"ERROR list machines failed: HTTP {status} {payload}")
        sys.exit(2)
    machines = payload.get("machines") or payload.get("data") or payload
    if isinstance(machines, dict):
        machines = [machines]
    if not machines:
        log("ERROR no machines found on this account")
        sys.exit(2)
    return machines[0].get("id") or machines[0].get("machineId")


def main():
    if not API_KEY:
        log("ERROR INSTABOX_API_KEY is not set")
        sys.exit(2)

    machine_id = pick_machine_id()

    status, payload = call("GET", f"/v1/machines/{machine_id}")
    if status in (401, 403):
        log(f"ERROR auth failed: HTTP {status} {payload}")
        sys.exit(1)
    if status != 200:
        log(f"ERROR get machine failed: HTTP {status} {payload}")
        sys.exit(2)

    state = payload.get("state") or payload.get("status") or "unknown"
    if state not in ("running", "suspended"):
        log(f"SKIP state={state} (lease only applies to running/suspended)")
        return

    lease_id = os.environ.get("INSTABOX_LEASE_ID") or (
        "keepalive-" + hashlib.sha256(machine_id.encode()).hexdigest()[:16]
    )
    status, payload = call(
        "PUT",
        f"/v1/machines/{machine_id}/activity-leases/{lease_id}",
        {"ttlSeconds": TTL},
    )
    if status in (401, 403):
        log(f"ERROR auth failed on lease: HTTP {status} {payload}")
        sys.exit(1)
    if status in (409, 429):
        log(f"RETRY-LATER state={state} lease HTTP {status} (next round)")
        return
    if status not in (200, 201):
        log(f"ERROR lease failed: HTTP {status} {payload}")
        sys.exit(2)

    expires = payload.get("expiresAt", "?")
    log(f"OK state={state} lease renewed until {expires}")


if __name__ == "__main__":
    main()
