/**
 * The scroll rules of docs/research/01-chatgpt-mobile-audit.md §3.3 as pure
 * functions, shared by both list candidates.
 */

/** Rule 1 vs rule 2: pin the new question to the top only when the thread already overflowed. */
export function shouldPinOnSend(p: {
  contentHeight: number;
  viewportHeight: number;
  messageCount: number;
}): boolean {
  return p.messageCount > 0 && p.contentHeight > p.viewportHeight + 1;
}

/**
 * Rule 1: empty space needed under the answer so the question can sit at the
 * top. Shrinks as the answer grows; 0 once the answer fills the screen.
 */
export function blankSpaceFor(p: {
  viewportHeight: number;
  pinOffset: number;
  questionHeight: number;
  answerHeight: number;
  /** Padding and gaps between the question's top and the end of the content. */
  chrome: number;
}): number {
  return Math.max(
    0,
    p.viewportHeight -
      p.pinOffset -
      p.questionHeight -
      p.answerHeight -
      p.chrome,
  );
}

/**
 * Rule 3: once the answer is complete and the reserved space has left the
 * screen, drop it, so scrolling back down ends at the answer's last line.
 */
export function shouldReleaseBlank(p: {
  generating: boolean;
  blank: number;
  /** Distance from the bottom of the viewport to the bottom of content + blank. */
  distanceFromEnd: number;
}): boolean {
  return !p.generating && p.blank > 0 && p.distanceFromEnd >= p.blank - 1;
}
