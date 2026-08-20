import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  generateBuildId: async () => "portal-lite-authjs",
  experimental: {
    // 서버 렌더링 데이터 경계에서 역할이 없으면 로그인 화면이나 500 대신 정확한 403을 낸다.
    authInterrupts: true,
  },
  async rewrites() {
    return [
      {
        source: "/healthz",
        destination: "http://127.0.0.1:8081/healthz",
      },
    ];
  },
};

export default nextConfig;
