#!/usr/bin/env python3
"""edit-server.py — Web UI for editing autofill personal data

Usage:
  edit-server.py             # Edit existing encrypted data
  edit-server.py --init      # First-time setup (blank template)

Starts a local web server on 127.0.0.1:9876 (localhost only).
"""

import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import webbrowser

import yaml

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(SCRIPT_DIR)
AUTOFILL_DIR = os.path.join(os.path.expanduser("~"), ".claude-autofill")
DATA_ENC = os.path.join(AUTOFILL_DIR, "data.enc")
TEMPLATE_FILE = os.path.join(PLUGIN_ROOT, "assets", "data-template.yaml")
SCHEMA_FILE = os.path.join(PLUGIN_ROOT, "skills", "autofill", "references", "data-schema.yaml")
UI_FILE = os.path.join(SCRIPT_DIR, "edit-ui.html")
PORT = 9876

# Global state
_data = None
_schema = None
_is_init = False
_tmpfile = None


def load_schema():
    with open(SCHEMA_FILE, "r") as f:
        return yaml.safe_load(f)


def load_template():
    with open(TEMPLATE_FILE, "r") as f:
        return yaml.safe_load(f)


def decrypt_data():
    """Decrypt data.enc via encrypt.sh, return parsed YAML data and tmpfile path."""
    cmd = ["bash", os.path.join(SCRIPT_DIR, "encrypt.sh"), "--decrypt"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"❌ 解密失敗: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)

    tmpfile = result.stdout.strip()
    if not os.path.exists(tmpfile):
        print("❌ 解密暫存檔不存在", file=sys.stderr)
        sys.exit(1)

    with open(tmpfile, "r") as f:
        data = yaml.safe_load(f)

    # Securely delete the temp file immediately after reading
    subprocess.run(["rm", "-P", tmpfile], capture_output=True)
    if os.path.exists(tmpfile):
        os.remove(tmpfile)

    return data


def save_and_encrypt(data):
    """Write data to temp YAML file, then encrypt it."""
    os.makedirs(AUTOFILL_DIR, exist_ok=True)

    # If first-time setup, initialize keys first
    global _is_init
    if _is_init:
        if not os.path.exists(os.path.join(AUTOFILL_DIR, "recipient.pub")):
            result = subprocess.run(
                ["bash", os.path.join(SCRIPT_DIR, "encrypt.sh"), "--init"],
                capture_output=True, text=True
            )
            if result.returncode != 0:
                return False, f"金鑰初始化失敗: {result.stderr.strip()}"
            print(result.stdout)

    # Write to temp YAML
    tmpfile = tempfile.mktemp(suffix=".yaml", dir=AUTOFILL_DIR)
    try:
        with open(tmpfile, "w") as f:
            yaml.dump(data, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
        os.chmod(tmpfile, 0o600)

        # Encrypt (this also deletes the plaintext file)
        result = subprocess.run(
            ["bash", os.path.join(SCRIPT_DIR, "encrypt.sh"), tmpfile],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            return False, f"加密失敗: {result.stderr.strip()}"

        print(result.stdout)
        return True, "資料已加密儲存"

    except Exception as e:
        # Clean up on error
        if os.path.exists(tmpfile):
            subprocess.run(["rm", "-P", tmpfile], capture_output=True)
            if os.path.exists(tmpfile):
                os.remove(tmpfile)
        return False, str(e)


class AutofillHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress default logging to avoid leaking data
        pass

    def do_GET(self):
        if self.path == "/":
            self._serve_html()
        elif self.path == "/api/schema":
            self._send_json(_schema)
        elif self.path == "/api/data":
            self._send_json(_data)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/data":
            content_length = int(self.headers["Content-Length"])
            body = self.rfile.read(content_length)
            try:
                new_data = json.loads(body)
                ok, msg = save_and_encrypt(new_data)
                if ok:
                    self._send_json({"status": "ok", "message": msg})
                    # Schedule server shutdown after response
                    def shutdown():
                        self.server.shutdown()
                    import threading
                    threading.Thread(target=shutdown, daemon=True).start()
                else:
                    self._send_json({"status": "error", "message": msg}, code=500)
            except json.JSONDecodeError as e:
                self._send_json({"status": "error", "message": f"JSON 解析錯誤: {e}"}, code=400)
        else:
            self.send_error(404)

    def _serve_html(self):
        with open(UI_FILE, "r") as f:
            content = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(content.encode("utf-8"))

    def _send_json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    global _data, _schema, _is_init

    _is_init = "--init" in sys.argv

    # Load schema
    _schema = load_schema()

    # Load data
    if _is_init:
        _data = load_template()
        print("📋 使用空白模板")
    else:
        if not os.path.exists(DATA_ENC):
            print("❌ 找不到加密資料。請先執行 /autofill setup", file=sys.stderr)
            sys.exit(1)
        print("🔐 解密個人資料...")
        _data = decrypt_data()
        print("✅ 資料已載入")

    # Start server
    server = http.server.HTTPServer(("127.0.0.1", PORT), AutofillHandler)

    # Handle Ctrl+C gracefully
    def signal_handler(sig, frame):
        print("\n🛑 Server 已關閉")
        server.shutdown()
        sys.exit(0)
    signal.signal(signal.SIGINT, signal_handler)

    print(f"🌐 Web 編輯器啟動: http://127.0.0.1:{PORT}")
    print("   (儲存後自動關閉)")

    # Open browser
    webbrowser.open(f"http://127.0.0.1:{PORT}")

    # Serve until shutdown
    server.serve_forever()
    print("✅ 完成")


if __name__ == "__main__":
    main()
