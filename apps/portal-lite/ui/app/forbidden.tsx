import Link from "next/link";

/** 서버 데이터 권한이 없는 로그인 사용자에게 내려가는 403 화면. */
export default function Forbidden() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col items-start justify-center gap-4 px-6 py-12">
      <p className="font-mono text-sm font-semibold text-muted-foreground">403</p>
      <h1 className="text-3xl font-bold text-brand-900">접근 권한이 없습니다.</h1>
      <p className="text-muted-foreground">
        이 화면을 보려면 Portal 배포 조회 권한이 필요합니다. 권한을 부여받은 뒤 다시
        로그인해 주세요.
      </p>
      <Link
        href="/portal"
        className="rounded-md bg-brand-900 px-4 py-2 text-sm font-semibold text-white hover:opacity-90"
      >
        포털로 돌아가기
      </Link>
    </main>
  );
}
