import NextAuth from "next-auth";
import Keycloak from "next-auth/providers/keycloak";

import {
  extractKeycloakIdentity,
  refreshKeycloakAccessToken,
} from "./lib/keycloak-token";

function requiredRuntimeEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required at runtime`);
  return value;
}

export const { handlers, auth, signIn, signOut } = NextAuth({
  providers: [
    Keycloak({
      authorization: { params: { scope: "openid email profile" } },
      // 복구 버튼을 누를 때마다 세 검증값을 모두 새로 발급해 오래된 탭의 요청과 섞이지 않게 한다.
      checks: ["pkce", "state", "nonce"],
    }),
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
        const clientId = requiredRuntimeEnvironment("AUTH_KEYCLOAK_ID");
        const identity = extractKeycloakIdentity(profile, account.access_token, clientId);
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
        const refreshed = await refreshKeycloakAccessToken(token, {
          issuer: requiredRuntimeEnvironment("AUTH_KEYCLOAK_ISSUER"),
          clientId: requiredRuntimeEnvironment("AUTH_KEYCLOAK_ID"),
          clientSecret: requiredRuntimeEnvironment("AUTH_KEYCLOAK_SECRET"),
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
