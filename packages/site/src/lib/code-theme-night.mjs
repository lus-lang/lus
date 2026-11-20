/*
** The night counterpart of code-theme.mjs, used by the playground editor.
** Its colors are the night tokens of styles/global.css written in hex:
** keywords carry the lime signal, everything else stays near ink.
*/
export default {
  name: "lus-night",
  type: "dark",
  colors: {
    "editor.background": "#0f1708",
    "editor.foreground": "#edf1db",
    "editorLineNumber.foreground": "#515846",
    "editorLineNumber.activeForeground": "#949c88",
    "editorCursor.foreground": "#aeec46",
    "editor.selectionBackground": "#2f4513",
    "editor.inactiveSelectionBackground": "#223409",
    "editor.lineHighlightBackground": "#192311",
    "editor.lineHighlightBorder": "#00000000",
    "editorIndentGuide.background1": "#192311",
    "editorIndentGuide.activeBackground1": "#515846",
    "editorWidget.background": "#192311",
    "editorWidget.border": "#515846",
    "editorSuggestWidget.background": "#192311",
    "editorSuggestWidget.selectedBackground": "#223409",
    "scrollbarSlider.background": "#51584666",
    "scrollbarSlider.hoverBackground": "#515846aa",
    "scrollbarSlider.activeBackground": "#949c88aa",
    "focusBorder": "#aeec46",
  },
  tokenColors: [
    { settings: { foreground: "#edf1db" } },
    {
      scope: ["comment", "punctuation.definition.comment"],
      settings: { foreground: "#949c88", fontStyle: "italic" },
    },
    {
      scope: [
        "keyword",
        "storage",
        "constant.language",
        "variable.language.self",
      ],
      settings: { foreground: "#aeec46", fontStyle: "bold" },
    },
    {
      scope: ["keyword.operator"],
      settings: { foreground: "#bbc1ac", fontStyle: "" },
    },
    { scope: ["string", "string.tag"], settings: { foreground: "#eeb97b" } },
    {
      scope: ["constant.character.escape", "punctuation.section.interpolation"],
      settings: { foreground: "#facf9e" },
    },
    { scope: ["constant.numeric"], settings: { foreground: "#bcb3fa" } },
    {
      scope: ["support.function", "entity.name.function"],
      settings: { foreground: "#84c9e5" },
    },
    {
      scope: ["entity.name.class", "entity.name.tag", "entity.other.attribute"],
      settings: { foreground: "#bcb3fa" },
    },
    { scope: ["invalid"], settings: { foreground: "#f98f87" } },
  ],
}
