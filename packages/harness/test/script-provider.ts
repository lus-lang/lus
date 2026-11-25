// A scripted model for driving the harness without a network. It answers
// each turn with the next step of the JSON file named by LUS_HARNESS_SCRIPT:
// a list of steps, each a string (a text reply) or a list of tool calls
// written as {"tool": name, "args": {...}}.
import { readFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

type Step = string | { tool: string; args: Record<string, unknown> }[];

export default function (pi: ExtensionAPI) {
  const file = process.env.LUS_HARNESS_SCRIPT;
  if (!file) return;
  const steps: Step[] = JSON.parse(readFileSync(file, "utf8"));
  const faux = createFauxCore({ api: "script", provider: "script", models: [{ id: "script", contextWindow: 200000 }], tokensPerSecond: 4000 });
  faux.setResponses(
    steps.map((step) =>
      typeof step === "string"
        ? fauxAssistantMessage(fauxText(step))
        : fauxAssistantMessage(step.map((call) => fauxToolCall(call.tool, call.args)), { stopReason: "toolUse" }),
    ),
  );
  pi.registerProvider("script", {
    api: faux.api,
    baseUrl: "http://script.invalid",
    apiKey: "script",
    models: [{ id: "script", name: "script", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200000, maxTokens: 8192 }],
    streamSimple: faux.streamSimple,
  } as never);
}
