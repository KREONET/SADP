"use server";

import { getToken } from "next-auth/jwt";
import { headers } from "next/headers";
import { redirect, RedirectType } from "next/navigation";

import { signOut } from "@/auth";
import {
  endKeycloakSession,
  keycloakBrowserLogoutURL,
  type KeycloakTokenState,
} from "@/lib/keycloak-token";

function requiredRuntimeEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required at runtime`);
  return value;
}

async function authToken(): Promise<KeycloakTokenState | null> {
  const authURL = new URL(requiredRuntimeEnvironment("AUTH_URL"));
  const requestHeaders = await headers();
  const secret = requiredRuntimeEnvironment("AUTH_SECRET");
  const secureCookie = authURL.protocol === "https:";

  // 운영은 __Secure-authjs.session-token, 로컬 HTTP는 authjs.session-token을 쓴다.
  // URL 전환 직후 남은 구형 쿠키도 한 번의 로그아웃으로 정리하도록 둘 다 확인한다.
  return (
    (await getToken({ req: { headers: requestHeaders }, secret, secureCookie })) ??
    (await getToken({ req: { headers: requestHeaders }, secret, secureCookie: !secureCookie }))
  );
}

export async function signOutFromKeycloak(): Promise<never> {
  const issuer = requiredRuntimeEnvironment("AUTH_KEYCLOAK_ISSUER");
  const clientId = requiredRuntimeEnvironment("AUTH_KEYCLOAK_ID");
  const authURL = new URL(requiredRuntimeEnvironment("AUTH_URL"));
  const postLogoutRedirectUri = new URL("/portal", authURL).toString();
  const token = await authToken();

  // 이 기능 배포 전에 만들어진 Auth.js 쿠키에는 ID token이 없다. 그 세션만 백채널로
  // 먼저 끊고, 새 세션은 브라우저 RP logout으로 Keycloak/상위 SAML 로그아웃을 전파한다.
  if (token?.refreshToken && !token.idToken) {
    try {
      await endKeycloakSession(token, {
        issuer,
        clientId,
        clientSecret: requiredRuntimeEnvironment("AUTH_KEYCLOAK_SECRET"),
      });
    } catch (error) {
      console.warn("기존 Keycloak 세션 백채널 종료 실패", error);
    }
  }

  const keycloakLogout = keycloakBrowserLogoutURL(token ?? {}, {
    issuer,
    clientId,
    postLogoutRedirectUri,
  });
  await signOut({ redirect: false });
  redirect(keycloakLogout, RedirectType.replace);
}
