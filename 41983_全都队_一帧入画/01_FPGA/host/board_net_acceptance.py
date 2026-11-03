"""Physical ANET transport acceptance. Does not configure adapters or Flash."""
import argparse
import json
import secrets
import socket
import statistics
import struct
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from a_net_wire import Packet, encode, decode, HELLO, ACK


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ip', default='192.168.0.2')
    parser.add_argument('--bind-ip', required=True)
    parser.add_argument('--interface-index', required=True, type=int)
    parser.add_argument('--out', required=True)
    parser.add_argument('--bulk', type=int, default=1000)
    args = parser.parse_args()
    peer = (args.ip, 40000)
    records = []
    rejects = []
    seq = 0
    sid = secrets.randbits(32)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.IPPROTO_IP, 31, struct.pack('!I', args.interface_index))
        sock.bind((args.bind_ip, 0))
        local = sock.getsockname()

        def exchange(payload):
            nonlocal seq
            seq += 1
            raw = encode(Packet(HELLO, sid, seq, payload=payload))
            start = time.perf_counter()
            sock.sendto(raw, peer)
            end = start + 2
            while time.perf_counter() < end:
                sock.settimeout(max(0.001, end - time.perf_counter()))
                try:
                    got, source = sock.recvfrom(65535)
                except socket.timeout:
                    break
                if source != peer:
                    continue
                try:
                    packet = decode(got)
                except ValueError:
                    continue
                if packet.session == sid and packet.sequence == seq:
                    ok = packet.op == ACK and packet.payload == payload
                    records.append(dict(seq=seq, bytes=len(payload), passed=ok,
                                        rtt_ms=(time.perf_counter() - start) * 1000))
                    return ok
            records.append(dict(seq=seq, bytes=len(payload), passed=False, error='TIMEOUT'))
            return False

        def negative(name, raw):
            sock.sendto(raw, peer)
            end = time.perf_counter() + 0.2
            replied = False
            while time.perf_counter() < end:
                sock.settimeout(max(0.001, end - time.perf_counter()))
                try:
                    got, source = sock.recvfrom(65535)
                except socket.timeout:
                    break
                if source == peer:
                    replied = True
            rejects.append(dict(case=name, rejected=not replied))

        ok = exchange(b'FUSION-NETFIX-ACCEPTANCE')
        if ok:
            for length in [0, 1, 2, 3, 4, 5, 7, 15, 16, 31, 32, 63, 64,
                           127, 128, 255, 256, 511, 512, 1023, 1367, 1368]:
                for trial in range(3):
                    ok = exchange(bytes((i * 17 + trial) & 255 for i in range(length)))
                    if not ok:
                        break
                if not ok:
                    break
        if ok:
            raw = encode(Packet(HELLO, sid, seq + 1, payload=b'bad-crc'))
            negative('app_crc_corrupted', raw[:-1] + bytes([raw[-1] ^ 1]))
            negative('truncated_app_header', b'ANET\x01')
            ok = all(x['rejected'] for x in rejects) and exchange(b'AFTER-MALFORMED')
        if ok:
            for trial in range(args.bulk):
                if not exchange(bytes((i * 29 + trial) & 255 for i in range(1368))):
                    ok = False
                    break
    times = [x['rtt_ms'] for x in records if x['passed']]
    result = dict(status='PASS' if ok else 'FAIL', peer=peer, local=local,
                  interface_index=args.interface_index, replies=sum(x['passed'] for x in records),
                  attempted=len(records), negative_cases=rejects,
                  rtt_ms_mean=statistics.mean(times) if times else None,
                  rtt_ms_max=max(times) if times else None, records=records,
                  scope='Hardware ARP/UDP HELLO only; not CPU service or image inference proof')
    Path(args.out).write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k != 'records'}, indent=2), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
