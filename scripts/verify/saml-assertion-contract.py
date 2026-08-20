#!/usr/bin/env python3
"""두 SAML 응답의 시간 계약과 ID 재사용 여부를 원문 출력 없이 검증한다."""

from __future__ import annotations

import argparse
import base64
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import stat
import sys
import xml.etree.ElementTree as ET


SAML_ASSERTION = "urn:oasis:names:tc:SAML:2.0:assertion"
MAX_INPUT_BYTES = 4 * 1024 * 1024
MIN_OFFICIAL_WINDOW_SECONDS = 5 * 60


@dataclass(frozen=True)
class AssertionEvidence:
    response_id_hash: bytes
    assertion_id_hash: bytes
    response_hash: bytes
    issue_instant: datetime
    not_before: datetime
    conditions_not_after: datetime
    subject_not_after: datetime


def parse_time(value: str | None) -> datetime:
    if not value:
        raise ValueError("missing time")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("time must contain timezone")
    return parsed.astimezone(timezone.utc)


def protected_file(path: Path) -> bytes:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise ValueError("sample must be a regular file")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("sample must not be group/world accessible")
    data = path.read_bytes().strip()
    if not data or len(data) > MAX_INPUT_BYTES:
        raise ValueError("sample size invalid")
    return data


def decode_sample(path: Path) -> bytes:
    encoded = protected_file(path)
    try:
        xml = base64.b64decode(encoded, validate=True)
    except (ValueError, base64.binascii.Error) as error:
        raise ValueError("invalid base64 sample") from error
    if len(xml) > MAX_INPUT_BYTES or b"<!DOCTYPE" in xml.upper() or b"<!ENTITY" in xml.upper():
        raise ValueError("unsafe XML sample")
    return xml


def digest_identifier(value: str | None) -> bytes:
    if not value:
        raise ValueError("missing identifier")
    return hashlib.sha256(value.encode("utf-8")).digest()


def parse_evidence(path: Path) -> AssertionEvidence:
    xml = decode_sample(path)
    root = ET.fromstring(xml)
    assertions = root.findall(f".//{{{SAML_ASSERTION}}}Assertion")
    if len(assertions) != 1:
        raise ValueError("exactly one assertion required")
    assertion = assertions[0]
    conditions = assertion.find(f"{{{SAML_ASSERTION}}}Conditions")
    if conditions is None:
        raise ValueError("conditions missing")
    subject_expiries = [
        parse_time(item.get("NotOnOrAfter"))
        for item in assertion.findall(
            f".//{{{SAML_ASSERTION}}}SubjectConfirmationData"
        )
        if item.get("NotOnOrAfter")
    ]
    if not subject_expiries:
        raise ValueError("subject confirmation expiry missing")
    return AssertionEvidence(
        response_id_hash=digest_identifier(root.get("ID")),
        assertion_id_hash=digest_identifier(assertion.get("ID")),
        response_hash=hashlib.sha256(xml).digest(),
        issue_instant=parse_time(assertion.get("IssueInstant") or root.get("IssueInstant")),
        not_before=parse_time(conditions.get("NotBefore")),
        conditions_not_after=parse_time(conditions.get("NotOnOrAfter")),
        subject_not_after=min(subject_expiries),
    )


def validate_timing(evidence: AssertionEvidence, now: datetime) -> None:
    if not evidence.not_before <= now < evidence.conditions_not_after:
        raise ValueError("conditions not valid now")
    if not now < evidence.subject_not_after:
        raise ValueError("subject confirmation not valid now")
    if evidence.issue_instant > now:
        raise ValueError("assertion issued in the future")
    if (evidence.issue_instant - evidence.not_before).total_seconds() \
            < MIN_OFFICIAL_WINDOW_SECONDS:
        raise ValueError("not-before window shorter than official default")
    if (evidence.conditions_not_after - evidence.issue_instant).total_seconds() \
            < MIN_OFFICIAL_WINDOW_SECONDS:
        raise ValueError("conditions expiry window shorter than official default")
    if (evidence.subject_not_after - evidence.issue_instant).total_seconds() \
            < MIN_OFFICIAL_WINDOW_SECONDS:
        raise ValueError("subject expiry window shorter than official default")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="root-only SAMLResponse 두 개의 시간/재사용 계약을 원문 비출력으로 검사"
    )
    parser.add_argument("samples", nargs=2, type=Path)
    parser.add_argument("--now-epoch", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if os.geteuid() != 0 and os.environ.get("SADP_SAML_TEST_MODE") != "1":
        print("[FAIL] root 권한이 필요함", file=sys.stderr)
        return 1
    now = datetime.fromtimestamp(args.now_epoch, timezone.utc) \
        if args.now_epoch is not None else datetime.now(timezone.utc)
    evidence: list[AssertionEvidence] = []
    for index, path in enumerate(args.samples, start=1):
        try:
            item = parse_evidence(path)
            validate_timing(item, now)
        except (OSError, ValueError, ET.ParseError):
            print(f"[FAIL] SAML sample {index} 시간/구조 계약 실패", file=sys.stderr)
            return 1
        evidence.append(item)
        print(f"[OK]   SAML sample {index} IssueInstant/Conditions/SubjectConfirmation 유효")

    if evidence[0].response_id_hash == evidence[1].response_id_hash \
            or evidence[0].assertion_id_hash == evidence[1].assertion_id_hash \
            or evidence[0].response_hash == evidence[1].response_hash:
        print("[FAIL] 두 로그인에서 SAML Response/Assertion 재사용 감지", file=sys.stderr)
        return 1
    print("[OK]   로그인마다 새 SAML Response ID와 Assertion ID 발급")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
