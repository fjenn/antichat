import {decideSearch} from '../../search/decision';
import {builtinTools} from '../install';
import {matchingTools, selectTools} from '../selection';
import {toolCapsFor} from '../toolCaps';

describe('keyword-matched tools take a seat', () => {
  const catalog = builtinTools();
  const caps = toolCapsFor('LFM3-1.7B-Q4_K_M', 'lfm3', 8192);

  it('offers get_location for "where am I" on the smallest cap', () => {
    const text = 'Where am I right now? Use my location.';
    expect(matchingTools(text, catalog).map(tool => tool.name)).toEqual([
      'get_location',
    ]);
    const selection = selectTools({
      catalog,
      online: true,
      caps,
      userText: text,
    });
    expect(selection.names).toEqual(
      expect.arrayContaining(['web_search', 'read_url', 'get_location']),
    );
    expect(selection.names[0]).toBe('get_location');
    expect(
      decideSearch({userText: text, otherToolMatches: true}).decision,
    ).not.toBe('force');
  });

  it('leaves an ordinary question to the default set', () => {
    const selection = selectTools({
      catalog,
      online: true,
      caps,
      userText: 'What is the capital of Australia?',
    });
    expect(selection.names).not.toContain('get_location');
    expect(selection.names.length).toBeLessThanOrEqual(caps.maxTools);
  });
});
