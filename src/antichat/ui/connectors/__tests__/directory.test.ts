import type {Toolkit} from '../../../engine/mcp/relay';
import {buildDirectory, groupOf} from '../directory';

const kit = (
  slug: string,
  categories: string[],
  auth: Toolkit['auth'] = 'oauth',
): Toolkit => ({
  slug,
  name: slug.charAt(0).toUpperCase() + slug.slice(1),
  description: '',
  categories,
  auth,
  logo: '',
});

describe('app directory', () => {
  const toolkits = [
    kit('zoom', ['video conferencing']),
    kit('gmail', ['email']),
    kit('postgres', ['model context protocol', 'databases']),
    kit('mystery', ['tag1']),
    kit('slack', ['team chat']),
    kit('hidden', ['email'], 'none'),
    kit('notion', ['productivity', 'notes']),
  ];

  it('places apps by their most telling category', () => {
    expect(groupOf(toolkits[2]!).id).toBe('developer');
    expect(groupOf(toolkits[3]!).id).toBe('other');
    expect(groupOf(toolkits[6]!).id).toBe('productivity');
  });

  it('lists popular apps first and every app under a group header', () => {
    const all = buildDirectory(toolkits);
    expect(all.popular.map(t => t.slug)).toEqual([
      'gmail',
      'notion',
      'slack',
      'zoom',
    ]);
    expect(all.rows.map(row => row.key)).toEqual([
      'group-communication',
      'gmail',
      'slack',
      'zoom',
      'group-productivity',
      'notion',
      'group-developer',
      'postgres',
      'group-other',
      'mystery',
    ]);
    expect(all.groups.map(g => [g.id, g.count])).toEqual([
      ['communication', 3],
      ['productivity', 1],
      ['developer', 1],
      ['other', 1],
    ]);
  });

  it('lists only the headers of collapsed groups', () => {
    const some = buildDirectory(toolkits, null, new Set(['productivity']));
    expect(some.rows.map(row => row.key)).toEqual([
      'group-communication',
      'group-productivity',
      'notion',
      'group-developer',
      'group-other',
    ]);
    const header = some.rows[0];
    expect(header.kind === 'header' && [header.count, header.expanded]).toEqual(
      [3, false],
    );
  });

  it('narrows to one group without headers', () => {
    const one = buildDirectory(toolkits, 'communication');
    expect(one.rows.map(row => row.key)).toEqual(['gmail', 'slack', 'zoom']);
  });
});
