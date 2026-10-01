#!/usr/bin/env python3
"""회귀 시험용 격리 작업공간(fixture).

사이트 branch의 checkout은 실제 site.env로 렌더된 계약과 생성물을 담는다. 시험이 그 파일을
직접 읽으면 예제 기준 기대값(노드 이름, IdP 호스트, 공유 client ID 등)이 사이트 값과 달라
"변경 전부터 실패"하는 시험이 생기고, 새 회귀를 구분할 수 없다. 그래서 시험은 현재 작업
트리의 코드(아직 커밋하지 않은 수정 포함)를 임시 디렉터리에 복사하고, 계약·생성물만
environments/site.env.example로 다시 렌더한 사본에서 돈다.

- 실제 site.env, 루트 .env, 무시 대상(node_modules, 복구 재료 등)은 복사하지 않는다.
- 렌더는 configure-site.py의 validate/prepare_updates와 RENDERERS를 그대로 쓴다.
  --write는 helm이 필요한 render-test.sh까지 돌리므로, helm 없이도 다른 시험의 실패 원인이
  helm 부재로 뭉개지지 않게 렌더러만 호출한다(helm 회귀는 render-test.sh가 따로 본다).

사용:
  python3 scripts/tests/sadp_test_fixture.py --build   # 경로를 stdout으로 출력
  reexec_in_fixture(__file__)                          # 시험 파일 머리에서 호출
"""

from __future__ import annotations

import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


REPO = pathlib.Path(__file__).resolve().parents[2]
MARKER = ".sadp-test-fixture"
ENV_KEY = "SADP_TEST_FIXTURE_ROOT"
EXAMPLE_ENV = "environments/site.env.example"
# .gitignore와 별개로 명시한다. Git metadata가 없는 bundle에서도 사이트 입력이 사본에
# 들어가면 안 된다.
EXCLUDED_NAMES = {".git", "node_modules", "__pycache__", ".next", ".rendered", ".claude"}
EXCLUDED_PATHS = {".env", "environments/site.env"}


class FixtureError(RuntimeError):
    pass


def is_fixture(root: pathlib.Path) -> bool:
    return (root / MARKER).is_file()


def _source_files() -> list[str]:
    if (REPO / ".git").exists():
        result = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=REPO,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            return [item for item in result.stdout.decode().split("\0") if item]
    files = []
    for path in REPO.rglob("*"):
        relative = path.relative_to(REPO)
        if any(part in EXCLUDED_NAMES for part in relative.parts):
            continue
        if path.is_file() or path.is_symlink():
            files.append(relative.as_posix())
    return files


def _copy_tree(target: pathlib.Path) -> None:
    for relative in _source_files():
        name = pathlib.PurePosixPath(relative).name
        if (
            relative in EXCLUDED_PATHS
            or name.startswith(".env")
            or (relative.startswith("environments/") and relative.endswith(".env"))
        ):
            continue
        if any(part in EXCLUDED_NAMES for part in pathlib.PurePosixPath(relative).parts):
            continue
        source = REPO / relative
        # 삭제했지만 아직 커밋하지 않은 파일은 ls-files --cached에 남는다.
        if not source.exists() and not source.is_symlink():
            continue
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            os.symlink(os.readlink(source), destination)
        else:
            shutil.copy2(source, destination)


def _render(root: pathlib.Path) -> None:
    spec = importlib.util.spec_from_file_location(
        "sadp_fixture_configure_site", root / "scripts/site/configure-site.py"
    )
    if not spec or not spec.loader:
        raise FixtureError("configure-site.py를 불러올 수 없음")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        cfg = module.validate(module.parse_env(root / EXAMPLE_ENV))
        import yaml

        contract = yaml.safe_load(module.CONTRACT_PATH.read_text(encoding="utf-8"))
        updates = module.prepare_updates(cfg, contract)
    except module.ConfigError as error:
        raise FixtureError(f"예제 site.env 검증 실패: {error}") from error
    for path, content in updates.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    if cfg["tls"]["source"] == "provided":
        (root / "platform/cert-manager/resources.yaml").unlink(missing_ok=True)
    for script in module.RENDERERS:
        result = subprocess.run(
            [sys.executable, script], cwd=root, capture_output=True, text=True, check=False
        )
        if result.returncode:
            raise FixtureError(f"fixture 렌더 실패: {script}\n{result.stderr.strip()}")


def _git_snapshot(root: pathlib.Path) -> None:
    # 일부 시험은 clean checkout을 전제로 git status/archive를 부른다. 렌더 결과를 한 번
    # 커밋해 두면 사본도 "예제값으로 렌더한 깨끗한 checkout"으로 보인다.
    if not shutil.which("git"):
        return
    identity = ["-c", "user.name=SADP Test Fixture", "-c", "user.email=fixture@example.invalid"]
    for command in (
        ["git", "init", "-q"],
        ["git", "add", "-A"],
        ["git", *identity, "commit", "-q", "--no-verify", "-m", "fixture"],
    ):
        result = subprocess.run(command, cwd=root, capture_output=True, text=True, check=False)
        if result.returncode:
            raise FixtureError(f"fixture git 준비 실패: {' '.join(command[:2])}")


def build(parent: pathlib.Path | None = None) -> pathlib.Path:
    base = pathlib.Path(tempfile.mkdtemp(prefix="sadp-test-fixture-", dir=parent))
    root = base / "repo"
    try:
        root.mkdir()
        _copy_tree(root)
        _render(root)
        (root / MARKER).write_text("rendered from environments/site.env.example\n", encoding="utf-8")
        _git_snapshot(root)
    except BaseException:
        shutil.rmtree(base, ignore_errors=True)
        raise
    return root


def remove(root: pathlib.Path) -> None:
    if is_fixture(root):
        shutil.rmtree(root.parent, ignore_errors=True)


def reexec_in_fixture(script_file: str) -> None:
    """저장소 checkout에서 직접 부르면 fixture 사본에서 같은 시험을 다시 실행하고 종료한다."""
    script = pathlib.Path(script_file).resolve()
    root = script.parents[2]
    if is_fixture(root):
        return
    shared = os.environ.get(ENV_KEY, "")
    fixture = pathlib.Path(shared) if shared and is_fixture(pathlib.Path(shared)) else None
    owned = fixture is None
    try:
        if owned:
            fixture = build()
        result = subprocess.run(
            [sys.executable, str(fixture / script.relative_to(root)), *sys.argv[1:]],
            env=dict(os.environ, **{ENV_KEY: str(fixture)}),
            check=False,
        )
    except FixtureError as error:
        print(f"[FAIL] 시험 fixture 준비 실패: {error}", file=sys.stderr)
        raise SystemExit(1) from None
    finally:
        if owned and fixture is not None:
            remove(fixture)
    raise SystemExit(result.returncode)


def main() -> int:
    if sys.argv[1:] == ["--build"]:
        try:
            print(build())
        except FixtureError as error:
            print(f"[FAIL] 시험 fixture 준비 실패: {error}", file=sys.stderr)
            return 1
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "--remove":
        remove(pathlib.Path(sys.argv[2]))
        return 0
    print("usage: sadp_test_fixture.py --build | --remove <root>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
