/**
 * The app's public addresses. The only place they are written: screens,
 * tests and the App Store drafts (docs/antichat/app-store/) use these.
 */
export const LINKS = {
  /** The source code. */
  github: 'https://github.com/fjenn/antichat',
  privacyPolicy: 'https://opena.tech/antichat/privacy',
  support: 'https://opena.tech/antichat/support',
} as const;

export type LinkName = keyof typeof LINKS;
