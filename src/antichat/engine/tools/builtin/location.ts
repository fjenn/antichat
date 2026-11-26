/**
 * `get_location`: where the phone is, coarsely, and the local time there.
 * For "near me", "weather here", "what time is it here".
 *
 * The first call asks for the system location permission. Position is
 * rounded to 0.1° (about 11 km) before anything else sees it. Online, the
 * rounded position is turned into a city name (OpenStreetMap Nominatim,
 * keyless); offline the tool still answers with coordinates and time. Once
 * the user says no, the tool stops asking and tells the model to ask for a
 * place name instead.
 *
 * Needs the native module `@react-native-community/geolocation` and the
 * coarse-location entries in the manifest / Info.plist (integration lane).
 * Without them the tool answers "not available" and nothing breaks.
 */
import {isOnline} from '../connectivity';
import type {AntichatTool} from '../types';

export type LocationFix =
  | {status: 'ok'; latitude: number; longitude: number}
  | {status: 'denied' | 'unavailable'};

export interface LocationProvider {
  /** Asks for permission when it has not been decided, then reads once. */
  locate(signal?: AbortSignal): Promise<LocationFix>;
}

export type LocationFetch = (
  url: string,
  init?: {signal?: AbortSignal; headers?: Record<string, string>},
) => Promise<{ok: boolean; status: number; json(): Promise<any>}>;

const REVERSE = 'https://nominatim.openstreetmap.org/reverse';

/** City-level rounding: one decimal of a degree. */
export const coarse = (value: number): number => Math.round(value * 10) / 10;

export interface Place {
  city?: string;
  region?: string;
  country?: string;
}

export async function reverseGeocode(
  latitude: number,
  longitude: number,
  options: {
    fetchImpl?: LocationFetch;
    signal?: AbortSignal;
    locale?: string;
  } = {},
): Promise<Place> {
  const fetchImpl = options.fetchImpl ?? (fetch as unknown as LocationFetch);
  const response = await fetchImpl(
    `${REVERSE}?format=jsonv2&zoom=10&addressdetails=1&lat=${latitude}&lon=${longitude}` +
      `&accept-language=${encodeURIComponent((options.locale ?? 'en').slice(0, 2))}`,
    {signal: options.signal, headers: {'User-Agent': 'AntiChat/0.1'}},
  );
  if (!response.ok) {
    throw new Error(`place lookup failed (${response.status})`);
  }
  const address = (await response.json())?.address ?? {};
  return {
    city:
      address.city ??
      address.town ??
      address.village ??
      address.municipality ??
      address.county,
    region: address.state ?? address.region,
    country: address.country,
  };
}

function localTime(now: Date, timeZone?: string, locale?: string): string {
  try {
    return new Intl.DateTimeFormat(locale ?? 'en-GB', {
      weekday: 'long',
      day: 'numeric',
      month: 'long',
      year: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
      timeZone,
    }).format(now);
  } catch {
    return now.toString();
  }
}

export const LOCATION_DENIED_TEXT =
  'The user has not allowed location access. Ask them which city or place they mean; do not call this tool again.';
export const LOCATION_UNAVAILABLE_TEXT =
  'Location is not available on this phone right now. Ask the user which city or place they mean.';

export const LOCATION_OFF_TEXT =
  'The user switched location off in Settings. Ask them which city or place they mean.';

/**
 * Settings > Privacy "Use my location". Off: the tool is never offered and
 * answers without asking the system for a position if called anyway.
 */
let locationAllowed = true;

export function setLocationAllowed(allowed: boolean): void {
  locationAllowed = allowed;
}

export function isLocationAllowed(): boolean {
  return locationAllowed;
}

export interface LocationToolOptions {
  provider?: LocationProvider;
  fetchImpl?: LocationFetch;
  online?: () => boolean;
}

