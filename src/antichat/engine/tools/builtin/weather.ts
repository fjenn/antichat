/**
 * Weather through Open-Meteo: keyless, no account, CC BY 4.0 data. Online
 * only. Returns a `WeatherCard` the app draws without the model, plus one
 * line of text the model can answer from.
 */
import type {WeatherCard, WeatherDay} from '../cards';
import type {AntichatTool, ToolSource} from '../types';

export type FetchLike = (
  url: string,
  init?: {signal?: AbortSignal; headers?: Record<string, string>},
) => Promise<{ok: boolean; status: number; json(): Promise<any>}>;

const GEOCODE = 'https://geocoding-api.open-meteo.com/v1/search';
const FORECAST = 'https://api.open-meteo.com/v1/forecast';

/** WMO weather interpretation codes → words and a stable icon key. */
export function describeWeatherCode(code: number): {
  condition: string;
  icon: string;
} {
  if (code === 0) {
    return {condition: 'clear sky', icon: 'clear'};
  }
  if (code <= 2) {
    return {
      condition: code === 1 ? 'mainly clear' : 'partly cloudy',
      icon: 'partly',
    };
  }
  if (code === 3) {
    return {condition: 'overcast', icon: 'cloudy'};
  }
  if (code === 45 || code === 48) {
    return {condition: 'fog', icon: 'fog'};
  }
  if (code >= 51 && code <= 57) {
    return {condition: 'drizzle', icon: 'drizzle'};
  }
  if (code >= 61 && code <= 67) {
    return {
      condition:
        code === 61 ? 'light rain' : code === 65 ? 'heavy rain' : 'rain',
      icon: 'rain',
    };
  }
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) {
    return {condition: 'snow', icon: 'snow'};
  }
  if (code >= 80 && code <= 82) {
    return {condition: 'rain showers', icon: 'rain'};
  }
  if (code >= 95) {
    return {condition: 'thunderstorm', icon: 'storm'};
  }
  return {condition: 'unknown', icon: 'cloudy'};
}

const FAHRENHEIT_COUNTRIES = new Set([
  'US',
  'BS',
  'BZ',
  'KY',
  'LR',
  'PW',
  'FM',
  'MH',
]);

export function unitForLocale(locale?: string): 'C' | 'F' {
  const region = locale?.split(/[-_]/)[1]?.toUpperCase();
  return region && FAHRENHEIT_COUNTRIES.has(region) ? 'F' : 'C';
}

const toF = (celsius: number): number => Math.round((celsius * 9) / 5 + 32);
const show = (celsius: number, unit: 'C' | 'F'): string =>
  unit === 'F' ? `${toF(celsius)} °F` : `${Math.round(celsius)} °C`;

export async function fetchWeather(
  place: string,
  options: {
    fetchImpl?: FetchLike;
    signal?: AbortSignal;
    locale?: string;
    days?: number;
  } = {},
): Promise<WeatherCard> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as FetchLike);
  const language = (options.locale ?? 'en').slice(0, 2);
  const geo = await fetchImpl(
    `${GEOCODE}?name=${encodeURIComponent(place)}&count=1&language=${language}&format=json`,
    {signal: options.signal},
  );
  if (!geo.ok) {
    throw new Error(`place lookup failed (${geo.status})`);
  }
  const hit = (await geo.json())?.results?.[0];
  if (!hit) {
    throw new Error(`no place called "${place}" was found`);
  }
  const days = Math.min(Math.max(options.days ?? 5, 1), 7);
  const response = await fetchImpl(
    `${FORECAST}?latitude=${hit.latitude}&longitude=${hit.longitude}` +
      '&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code' +
      '&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max' +
      `&timezone=auto&forecast_days=${days}`,
    {signal: options.signal},
  );
  if (!response.ok) {
    throw new Error(`forecast failed (${response.status})`);
  }
  const data = await response.json();
  const current = data?.current;
  if (!current || typeof current.temperature_2m !== 'number') {
    throw new Error('the forecast came back empty');
  }
  const daily = data.daily ?? {};
  const list: WeatherDay[] = (daily.time ?? []).map(
    (date: string, index: number) => ({
      date,
      minC: daily.temperature_2m_min?.[index],
      maxC: daily.temperature_2m_max?.[index],
      ...describeWeatherCode(daily.weather_code?.[index] ?? -1),
      precipitationChance:
        daily.precipitation_probability_max?.[index] ?? undefined,
    }),
  );
  return {
    type: 'weather',
    place: hit.name,
    country: hit.country,
    latitude: hit.latitude,
    longitude: hit.longitude,
    unit: unitForLocale(options.locale),
    current: {
      temperatureC: current.temperature_2m,
      feelsLikeC: current.apparent_temperature,
      ...describeWeatherCode(current.weather_code ?? -1),
      windKmh: current.wind_speed_10m,
      humidity: current.relative_humidity_2m,
      observedAt: current.time,
    },
    days: list,
    source: {name: 'Open-Meteo', url: 'https://open-meteo.com/'},
  };
}

