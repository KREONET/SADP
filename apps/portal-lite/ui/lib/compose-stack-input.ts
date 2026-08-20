import type { AppGroupInput } from "./paas-api";
import type { ComposeServiceDraft } from "../types/domain";

/** 서비스별 화면 설정을 AppGroup API override로 직렬화한다. */
export function composeServiceOverrides(
  services: readonly ComposeServiceDraft[],
): NonNullable<AppGroupInput["services"]> {
  return services.map((service) => ({
    name: service.name,
    // 값은 절대 받거나 보내지 않는다. OpenBao remote object에 이미 존재하는 key만 참조한다.
    secretKeys: service.secretKeys.map((key) => key.trim()),
    exposure: { mode: service.exposureMode },
    authentication: {
      // 내부 전용 앱에는 붙일 HTTPRoute가 없다. 서버도 같은 이유로 거부한다.
      mode: service.exposureMode === "external" ? service.authMode : "none",
    },
    networkPolicy: {
      egressMode: service.egressMode,
      // 비어 있거나 잘못된 행을 조용히 버리면 화면에는 연결이 있는데 배포에는 없는
      // 상태가 된다. 그대로 보내 백엔드가 해당 행의 정확한 필드 오류를 돌려주게 한다.
      allowedApps: service.allowedApps.map((peer) => ({
        app: peer.app,
        port: Number(peer.port),
        protocol: peer.protocol,
      })),
      ...(service.egressMode === "custom"
        ? {
            allowedCIDRs: service.allowedCidrs.map((peer) => ({
              cidr: peer.cidr.trim(),
              port: Number(peer.port),
              protocol: peer.protocol,
            })),
          }
        : {}),
      ingress: {
        allowedApps: service.ingressApps.map((peer) => ({
          // 빈 행도 그대로 전달한다. 조용히 버리면 화면에서 허용했다고 보인 연결이
          // 실제 정책에는 빠지므로, 백엔드가 필드별 422를 돌려주게 해야 한다.
          app: peer.app,
          port: Number(peer.port),
          protocol: peer.protocol,
        })),
      },
    },
  }));
}
