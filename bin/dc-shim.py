#!/usr/bin/env python3
"""DefenseClaw reachability shim. The Agent Control server runs in a container and cannot
reach a DefenseClaw gateway bound to the host's 127.0.0.1. This runs on the host network
and forwards a Docker-reachable port to that loopback gateway, so containers reach it via
host.docker.internal. Stdlib only. Configure with DC_LISTEN and DC_TARGET.

    DC_LISTEN=18971  DC_TARGET=127.0.0.1:18970  python3 dc-shim.py
"""
import os, socket, threading

LISTEN_PORT = int(os.environ.get("DC_LISTEN", "18971"))
th, tp = (os.environ.get("DC_TARGET", "127.0.0.1:18970").rsplit(":", 1) + ["18970"])[:2]
TARGET = (th, int(tp))


def pipe(a, b):
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
    except Exception:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except Exception:
            pass


def handle(client):
    try:
        upstream = socket.create_connection(TARGET, timeout=10)
    except Exception:
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", LISTEN_PORT))
    s.listen(128)
    print(f"[dc-shim] forwarding 0.0.0.0:{LISTEN_PORT} -> {TARGET[0]}:{TARGET[1]}", flush=True)
    while True:
        client, _ = s.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
