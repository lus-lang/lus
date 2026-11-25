/*
** Serves the installer of the Lus harness for Pi at /harness.sh. The single
** source of truth is packages/harness/install.sh. The ?raw import inlines it
** at build time, so the deployed script always matches the checkout.
** Content-Type for the static deploy comes from public/_headers.
*/
import type { APIRoute } from "astro"
// @ts-expect-error vite ?raw import
import script from "../../../harness/install.sh?raw"

export const GET: APIRoute = () =>
  new Response(script, {
    headers: { "Content-Type": "text/x-shellscript; charset=utf-8" },
  })
