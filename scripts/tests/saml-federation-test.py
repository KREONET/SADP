#!/usr/bin/env python3
"""SAML Assertion 시간 계약, ID 재사용 차단과 NTP 자동화 표면을 검증한다."""

from __future__ import annotations

import base64
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PARSER = ROOT / "scripts/verify/saml-assertion-contract.py"
TIME_SYNC = ROOT / "platform/keycloak/external/configure-time-sync.sh"
AUTHENTIK = ROOT / "scripts/ops/configure-authentik-saml.sh"
VERIFY = ROOT / "scripts/verify/verify-saml-federation.sh"
REMOTE = ROOT / "scripts/cluster/configure-external-keycloak.sh"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    print(f"[OK]   {message}")


for script in (TIME_SYNC, AUTHENTIK, VERIFY, REMOTE):
    subprocess.run(["bash", "-n", str(script)], cwd=ROOT, check=True)
check(True, "SAML/NTP shell syntax")

time_sync = TIME_SYNC.read_text(encoding="utf-8")
authentik = AUTHENTIK.read_text(encoding="utf-8")
verify = VERIFY.read_text(encoding="utf-8")
remote = REMOTE.read_text(encoding="utf-8")
check(
    "SADP_NTP_SERVERS" in time_sync
    and "UDP 123 응답 검증 실패" in time_sync
    and "NTPSynchronized --value" in time_sync
    and "systemd-time-wait-sync.service" in time_sync,
    "NTP는 DNS/UDP 응답과 NTPSynchronized를 강제하고 인증 시작 순서를 고정",
)
check(
    "--runtime auto --apply" in remote
    and '"${REMOTE_TIME_SCRIPT}"' in remote
    and remote.index("quoted_time_script") < remote.index("remote_config_args"),
    "외부 Keycloak 정책보다 VM 시간 동기화를 먼저 적용",
)
check(
    "EXPECTED_NOT_BEFORE='minutes=-5'" in authentik
    and "EXPECTED_NOT_ON_OR_AFTER='minutes=5'" in authentik
    and "allowedClockSkew/Login timeout/서명 검증 변경 없음" in authentik
    and "-X PATCH" in authentik,
    "Authentik Assertion 유효시간만 공식 -5분/+5분 계약으로 PATCH",
)
check(
    "Assertion expired" in verify
    and "invalid_saml_response" in verify
    and "SAML 원문, Response/Assertion ID" in verify
    and "NTPSynchronized" in verify,
    "federation 검증은 시간차·신규 오류를 원문 비출력으로 확인",
)


def sample_xml(
    response_id: str,
    assertion_id: str,
    issue: datetime,
    *,
    before_seconds: int = 300,
    after_seconds: int = 300,
) -> bytes:
    def timestamp(value: datetime) -> str:
        return value.isoformat(timespec="seconds").replace("+00:00", "Z")

    return f"""<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol"
      xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion"
      ID="{response_id}" IssueInstant="{timestamp(issue)}">
      <saml:Assertion ID="{assertion_id}" IssueInstant="{timestamp(issue)}">
        <saml:Subject>
          <saml:NameID>private-user-must-not-appear</saml:NameID>
          <saml:SubjectConfirmation>
            <saml:SubjectConfirmationData NotOnOrAfter="{timestamp(issue + timedelta(seconds=after_seconds))}" />
          </saml:SubjectConfirmation>
        </saml:Subject>
        <saml:Conditions NotBefore="{timestamp(issue - timedelta(seconds=before_seconds))}"
          NotOnOrAfter="{timestamp(issue + timedelta(seconds=after_seconds))}" />
      </saml:Assertion>
    </samlp:Response>""".encode()


def write_sample(path: Path, xml: bytes, mode: int = 0o600) -> None:
    path.write_bytes(base64.b64encode(xml))
    path.chmod(mode)


issue = datetime(2026, 8, 20, 2, 0, tzinfo=timezone.utc)
now_epoch = int((issue + timedelta(seconds=30)).timestamp())
test_env = os.environ.copy()
test_env["SADP_SAML_TEST_MODE"] = "1"

with tempfile.TemporaryDirectory(prefix="sadp-saml-contract-") as temp_dir:
    temp = Path(temp_dir)
    first = temp / "first.saml"
    second = temp / "second.saml"
    write_sample(first, sample_xml("response-one-private", "assertion-one-private", issue))
    write_sample(second, sample_xml("response-two-private", "assertion-two-private", issue))
    success = subprocess.run(
        [
            "python3",
            str(PARSER),
            "--now-epoch",
            str(now_epoch),
            str(first),
            str(second),
        ],
        cwd=ROOT,
        env=test_env,
        text=True,
        capture_output=True,
        check=True,
    )
    output = success.stdout + success.stderr
    check(
        "로그인마다 새 SAML Response ID와 Assertion ID 발급" in output
        and "private" not in output,
        "정상 -5분/+5분 Assertion과 서로 다른 ID 통과, 원문/ID 비출력",
    )

    write_sample(second, sample_xml("response-one-private", "assertion-one-private", issue))
    duplicate = subprocess.run(
        ["python3", str(PARSER), "--now-epoch", str(now_epoch), str(first), str(second)],
        cwd=ROOT,
        env=test_env,
        text=True,
        capture_output=True,
    )
    check(
        duplicate.returncode != 0
        and "재사용 감지" in duplicate.stderr
        and "private" not in duplicate.stdout + duplicate.stderr,
        "이전 SAML Response/Assertion ID 재사용 거부",
    )

    write_sample(second, sample_xml("response-short", "assertion-short", issue, after_seconds=60))
    short = subprocess.run(
        ["python3", str(PARSER), "--now-epoch", str(now_epoch), str(first), str(second)],
        cwd=ROOT,
        env=test_env,
        text=True,
        capture_output=True,
    )
    check(short.returncode != 0 and "시간/구조 계약 실패" in short.stderr,
          "지나치게 짧은 Assertion 유효시간 거부")

    write_sample(second, sample_xml("response-expired", "assertion-expired", issue))
    expired = subprocess.run(
        [
            "python3",
            str(PARSER),
            "--now-epoch",
            str(int((issue + timedelta(minutes=6)).timestamp())),
            str(first),
            str(second),
        ],
        cwd=ROOT,
        env=test_env,
        text=True,
        capture_output=True,
    )
    check(expired.returncode != 0 and "시간/구조 계약 실패" in expired.stderr,
          "도착 시점에 만료된 Assertion 거부")

    write_sample(second, sample_xml("response-mode", "assertion-mode", issue), mode=0o644)
    exposed = subprocess.run(
        ["python3", str(PARSER), "--now-epoch", str(now_epoch), str(first), str(second)],
        cwd=ROOT,
        env=test_env,
        text=True,
        capture_output=True,
    )
    check(exposed.returncode != 0 and "시간/구조 계약 실패" in exposed.stderr,
          "group/world-readable SAML 원문 파일 거부")

print("SAML federation regression test passed")
