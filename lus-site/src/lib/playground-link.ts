/*
** Build a playground URL that pre-fills the editor. The code travels
** in the hash as base64url so it never hits the server or analytics.
** Decoded by the playground page on load (see playground.astro).
*/
export function playgroundHref(
  code: string,
  version?: "stable" | "unstable",
): string {
  const encoded = Buffer.from(code, "utf-8").toString("base64url")
  const v = version ? `&v=${version}` : ""
  return `/playground#code=${encoded}${v}`
}
