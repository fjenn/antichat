import type {Md4cFlags} from 'react-native-enriched-markdown';

// Single newlines are line breaks, as in ChatGPT: small models rely on it.
// md4c applies it to soft breaks inside a paragraph only, so lists, tables,
// code blocks and maths are untouched.
export const FLAGS: Md4cFlags = {
  latexMath: true,
  admonitions: false,
  hardSoftBreaks: true,
};
