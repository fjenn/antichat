import {
  composeMessage,
  detectLargePaste,
  inputHeights,
  pasteLimitFor,
  trailingState,
} from '../composerState';

describe('trailing button', () => {
  const base = {text: '', attachments: 0, preparing: false, generating: false};

  it('rests (no voice mode in the first version) when there is nothing to send', () => {
    expect(trailingState(base)).toBe('disabled');
  });

  it('offers send as soon as there is text or an attachment', () => {
    expect(trailingState({...base, text: 'hi'})).toBe('send');
    expect(trailingState({...base, attachments: 1})).toBe('send');
  });

  it('offers stop while an answer runs and nothing is typed', () => {
    expect(trailingState({...base, generating: true})).toBe('stop');
  });

  it('offers send while an answer runs once something is typed (interrupt)', () => {
    expect(trailingState({...base, generating: true, text: 'wait'})).toBe(
      'send',
    );
  });

  it('is disabled for blank text and while a file is being read', () => {
    expect(trailingState({...base, text: '   '})).toBe('disabled');
    expect(trailingState({...base, text: 'hi', preparing: true})).toBe(
      'disabled',
    );
  });
});

describe('large paste', () => {
  it('ignores typing and short pastes', () => {
    expect(detectLargePaste('hel', 'hell', 100)).toBeNull();
    expect(detectLargePaste('a', `a${'x'.repeat(50)}`, 100)).toBeNull();
  });

  it('lifts a long pasted run out of the text, wherever it was inserted', () => {
    const pasted = 'p'.repeat(120);
    expect(
      detectLargePaste('before after', `before ${pasted}after`, 100),
    ).toEqual({text: 'before after', pasted});
    expect(detectLargePaste('', pasted, 100)).toEqual({text: '', pasted});
  });

  it('has a smaller limit on small phones', () => {
    expect(pasteLimitFor('A')).toBeLessThan(pasteLimitFor('D'));
    expect(pasteLimitFor(null)).toBe(4000);
  });
});

describe('message that is sent', () => {
  it('puts the quote first and pasted text last', () => {
    expect(
      composeMessage({
        text: ' What does this mean? ',
        quote: 'line one\nline two',
        pastes: [{id: 'a', text: 'PASTED'}],
      }),
    ).toBe('> line one\n> line two\n\nWhat does this mean?\n\nPASTED');
  });

  it('is just the text when there is nothing else', () => {
    expect(composeMessage({text: 'hello'})).toBe('hello');
  });
});

it('the field grows to seven lines and no further', () => {
  expect(inputHeights(22, 7)).toEqual({min: 36, max: 168});
});
