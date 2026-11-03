"""Explicit offline UI QA. No physical board connection; no style model runs."""
import argparse
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_app import Endpoint, FakeUART
import server
import adapters

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8772)
    parser.add_argument("--data-dir", required=True)
    args = parser.parse_args()
    endpoint = Endpoint(delay=.001)
    app = server.App(args.data_dir, offline_fixture=True)
    app.config = adapters.validate_config(dict(ip="127.0.0.1", bind_ip="127.0.0.1", port=endpoint.port, interface_index=None, serial_port=""))
    app.network = adapters.probe_network(app.config)
    app.serial = dict(online=True, port="OFFLINE_FIXTURE", raw="firmware=fixture-only; not a board")
    app.uart.port = FakeUART()
    http = server.Server(("127.0.0.1", args.port), app)
    print(f"OFFLINE IDENTITY FIXTURE ONLY: http://127.0.0.1:{args.port}/", flush=True)
    try:
        http.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        http.server_close()
        endpoint.close()
