import type { ComposePlan, ComposeServiceDraft } from "@/types/domain";

/**
 * Compose 재검증 결과와 사용자가 고른 서비스 정책을 합친다.
 *
 * 서비스 이름만 같다고 이전 파싱 결과(port/image)까지 유지하면 Compose 문서를 고친 뒤
 * 화면과 실제 제출 본문이 달라진다. 사용자가 고른 정책만 유지하고, Compose에서 파생된
 * 값은 항상 새 계획을 신뢰한다.
 */
export function reconcileComposeServices(
  previous: readonly ComposeServiceDraft[],
  next: ComposePlan,
): ComposeServiceDraft[] {
  return next.services.map((service) => {
    const kept = previous.find((item) => item.name === service.name);
    if (kept) {
      return {
        ...kept,
        port: service.port,
        serviceEnabled: service.serviceEnabled,
        persistenceMountPath: service.persistenceMountPath,
        image: service.image,
        // 앱 이름을 고르는 연결은 새 Compose Service 포트를 따라간다. 그렇지 않으면
        // api:8080→api:9000 변경 뒤 화면에만 예전 포트가 남는다.
        allowedApps: kept.allowedApps
          .filter(
            (peer) =>
              next.services.find((candidate) => candidate.name === peer.app)
                ?.serviceEnabled !== false,
          )
          .map((peer) => ({
            ...peer,
            port: String(
              next.services.find((candidate) => candidate.name === peer.app)?.port ??
                peer.port,
            ),
          })),
        ingressApps: service.serviceEnabled
          ? kept.ingressApps.map((peer) => ({
              ...peer,
              port: String(service.port),
            }))
          : [],
        ...(service.serviceEnabled
          ? {}
          : { exposureMode: "internal" as const, authMode: "none" as const }),
      };
    }
    return {
      name: service.name,
      port: service.port,
      serviceEnabled: service.serviceEnabled,
      persistenceMountPath: service.persistenceMountPath,
      image: service.image,
      // 새 서비스는 방금 서버가 실제로 검증한 기본 정책을 그대로 보여 준다.
      exposureMode: service.exposureMode,
      authMode: service.authMode,
      egressMode: service.egressMode,
      allowedCidrs: [],
      secretKeys: [],
      allowedApps: [],
      ingressApps: [],
    };
  });
}

/** 검증 당시 본문과 현재 본문이 완전히 같은지 비교할 안정적인 직렬화. */
export function composeFormSnapshot(value: unknown): string {
  return JSON.stringify(value);
}
