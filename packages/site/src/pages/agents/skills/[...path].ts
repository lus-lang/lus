/* Serves the agent skills of .agents/skills at /agents/skills/... */
import type { APIRoute, GetStaticPaths } from "astro"
import { llmsFiles, MARKDOWN } from "../../../lib/llms"

export const getStaticPaths: GetStaticPaths = () =>
  [...llmsFiles().entries()]
    .filter(([name]) => name.startsWith("agents/skills/"))
    .map(([name, text]) => ({
      params: { path: name.slice("agents/skills/".length) },
      props: { text },
    }))

export const GET: APIRoute = ({ props }) => new Response(props.text, { headers: MARKDOWN })
