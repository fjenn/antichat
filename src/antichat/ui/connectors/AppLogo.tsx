import React, {useEffect, useState} from 'react';
import {View} from 'react-native';
import {SvgXml} from 'react-native-svg';
import {StyleSheet} from 'react-native-unistyles';

import {Text} from '../primitives';

export interface AppLogoProps {
  name: string;
  /** https URL of an SVG logo; a letter tile is drawn without one. */
  uri?: string;
  size?: number;
}

/** Logos already fetched this session; `null` is one that cannot be drawn. */
const cache = new Map<string, string | null>();
const pending = new Map<string, Promise<string | null>>();
const LAZY_MS = 120;

const percent = (value: string) =>
  Math.max(0, Math.min(255, Math.round((parseFloat(value) / 100) * 255)));

/**
 * Makes a downloaded logo drawable, or says it is not (null). Exported
 * drawings often write colours as `rgb(0%, 36.5%, 72.9%)`, which the SVG
 * renderer on iOS draws as nothing: those become plain numbers.
 */
export function drawableSvg(source: string): string | null {
  const start = source.indexOf('<svg');
  if (
    start < 0 ||
    !/<(path|rect|circle|ellipse|polygon|polyline|line|use|image|text)\b/.test(
      source,
    )
  ) {
    return null;
  }
  return (
    source
      .slice(start)
      // Whitespace written as character references (`&#10;` inside path
      // data) makes the native SVG parser throw: plain spaces instead.
      .replace(/&#(?:x0*(?:9|a|d|20)|0*(?:9|10|13|32));/gi, ' ')
      .replace(
        /rgb\(\s*([\d.]+)%\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%\s*\)/g,
        (_all, r, g, b) => `rgb(${percent(r)},${percent(g)},${percent(b)})`,
      )
  );
}

function load(uri: string): Promise<string | null> {
  let job = pending.get(uri);
  if (!job) {
    job = fetch(uri)
      .then(answer => (answer.ok ? answer.text() : ''))
      .then(drawableSvg)
      .catch(() => null)
      .then(xml => {
        cache.set(uri, xml);
        pending.delete(uri);
        return xml;
      });
    pending.set(uri, job);
  }
  return job;
}

/**
 * A logo the SVG renderer cannot draw (bad path data throws while the
 * elements render, after `SvgXml`'s own parse check) falls back to the
 * letter tile instead of taking the screen down.
 */
class LogoBoundary extends React.Component<
  {onError: () => void; children: React.ReactNode},
  {broken: boolean}
> {
  state = {broken: false};

  static getDerivedStateFromError() {
    return {broken: true};
  }

  componentDidCatch() {
    this.props.onError();
  }

  render() {
    return this.state.broken ? null : this.props.children;
  }
}

/**
 * An app's logo on a rounded tile. Until the logo is there, and whenever it
 * cannot be loaded or drawn, the tile shows the app's first letter.
 */
export function AppLogo({name, uri, size = 40}: AppLogoProps) {
  const [xml, setXml] = useState<string | null>(
    uri ? (cache.get(uri) ?? null) : null,
  );
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    setFailed(false);
    if (!uri) {
      setXml(null);
      return;
    }
    const known = cache.get(uri);
    if (known !== undefined) {
      setXml(known);
      return;
    }
    let current = true;
    // Rows flung past within a moment never fetch: the directory has
    // ~1,700 apps and only the ones that stay on screen need a logo.
    const timer = setTimeout(() => {
      load(uri).then(loaded => {
        if (current) {
          setXml(loaded);
        }
      });
    }, LAZY_MS);
    return () => {
      current = false;
      clearTimeout(timer);
    };
  }, [uri]);
  const inner = Math.round(size * 0.6);
  return (
    <View style={styles.tile(size)} accessibilityElementsHidden>
      {xml && !failed ? (
        <LogoBoundary onError={() => setFailed(true)}>
          <SvgXml
            xml={xml}
            width={inner}
            height={inner}
            onError={() => setFailed(true)}
          />
        </LogoBoundary>
      ) : (
        <Text variant="headline" style={styles.letter}>
          {name.trim().charAt(0).toUpperCase() || '?'}
        </Text>
      )}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  letter: {
    color: theme.dark ? '#5D5D66' : theme.colors.textSecondary,
  },
  tile: (size: number) => ({
    width: size,
    height: size,
    borderRadius: Math.round(size * 0.28),
    alignItems: 'center',
    justifyContent: 'center',
    // Logos are drawn for a light ground; in the dark theme the tile stays light.
    backgroundColor: theme.dark ? '#F4F4F5' : theme.colors.surface,
    borderWidth: theme.sizes.hairline,
    borderColor: theme.colors.border,
    overflow: 'hidden',
  }),
}));
