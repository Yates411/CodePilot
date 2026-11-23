#!/usr/bin/env python3
"""
CodePilot Unix Domain Socket 联调模拟脚本。
用法示例：
  python3 scripts/mock_event.py running --title "重构认证模块"
  python3 scripts/mock_event.py waiting_user --message "等待批准终端命令"
  python3 scripts/mock_event.py completed
  python3 scripts/mock_event.py demo   # 一键跑完 running -> waiting_user -> running -> completed
"""
import argparse
import json
import os
import socket
import sys
import time

DEFAULT_SOCKET = os.path.expanduser("~/.codepilot/events.sock")


def send_event(sock_path: str, payload: dict) -> dict:
    line = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(5.0)
        s.connect(sock_path)
        s.sendall(line)
        resp = b""
        while not resp.endswith(b"\n"):
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
    return json.loads(resp.decode("utf-8")) if resp else {"ok": False, "error": "empty_ack"}


def main():
    parser = argparse.ArgumentParser(description="Send mock AI task events to CodePilot")
    parser.add_argument("action", choices=["running", "waiting_user", "completed", "error", "heartbeat", "remove", "demo"])
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    parser.add_argument("--source", default="antigravity")
    parser.add_argument("--session", default="mock-session-1")
    parser.add_argument("--task", default="main")
    parser.add_argument("--epoch", default="mock-epoch-1")
    parser.add_argument("--seq", type=int, default=int(time.time()))
    parser.add_argument("--title", default="CodePilot 联调测试任务")
    parser.add_argument("--message", default=None)
    args = parser.parse_args()

    if args.action == "demo":
        steps = [
            (1, "running", "正在运行单元测试…"),
            (2, "waiting_user", "等待确认数据库迁移方案"),
            (3, "running", "继续应用迁移并构建…"),
            (4, "completed", "全部测试通过，任务完成"),
        ]
        for seq, status, msg in steps:
            payload = {
                "v": 1,
                "type": "upsert",
                "source": args.source,
                "epoch": args.epoch,
                "sessionId": args.session,
                "taskId": args.task,
                "seq": seq,
                "status": status,
                "title": args.title,
                "message": msg,
                "ts": time.time(),
            }
            ack = send_event(args.socket, payload)
            print(f"[{status}] seq={seq} -> ack={ack}")
            time.sleep(1.0)
        return

    event_type = "upsert"
    status = args.action
    if args.action in ("heartbeat", "remove"):
        event_type = args.action
        status = None

    payload = {
        "v": 1,
        "type": event_type,
        "source": args.source,
        "epoch": args.epoch,
        "sessionId": args.session,
        "taskId": args.task,
        "seq": args.seq,
        "title": args.title,
        "ts": time.time(),
    }
    if status is not None:
        payload["status"] = status
    if args.message is not None:
        payload["message"] = args.message

    ack = send_event(args.socket, payload)
    print(json.dumps(ack, ensure_ascii=False))
    if not ack.get("ok"):
        sys.exit(1)


if __name__ == "__main__":
    main()
