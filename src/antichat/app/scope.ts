/**
 * What the first version shows. Everything switched off here is built (or
 * has a slot) and simply not mounted, so nothing dead is on screen. Turn a
 * line on when its milestone ships.
 *
 * In: chat, history, settings, first-run model download, dictation, memory,
 * web search, connectors.
 */
export const V1 = {
  /** The + button and its sheet (web search, apps). */
  attachSheet: true,
  /** Camera, photos and files in the + sheet. */
  attachments: false,
  /** "Think longer" in the + sheet (the model menu has the switch). */
  thinkTool: false,
  /** "Study and learn". */
  study: false,
  /** Voice mode: the composer's resting button and the dock. */
  voiceMode: false,
  /** "Read aloud" under an answer. */
  readAloud: false,
  /** Rows in the drawer above the chat list (projects, library, tasks…). */
  drawerShortcuts: false,
  projects: false,
  /** Image generation, research, scheduled tasks. */
  images: false,
  research: false,
  tasks: false,
} as const;
