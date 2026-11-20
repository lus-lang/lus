/* Serves /agents.md from the agent documentation (lib/llms.ts). */
import type { APIRoute } from "astro"
import { llmsFile, MARKDOWN } from "../lib/llms"

export const GET: APIRoute = () => new Response(llmsFile("agents.md"), { headers: MARKDOWN })
