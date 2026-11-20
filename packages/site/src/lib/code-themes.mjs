/*
** The pair of code themes every highlighted block renders with: Shiki
** writes the light colors inline and the night colors as --shiki-dark
** variables, which global.css switches to under the night scheme.
*/
import light from "./code-theme.mjs"
import dark from "./code-theme-night.mjs"

export default { light, dark }
