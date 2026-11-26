import type {AudioRoute} from './ports';

/** An AVAudioSession port type or Android device category → our route. */
export function routeFromPort(port: string | undefined): AudioRoute {
  const name = (port ?? '').toLowerCase();
  if (!name) {
    return 'unknown';
  }
  if (name.includes('car')) {
    return 'car';
  }
  if (name.includes('bluetooth') || name.includes('airpods')) {
    return 'bluetooth';
  }
  if (
    name.includes('headphone') ||
    name.includes('headset') ||
    name.includes('usb') ||
    name.includes('wired')
  ) {
    return 'wired';
  }
  if (name.includes('receiver') || name.includes('earpiece')) {
    return 'earpiece';
  }
  return name.includes('speaker') ? 'speaker' : 'unknown';
}
