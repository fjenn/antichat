/** Language choice for speech recognition: the user's setting, or detection. */

/** Whisper's code for a BCP-47 tag ("pt-BR" → "pt"), or undefined for 'auto'. */
export function whisperLanguage(tag: string | undefined): string | undefined {
  if (!tag || tag === 'auto') {
    return undefined;
  }
  const base = tag.toLowerCase().split(/[-_]/)[0]!;
  const alias: Record<string, string> = {
    nb: 'no',
    iw: 'he',
    in: 'id',
    fil: 'tl',
  };
  return alias[base] ?? base;
}

const parts = (tag: string) => {
  const [language, ...rest] = tag.replace(/_/g, '-').split('-');
  const region = rest.find(part => /^([A-Za-z]{2}|\d{3})$/.test(part));
  return {language: language!.toLowerCase(), region: region?.toUpperCase()};
};

/**
 * The supported locale closest to `wanted`: the same tag, then the same
 * language and region, then the same language. Undefined when the language
 * is not supported at all.
 */
export function matchLocale(
  wanted: string,
  supported: readonly string[],
): string | undefined {
  const want = parts(wanted);
  const normalised = supported.map(tag => ({tag, ...parts(tag)}));
  return (
    normalised.find(s => s.tag.toLowerCase() === wanted.toLowerCase()) ??
    normalised.find(
      s => s.language === want.language && s.region === want.region,
    ) ??
    normalised.find(s => s.language === want.language)
  )?.tag;
}

export interface LanguageInputs {
  /** The Voice setting: 'auto' or a BCP-47 tag. */
  setting: string;
  /** Languages of the phone, most preferred first. */
  deviceLocales: readonly string[];
  /** Language detected earlier in this chat, if any. */
  detected?: string;
}

/**
 * The language a recogniser that cannot detect languages should listen in:
 * the setting, else what was detected before, else the phone's language.
 */
export function listeningLocale(
  inputs: LanguageInputs,
  supported: readonly string[],
): string | undefined {
  const candidates =
    inputs.setting !== 'auto'
      ? [inputs.setting]
      : [
          ...(inputs.detected ? [inputs.detected] : []),
          ...inputs.deviceLocales,
        ];
  for (const candidate of candidates) {
    const match = matchLocale(candidate, supported);
    if (match) {
      return match;
    }
  }
  return undefined;
}
