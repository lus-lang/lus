/* Serves /llms-full.txt from the agent documentation (lib/llms.ts). */
import type { APIRoute } from "astro"
import { llmsFile, TEXT } from "../lib/llms"

export const GET: APIRoute = () => new Response(llmsFile("llms-full.txt"), { headers: TEXT })
