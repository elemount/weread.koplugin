#!/usr/bin/env python3
"""Interactively verify the e-ink APK's native WeChat QR login flow.

This contacts WeRead and WeChat services and creates a real login session. Do
not run it unless you intend to authorize this device with your account.
"""

from __future__ import annotations

import base64
import hashlib
import json
import secrets
import tempfile
import time
import urllib.parse
from pathlib import Path

import requests


NATIVE_BASE = "https://i.weread.qq.com"
WECHAT_QR_URL = "https://open.weixin.qq.com/connect/sdk/qrconnect"
WECHAT_POLL_URL = "https://long.open.weixin.qq.com/connect/l/qrconnect"
WECHAT_APP_ID = "wxab9b71ad2b90ff34"
WECHAT_SCOPE = "snsapi_userinfo,snsapi_friend,snsapi_favorites"
HEADERS = {
    "Accept": "application/json, text/plain, */*",
    "Origin": "https://weread.qq.com",
    "Referer": "https://weread.qq.com/",
}


def request_json(session: requests.Session, url: str, *, timeout: int = 20,
                 headers: dict[str, str] | None = None) -> dict:
    response = session.get(url, headers=headers, timeout=timeout)
    response.raise_for_status()
    data = response.json()
    if not isinstance(data, dict):
        raise RuntimeError("service returned a non-object JSON response")
    return data


def complete_login(session: requests.Session, code: str) -> dict:
    device_id = secrets.token_hex(16)
    timestamp = int(time.time() * 1000)
    random_value = secrets.randbelow(1000)
    signature = hashlib.sha256(
        f"{timestamp}{device_id}{random_value}".encode("utf-8")
    ).hexdigest()
    response = session.post(
        NATIVE_BASE + "/login",
        headers={**HEADERS, "Content-Type": "application/json;charset=UTF-8"},
        json={
            "code": code,
            "deviceId": device_id,
            "trackId": "",
            "timestamp": timestamp,
            "random": random_value,
            "signature": signature,
            "isFromQrcode": 1,
            "isAutoLogout": 0,
            "deviceName": "KOReader e-ink verification",
            "deviceType": 3,
        },
        timeout=30,
    )
    response.raise_for_status()
    data = response.json()
    if not isinstance(data, dict) or not data.get("vid") or not data.get("accessToken"):
        raise RuntimeError("native /login response did not contain credentials")
    return data


def main() -> None:
    with requests.Session() as session, tempfile.TemporaryDirectory(prefix="weread-qr-") as temp_dir:
        nonce = f"{int(time.time())}{secrets.randbelow(900000) + 100000}"
        ticket = request_json(
            session,
            NATIVE_BASE + "/wxticket?" + urllib.parse.urlencode({"nonceStr": nonce}),
            headers=HEADERS,
        )
        if not ticket.get("signature") or not ticket.get("timeStamp"):
            raise RuntimeError("native /wxticket response is incomplete")

        qr_params = {
            "appid": WECHAT_APP_ID,
            "noncestr": nonce,
            "timestamp": ticket["timeStamp"],
            "scope": WECHAT_SCOPE,
            "signature": ticket["signature"],
        }
        qr = request_json(
            session,
            WECHAT_QR_URL + "?" + urllib.parse.urlencode(qr_params),
            headers={"Accept": "application/json", "Referer": "https://open.weixin.qq.com/"},
        )
        if str(qr.get("errcode")) != "0" or not qr.get("uuid"):
            raise RuntimeError(f"WeChat QR creation failed: {qr.get('errmsg', qr.get('errcode'))}")
        qr_data = qr.get("qrcode", {}).get("qrcodebase64")
        if not qr_data:
            raise RuntimeError("WeChat did not return a QR image")
        image_path = Path(temp_dir) / "login.png"
        image_path.write_bytes(base64.b64decode(qr_data))
        print(f"Open this image and scan it in WeChat: {image_path}")

        uuid = qr["uuid"]
        last_status = 0
        auth_code = None
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            params = {"f": "json", "uuid": uuid}
            if last_status:
                params["last"] = str(last_status)
            status = request_json(
                session,
                WECHAT_POLL_URL + "?" + urllib.parse.urlencode(params),
                timeout=65,
                headers={"Accept": "application/json", "Referer": "https://open.weixin.qq.com/"},
            )
            code = int(status.get("wx_errcode", -1))
            if code == 405:
                auth_code = status.get("wx_code")
                break
            if code in (408, 404):
                last_status = code
                continue
            if code == 402:
                raise RuntimeError("WeChat login QR code expired")
            if code == 403:
                raise RuntimeError("WeChat login was cancelled")
            raise RuntimeError(f"unexpected WeChat QR status: {code}")

        if not auth_code:
            raise RuntimeError("WeChat login timed out")

        login = complete_login(session, auth_code)
        account_headers = {
            "vid": str(login["vid"]),
            "accessToken": str(login["accessToken"]),
        }
        shelf = request_json(
            session,
            NATIVE_BASE + "/shelf/sync?synckey=0&lectureSynckey=0",
            headers={**HEADERS, **account_headers},
        )
        books = shelf.get("books")
        print(json.dumps({
            "login": "ok",
            "vid_present": bool(login.get("vid")),
            "access_token_present": bool(login.get("accessToken")),
            "refresh_token_present": bool(login.get("refreshToken")),
            "shelf_books": len(books) if isinstance(books, list) else None,
        }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
