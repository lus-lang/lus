/*
** Serves the Markdown twin of every manual page at /manual/NAME.md, and
** the standard library reference at /manual/api.md.
*/
import type { APIRoute, GetStaticPaths } from "astro"
import { llmsFiles, MARKDOWN } from "../../lib/llms"

export const getStaticPaths: GetStaticPaths = () =>
  [...llmsFiles().entries()]
    .filter(([name]) => /^manual\/[^/]+\.md$/.test(name))
    .map(([name, text]) => ({
      params: { page: name.slice("manual/".length, -".md".length) },
      props: { text },
    }))

export const GET: APIRoute = ({ props }) => new Response(props.text, { headers: MARKDOWN })
