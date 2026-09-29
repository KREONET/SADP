#!/usr/bin/env python3
"""노드 변경 전에 실제 NIC와 계약을 비교해 내부망 전용 worker의 보호 생략을 검증한다."""
import argparse
import ipaddress
import json
import subprocess
import sys


def validate(interfaces, routes, internal, external, address, guarded, internal_only):
    devices = {item['ifname']: item for item in interfaces}
    if internal not in devices:
        raise ValueError(f'내부망 interface가 없음: {internal}')
    if address not in [entry.get('local') for entry in devices[internal].get('addr_info', [])]:
        raise ValueError(f'내부망 interface의 IP가 계약과 다름: {internal}')
    if not internal_only:
        for name in [external, *guarded]:
            if name not in devices:
                raise ValueError(f'외부/guarded interface가 없음: {name}; 내부망 전용 worker는 WORKER_INTERNAL_ONLY=true 필요')
        if not any(route.get('dev') == external for route in routes):
            raise ValueError(f'IPv4 default route가 외부 interface에 없음: {external}')
        return
    # 설정 오타로 외부 NIC의 보호를 생략하지 않도록 명시한 대상이 있으면 거부한다.
    if any(name in devices for name in [external, *guarded]):
        raise ValueError('내부망 전용 worker에 외부/guarded NIC가 존재함; 보호를 생략할 수 없음')
    if any(route.get('dev') != internal for route in routes):
        raise ValueError('내부망 전용 worker의 default route가 내부 NIC 이외의 장치를 사용함')
    for name, device in devices.items():
        for entry in device.get('addr_info', []):
            value = ipaddress.ip_address(entry['local'])
            # 내부 IPv4는 계약으로 검증한다. 그 외 공인 주소(SLAAC IPv6 포함)는 guard 없이 두지 않는다.
            if value.is_global and not (name == internal and str(value) == address):
                raise ValueError(f'내부망 전용 worker에 보호되지 않은 공인 주소가 있음: {name}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--internal-interface', required=True)
    parser.add_argument('--external-interface', required=True)
    parser.add_argument('--internal-ip', required=True)
    parser.add_argument('--guarded-interfaces', default='')
    parser.add_argument('--internal-only', action='store_true')
    args = parser.parse_args()
    try:
        interfaces = json.loads(subprocess.check_output(['ip', '-j', 'address', 'show']))
        routes = json.loads(subprocess.check_output(['ip', '-j', '-4', 'route', 'show', 'default']))
        validate(interfaces, routes, args.internal_interface, args.external_interface, args.internal_ip,
                 [name for name in args.guarded_interfaces.split(',') if name], args.internal_only)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f'[FAIL] 노드 NIC 사전 검사: {error}', file=sys.stderr)
        return 1
    print('[OK] 노드 NIC 사전 검사' + (' (내부망 전용 worker)' if args.internal_only else ''))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
