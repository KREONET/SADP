"use server";

import { getToken } from "next-auth/jwt";
import { headers } from "next/headers";
import { redirect, RedirectType } from "next/navigation";

import { signOut } from "@/auth";
import {
  oidcBrowserLogoutURL,
  type OIDCTokenState,
} from "@/lib/oidc-token";

function requiredRuntimeEnvironment(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required at runtime`);
  return value;
}

async function authToken(): Promise<OIDCTokenState | null> {
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

export async function signOutFromOIDC(): Promise<never> {
  const clientId = requiredRuntimeEnvironment("AUTH_OIDC_ID");
  const authURL = new URL(requiredRuntimeEnvironment("AUTH_URL"));
  const postLogoutRedirectUri = new URL("/portal", authURL).toString();
  const token = await authToken();
  await signOut({ redirect: false });
  const endSessionEndpoint = process.env.AUTH_OIDC_END_SESSION_ENDPOINT;
  if (!endSessionEndpoint) redirect(postLogoutRedirectUri, RedirectType.replace);
  redirect(
    oidcBrowserLogoutURL(token ?? {}, {
      endSessionEndpoint,
      clientId,
      postLogoutRedirectUri,
    }),
    RedirectType.replace,
  );
}