export function weatherText(card: WeatherCard): string {
  const unit = card.unit;
  const now = card.current;
  const lines = [
    `Weather in ${card.place}${card.country ? `, ${card.country}` : ''} (observed ${now.observedAt}): ${show(now.temperatureC, unit)}, ${now.condition}` +
      (now.feelsLikeC !== undefined
        ? `, feels like ${show(now.feelsLikeC, unit)}`
        : '') +
      (now.windKmh !== undefined
        ? `, wind ${Math.round(now.windKmh)} km/h`
        : '') +
      (now.humidity !== undefined
        ? `, humidity ${Math.round(now.humidity)}%`
        : '') +
      '.',
  ];
  for (const day of card.days) {
    lines.push(
      `${day.date}: ${show(day.minC, unit)} to ${show(day.maxC, unit)}, ${day.condition}` +
        (day.precipitationChance !== undefined &&
        day.precipitationChance !== null
          ? `, ${day.precipitationChance}% chance of precipitation`
          : ''),
    );
  }
  return lines.join('\n');
}

export function createWeatherTool(fetchImpl?: FetchLike): AntichatTool {
  return {
    name: 'weather',
    description:
      'Current weather and a forecast of up to 7 days for a city or place.',
    parameters: {
      type: 'object',
      properties: {
        place: {
          type: 'string',
          description: 'City or place name, e.g. "Lisbon"',
          minLength: 1,
        },
        days: {
          type: 'integer',
          description: 'Forecast days, 1-7',
          minimum: 1,
          maximum: 7,
        },
      },
      required: ['place'],
      additionalProperties: false,
    },
    kind: 'online',
    tier: 'always',
    keywords: [
      'weather',
      'forecast',
      'temperature',
      'rain',
      'snow',
      'wind',
      'umbrella',
      'wetter',
    ],
    triggers: [
      'forecast',
      'wetter',
      'wettervorhersage',
      'météo',
      'clima',
      'weer',
    ],
    timeoutMs: 10000,
    example: {place: 'Lisbon'},
    normalize: args => {
      const place = args.place ?? args.location ?? args.city ?? args.query;
      const out: Record<string, unknown> = place === undefined ? {} : {place};
      if (args.days !== undefined) {
        out.days = args.days;
      }
      return out;
    },
    async execute(args, context) {
      try {
        const card = await fetchWeather(String(args.place), {
          fetchImpl,
          signal: context.signal,
          locale: context.locale,
          days: args.days as number | undefined,
        });
        const text = weatherText(card);
        const source: ToolSource = {
          url: card.source.url,
          title: `Open-Meteo forecast for ${card.place}`,
          site: 'open-meteo.com',
          evidence: text,
          fetched: true,
        };
        return {text, card, sources: [source]};
      } catch (error) {
        return {text: `weather: ${(error as Error).message}.`, isError: true};
      }
    },
  };
}
