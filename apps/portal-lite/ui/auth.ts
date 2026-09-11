import NextAuth from "next-auth";

import { extractOIDCIdentity } from "./lib/oidc-token";
import { refreshOIDCAccessTokenOnce } from "./lib/oidc-refresh-coordinator";

function requiredRuntimeEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required at runtime`);
  return value;
}

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    {
      id: "oidc",
      name: "SSO",
      type: "oidc",
      issuer: requiredRuntimeEnvironment("AUTH_OIDC_ISSUER"),
      clientId: requiredRuntimeEnvironment("AUTH_OIDC_ID"),
      clientSecret: requiredRuntimeEnvironment("AUTH_OIDC_SECRET"),
      authorization: { params: { scope: "openid email profile" } },
      // 복구 버튼을 누를 때마다 세 검증값을 모두 새로 발급해 오래된 탭의 요청과 섞이지 않게 한다.
      checks: ["pkce", "state", "nonce"],
      profile(profile) {
        return {
          id: String(profile.sub),
          name:
            typeof profile.name === "string"
              ? profile.name
              : typeof profile.preferred_username === "string"
                ? profile.preferred_username
                : undefined,
          email: typeof profile.email === "string" ? profile.email : undefined,
          image: typeof profile.picture === "string" ? profile.picture : undefined,
        };
      },
    },
  ],
  pages: {
    signIn: "/login",
    error: "/login",
  },
  session: {
    strategy: "jwt",
    maxAge: 8 * 60 * 60,
  },
  callbacks: {
    async jwt({ token, account, profile }) {
      if (account) {
        const clientId = requiredRuntimeEnvironment("AUTH_OIDC_ID");
        const identity = extractOIDCIdentity(
          profile,
          account.access_token,
          clientId,
          process.env.AUTH_OIDC_GROUPS_CLAIM ?? "groups",
        );
        return {
          ...token,
          ...identity,
          accessToken: account.access_token,
          accessTokenExpiresAt:
            typeof account.expires_at === "number" ? account.expires_at * 1000 : Date.now() + 5 * 60 * 1000,
          refreshToken: account.refresh_token,
          idToken: account.id_token,
          error: undefined,
        };
      }

      if (!token.accessTokenExpiresAt || Date.now() < token.accessTokenExpiresAt - 30_000) {
        return token;
      }
      if (!token.refreshToken) return { ...token, error: "RefreshTokenError" };

      try {
        // 서버 요청의 쿠키 사본이 같은 구 토큰을 들고 와도 갱신은 한 번만 한다.
        // Proxy는 인증을 수행하지 않으며 별도 런타임과 메모리 공유를 가정하지 않는다.
        const refreshed = await refreshOIDCAccessTokenOnce(token, {
          tokenEndpoint: requiredRuntimeEnvironment("AUTH_OIDC_TOKEN_ENDPOINT"),
          clientId: requiredRuntimeEnvironment("AUTH_OIDC_ID"),
          clientSecret: requiredRuntimeEnvironment("AUTH_OIDC_SECRET"),
          groupsClaim: process.env.AUTH_OIDC_GROUPS_CLAIM ?? "groups",
        });
        return { ...refreshed, error: undefined };
      } catch {
        return { ...token, error: "RefreshTokenError" };
      }
    },
    session({ session, token }) {
      if (session.user) {
        session.user.id = token.userId ?? token.sub ?? "";
        session.user.username = token.username;
        session.user.groups = token.groups ?? [];
        session.user.realmRoles = token.realmRoles ?? [];
        session.user.clientRoles = token.clientRoles ?? [];
      }
      session.accessTokenExpiresAt = token.accessTokenExpiresAt;
      session.error = token.error;
      return session;
    },
  },
});
