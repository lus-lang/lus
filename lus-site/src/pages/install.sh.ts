/*
** Serves the UNIX installer at /install.sh. The single source of
** truth is lus-install/install.sh at the repo root; the ?raw import
** inlines it at build time, so the deployed script always matches
** the checkout. Content-Type for the static deploy comes from
** public/_headers (build-time Response headers aren't preserved).
*/
import type { APIRoute } from "astro"
// @ts-expect-error vite ?raw import
import script from "../../../lus-install/install.sh?raw"

export const GET: APIRoute = () =>
  new Response(script, {
    headers: { "Content-Type": "text/x-shellscript; charset=utf-8" },
  })
