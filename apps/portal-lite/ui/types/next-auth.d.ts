import type { DefaultSession } from "next-auth";

declare module "next-auth" {
  interface Session {
    user: {
      id: string;
      username?: string;
      groups: string[];
      realmRoles: string[];
      clientRoles: string[];
    } & DefaultSession["user"];
    accessTokenExpiresAt?: number;
    error?: "RefreshTokenError";
  }
}

declare module "next-auth/jwt" {
  interface JWT {
    userId?: string;
    username?: string;
    groups?: string[];
    realmRoles?: string[];
    clientRoles?: string[];
    accessToken?: string;
    accessTokenExpiresAt?: number;
    refreshToken?: string;
    idToken?: string;
    error?: "RefreshTokenError";
  }
}
