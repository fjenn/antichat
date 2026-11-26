import {
  blankSpaceFor,
  shouldPinOnSend,
  shouldReleaseBlank,
} from '../thread/rules';

describe('scroll rules', () => {
  it('rule 2: a thread that fits the screen is not pinned', () => {
    expect(
      shouldPinOnSend({
        contentHeight: 300,
        viewportHeight: 600,
        messageCount: 2,
      }),
    ).toBe(false);
    expect(
      shouldPinOnSend({contentHeight: 0, viewportHeight: 600, messageCount: 0}),
    ).toBe(false);
  });

  it('rule 1: an overflowing thread pins the new question', () => {
    expect(
      shouldPinOnSend({
        contentHeight: 900,
        viewportHeight: 600,
        messageCount: 4,
      }),
    ).toBe(true);
  });

  it('rule 1: blank space shrinks as the answer grows and never goes negative', () => {
    const base = {
      viewportHeight: 600,
      pinOffset: 8,
      questionHeight: 60,
      chrome: 32,
    };
    expect(blankSpaceFor({...base, answerHeight: 0})).toBe(500);
    expect(blankSpaceFor({...base, answerHeight: 200})).toBe(300);
    expect(blankSpaceFor({...base, answerHeight: 900})).toBe(0);
  });

  it('rule 3: blank space is released only when off screen and idle', () => {
    expect(
      shouldReleaseBlank({generating: false, blank: 300, distanceFromEnd: 320}),
    ).toBe(true);
    expect(
      shouldReleaseBlank({generating: false, blank: 300, distanceFromEnd: 100}),
    ).toBe(false);
    expect(
      shouldReleaseBlank({generating: true, blank: 300, distanceFromEnd: 320}),
    ).toBe(false);
    expect(
      shouldReleaseBlank({generating: false, blank: 0, distanceFromEnd: 320}),
    ).toBe(false);
  });
});
