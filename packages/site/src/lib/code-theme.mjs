/*
** The Shiki theme of every code figure on the site. Its colors are the
** design tokens of styles/global.css written in hex, since Shiki emits
** them inline. Keywords carry the lime signal in its text strength and
** everything else stays close to ink.
*/
export default {
  name: "lus-field",
  type: "light",
  colors: {
    "editor.background": "#eff2e6",
    "editor.foreground": "#101c05",
  },
  tokenColors: [
    { settings: { foreground: "#101c05" } },
    {
      scope: ["comment", "punctuation.definition.comment"],
      settings: { foreground: "#666e5b", fontStyle: "italic" },
    },
    {
      scope: [
        "keyword",
        "storage",
        "constant.language",
        "variable.language.self",
      ],
      settings: { foreground: "#295b00", fontStyle: "bold" },
    },
    {
      scope: ["keyword.operator"],
      settings: { foreground: "#414c38", fontStyle: "" },
    },
    { scope: ["string", "string.tag"], settings: { foreground: "#854408" } },
    {
      scope: ["constant.character.escape", "punctuation.section.interpolation"],
      settings: { foreground: "#6b3500" },
    },
    { scope: ["constant.numeric"], settings: { foreground: "#59479a" } },
    {
      scope: ["support.function", "entity.name.function"],
      settings: { foreground: "#00587c" },
    },
    {
      scope: ["entity.name.class", "entity.name.tag", "entity.other.attribute"],
      settings: { foreground: "#59479a" },
    },
    { scope: ["invalid"], settings: { foreground: "#9b1c1c" } },
  ],
}
