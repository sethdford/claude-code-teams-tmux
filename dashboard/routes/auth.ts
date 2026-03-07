import type { Session } from "../types/index.js";
import { CORS_HEADERS } from "../middleware/constants.js";
import { getAuthMode, isAuthEnabled, createSession, sessionCookie, clearSessionCookie } from "../middleware/auth.js";

export function handleAuthRoutes(req: Request, pathname: string, url: URL): Response | null {
  // POST /auth/pat-login — PAT-based login (returns session)
  if (pathname === "/auth/pat-login" && req.method === "POST") {
    // This endpoint requires body parsing which is done in server.ts
    // Returning null to signal server.ts to handle this
    return null;
  }

  // GET /auth/logout — Clear session and redirect
  if (pathname === "/auth/logout") {
    return new Response("Redirecting to login...", {
      status: 303,
      headers: {
        Location: "/login",
        "Set-Cookie": clearSessionCookie(),
      },
    });
  }

  // GET /auth/github — OAuth redirect (requires server.ts to handle)
  if (pathname === "/auth/github") {
    if (getAuthMode() !== "oauth") {
      return new Response("OAuth not configured", { status: 500 });
    }
    return null; // server.ts handles
  }

  // GET /auth/callback — OAuth callback (requires server.ts to handle)
  if (pathname === "/auth/callback") {
    return null; // server.ts handles with query params
  }

  return null;
}
