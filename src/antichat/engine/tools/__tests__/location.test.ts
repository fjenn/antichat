import {
  LOCATION_DENIED_TEXT,
  coarse,
  createLocationTool,
  type LocationFix,
} from '../builtin/location';

const ctx = {
  now: new Date('2026-11-24T15:30:00Z'),
  timeZone: 'Europe/Lisbon',
  locale: 'en-GB',
};

const geocoder = () => {
  const urls: string[] = [];
  const fetchImpl = async (url: string) => {
    urls.push(url);
    return {
      ok: true,
      status: 200,
      json: async () => ({
        address: {city: 'Lisbon', state: 'Lisbon', country: 'Portugal'},
      }),
    };
  };
  return {urls, fetchImpl};
};

describe('get_location', () => {
  it('returns the city, coarse coordinates and local time', async () => {
    const {urls, fetchImpl} = geocoder();
    const tool = createLocationTool({
      provider: {
        locate: async () => ({
          status: 'ok',
          latitude: 38.72231,
          longitude: -9.13934,
        }),
      },
      fetchImpl,
      online: () => true,
    });
    expect(tool.tier).toBe('deferred');
    const result = await tool.execute({}, ctx);
    expect(result.text).toContain('Lisbon, Portugal');
    expect(result.text).toContain('latitude 38.7, longitude -9.1');
    expect(result.text).toContain('15:30');
    expect(result.text).toContain('place "Lisbon"');
    // Only the rounded position leaves the phone.
    expect(urls[0]).toContain('lat=38.7&lon=-9.1');
    expect(urls[0]).not.toContain('38.72');
    expect(coarse(-9.13934)).toBe(-9.1);
  });

  it('answers offline without a lookup', async () => {
    const {urls, fetchImpl} = geocoder();
    const tool = createLocationTool({
      provider: {
        locate: async () => ({status: 'ok', latitude: 52.52, longitude: 13.4}),
      },
      fetchImpl,
      online: () => false,
    });
    const result = await tool.execute({}, ctx);
    expect(urls).toHaveLength(0);
    expect(result.text).toContain(
      'city unknown (latitude 52.5, longitude 13.4',
    );
  });

  it('stops asking once the user said no', async () => {
    const locate = jest.fn(
      async (): Promise<LocationFix> => ({status: 'denied'}),
    );
    const tool = createLocationTool({provider: {locate}, online: () => false});
    expect((await tool.execute({}, ctx)).text).toBe(LOCATION_DENIED_TEXT);
    expect((await tool.execute({}, ctx)).text).toBe(LOCATION_DENIED_TEXT);
    expect(locate).toHaveBeenCalledTimes(1);
  });

  it('reports unavailable when the phone has no fix', async () => {
    const tool = createLocationTool({
      provider: {
        locate: async () => {
          throw new Error('no module');
        },
      },
    });
    expect((await tool.execute({}, ctx)).isError).toBe(true);
  });
});
