import { readFile } from "node:fs/promises";

const canonical = await readFile(
  new URL("../../lus-textmate/lus.tmLanguage.json", import.meta.url),
);
const extension = await readFile(
  new URL("../syntaxes/lus.tmLanguage.json", import.meta.url),
);

if (!canonical.equals(extension)) {
  throw new Error(
    "The extension grammar differs from the canonical TextMate grammar.",
  );
}
