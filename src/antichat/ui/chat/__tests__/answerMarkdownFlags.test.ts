import {FLAGS} from '../thread/markdownFlags';

describe('answer markdown flags', () => {
  it('keeps single line breaks, with maths on and admonitions off', () => {
    expect(FLAGS.hardSoftBreaks).toBe(true);
    expect(FLAGS.latexMath).toBe(true);
    expect(FLAGS.admonitions).toBe(false);
  });
});