export function createLocationTool(
  options: LocationToolOptions = {},
): AntichatTool {
  /** A "no" lasts for the session: the tool does not ask again. */
  let denied = false;
  return {
    name: 'get_location',
    description:
      'The user\'s current city (approximate) and local time. Use for "near me", "here" or local weather when no place is named.',
    parameters: {type: 'object', properties: {}, additionalProperties: false},
    kind: 'local',
    tier: 'deferred',
    keywords: [
      'location',
      'where',
      'near',
      'nearby',
      'here',
      'city',
      'local',
      'around',
      'closest',
      'weather',
    ],
    triggers: ['near me', 'nearby', 'where am i', 'my location', 'around here'],
    // The permission dialog waits for the user.
    timeoutMs: 60_000,
    example: {},
    normalize: () => ({}),
    async execute(_args, context) {
      if (!locationAllowed) {
        return {text: LOCATION_OFF_TEXT};
      }
      if (denied) {
        return {text: LOCATION_DENIED_TEXT};
      }
      const provider = options.provider ?? platformLocation();
      let fix: LocationFix;
      try {
        fix = await provider.locate(context.signal);
      } catch {
        fix = {status: 'unavailable'};
      }
      if (fix.status === 'denied') {
        denied = true;
        return {text: LOCATION_DENIED_TEXT};
      }
      if (fix.status !== 'ok') {
        return {text: LOCATION_UNAVAILABLE_TEXT, isError: true};
      }
      const latitude = coarse(fix.latitude);
      const longitude = coarse(fix.longitude);
      let place: Place = {};
      if ((options.online ?? isOnline)()) {
        try {
          place = await reverseGeocode(latitude, longitude, {
            fetchImpl: options.fetchImpl,
            signal: context.signal,
            locale: context.locale,
          });
        } catch {
          // No name: the coordinates still answer the question.
        }
      }
      const name = [place.city, place.region, place.country]
        .filter((part, index, all) => part && all.indexOf(part) === index)
        .join(', ');
      const time = localTime(context.now, context.timeZone, context.locale);
      return {
        text:
          `Approximate location: ${name || 'city unknown'} ` +
          `(latitude ${latitude}, longitude ${longitude}, accurate to about 10 km). ` +
          `Local time: ${time}${context.timeZone ? ` (${context.timeZone})` : ''}.` +
          (place.city
            ? ` For weather, call the weather tool with place "${place.city}".`
            : ''),
      };
    },
  };
}

let platform: LocationProvider | null = null;

/**
 * The phone's location service. The native module is optional: when the
 * build does not have it, every call answers `unavailable`.
 */
export function platformLocation(): LocationProvider {
  platform ??= {
    async locate() {
      let Geolocation: any;
      let RN: any;
      try {
        RN = require('react-native');
        const loaded = require('@react-native-community/geolocation');
        Geolocation = loaded?.default ?? loaded;
      } catch {
        return {status: 'unavailable'};
      }
      if (!Geolocation?.getCurrentPosition) {
        return {status: 'unavailable'};
      }
      if (RN.Platform.OS === 'android') {
        const permission =
          RN.PermissionsAndroid.PERMISSIONS.ACCESS_COARSE_LOCATION;
        const answer = await RN.PermissionsAndroid.request(permission);
        if (answer !== RN.PermissionsAndroid.RESULTS.GRANTED) {
          return {status: 'denied'};
        }
      }
      return new Promise<LocationFix>(resolve => {
        const read = () =>
          Geolocation.getCurrentPosition(
            (position: any) =>
              resolve({
                status: 'ok',
                latitude: position.coords.latitude,
                longitude: position.coords.longitude,
              }),
            // code 1 = PERMISSION_DENIED
            (error: any) =>
              resolve({status: error?.code === 1 ? 'denied' : 'unavailable'}),
            {enableHighAccuracy: false, timeout: 20_000, maximumAge: 600_000},
          );
        if (RN.Platform.OS === 'ios' && Geolocation.requestAuthorization) {
          Geolocation.requestAuthorization(read, () =>
            resolve({status: 'denied'}),
          );
        } else {
          read();
        }
      });
    },
  };
  return platform;
}
