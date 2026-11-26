/**
 * Words of the model store and the unrestricted switch that are new since the
 * last locale pass. English only for now; they move into `locales/` with the
 * next one.
 */
export const ms = {
  unrestricted: 'Unrestricted',
  unrestrictedOnHint: 'On · no built-in refusals',
  unrestrictedOffHint: 'No built-in refusals',
  unrestrictedDownloadHint: (size: string) => `No built-in refusals · ${size}`,
  unrestrictedArriving: (percent: string | null) =>
    percent ? `Downloading · ${percent}` : 'Downloading',
  offerTitle: 'Download the unrestricted version?',
  offerMessage: (size: string) =>
    `The same size of model without built-in refusals, a ${size} download. AntiChat switches to it when it is ready.`,
  offerSwitchNote: 'AntiChat switches to it when it is ready.',
  offerConfirm: (size: string) => `Download · ${size}`,
  /** Top bar: the mode marker after the model's plain name. */
  modeLabel: 'Unrestricted mode',
};
