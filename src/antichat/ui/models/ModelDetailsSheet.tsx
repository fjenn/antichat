import React, {forwardRef, useState} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import type {ModelView} from '../../contracts';
import {useT} from '../../locales';
import {PressableScale, Sheet, Text, type SheetHandle} from '../primitives';
import {formatBytes} from './format';
import {isMultilingual, languageCount, languageNames} from './languages';

/** Roughly how many words fit in a token budget. */
const WORDS_PER_TOKEN = 0.75;

const MAX_PHONE_RAM_GB = 32;

const roundWords = (tokens: number): string => {
  const words = tokens * WORDS_PER_TOKEN;
  const rounded =
    words >= 1000 ? Math.round(words / 1000) * 1000 : Math.round(words);
  return rounded.toLocaleString('en-US');
};

export interface ModelDetailsSheetProps {
  model: ModelView | undefined;
}

/**
 * For the curious: the real name of the model behind "your assistant", its
 * size and licence. The only place a model name appears.
 */
export const ModelDetailsSheet = forwardRef<
  SheetHandle,
  ModelDetailsSheetProps
>(function Details({model}, ref) {
  const t = useT();
  const port = getPorts().model;
  const device = usePort(port, current => current.device);
  const capabilities = usePort(port, current => current.capabilities);
  const active = usePort(port, current => current.activeModelId);
  if (!model) {
    return <Sheet ref={ref}>{null}</Sheet>;
  }
  const loaded = model.state.status === 'loaded' ? model.state.info : null;
  const contextSize =
    loaded?.contextSize ??
    (capabilities && (active === model.id || active === null)
      ? capabilities.contextSize
      : undefined);
  const ramGb = device
    ? Math.round(device.snapshot.totalRamBytes / 1024 ** 3)
    : undefined;
  const rows: Array<[string, string]> = [
    [t('models.detailsSheet.model'), model.displayName],
    [t('models.detailsSheet.size'), formatBytes(model.downloadBytes)],
    [
      t('models.detailsSheet.licence'),
      model.openSource
        ? model.licenceName
        : t('models.detailsSheet.sourceAvailable', {name: model.licenceName}),
    ],
    [
      t('models.detailsSheet.images'),
      model.vision ? t('models.detailsSheet.yes') : t('models.detailsSheet.no'),
    ],
  ];
  if (contextSize) {
    rows.push([
      t('models.detailsSheet.context'),
      t('models.detailsSheet.contextValue', {words: roundWords(contextSize)}),
    ]);
  }
  if (loaded?.tokensPerSecond) {
    rows.push([
      t('models.detailsSheet.speed'),
      t('models.detailsSheet.speedValue', {
        value: Math.max(
          1,
          Math.round(loaded.tokensPerSecond * WORDS_PER_TOKEN),
        ),
      }),
    ]);
  }
  rows.push([
    t('models.detailsSheet.runsOn'),
    t('models.detailsSheet.runsOnValue'),
  ]);
  if (model.recommended) {
    rows.push([
      t('models.detailsSheet.chosen'),
      // A simulator reports the computer's memory; no phone has that much.
      ramGb && ramGb <= MAX_PHONE_RAM_GB
        ? t('models.detailsSheet.chosenValue', {ram: ramGb})
        : t('models.detailsSheet.chosenPlain'),
    ]);
  }
  return (
    <Sheet
      ref={ref}
      testID="model-details"
      title={t('models.detailsSheet.title')}>
      <View style={styles.rows}>
        {rows.map(([label, value]) => (
          <View key={label} style={styles.row}>
            <Text variant="callout" color="textSecondary" style={styles.label}>
              {label}
            </Text>
            <Text variant="callout" align="right" style={styles.value}>
              {value}
            </Text>
          </View>
        ))}
        <LanguagesRow key={model.id} model={model} />
      </View>
      {model.licenceNotice ? (
        <Text variant="footnote" color="textSecondary">
          {model.licenceNotice}
        </Text>
      ) : null}
    </Sheet>
  );
});

/**
 * "Languages": the card's list when short, otherwise "Multilingual (N
 * languages)" with the full list one tap away. Absent when the model card
 * says nothing about languages.
 */
function LanguagesRow({model}: {model: ModelView}) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const count = languageCount(model.languages);
  if (!count) {
    return null;
  }
  const names = languageNames(model.languages?.codes ?? []);
  const summed = isMultilingual(model.languages) || names.length === 0;
  const value = summed
    ? t('models.detailsSheet.multilingual', {count})
    : names.join(', ');
  const expandable = summed && names.length > 0;
  return (
    <View testID="model-details-languages" style={styles.row}>
      <Text variant="callout" color="textSecondary" style={styles.label}>
        {t('models.detailsSheet.languages')}
      </Text>
      <View style={styles.value}>
        <Text variant="callout" align="right">
          {value}
        </Text>
        {expandable && open ? (
          <Text
            testID="model-details-language-list"
            variant="footnote"
            color="textSecondary"
            align="right">
            {names.join(', ')}
          </Text>
        ) : null}
        {expandable ? (
          <PressableScale
            testID="model-details-languages-toggle"
            accessibilityRole="button"
            accessibilityState={{expanded: open}}
            hitSlop={8}
            scale={false}
            onPress={() => setOpen(!open)}
            style={styles.toggle}>
            <Text variant="footnote" color="accent" align="right">
              {open
                ? t('models.detailsSheet.hideLanguages')
                : t('models.detailsSheet.showLanguages')}
            </Text>
          </PressableScale>
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  toggle: {
    alignSelf: 'flex-end',
    marginTop: theme.spacing.xxs,
  },
  rows: {
    borderRadius: theme.radii.lg,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.xs,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: theme.spacing.lg,
    paddingVertical: theme.spacing.md,
  },
  label: {
    flexShrink: 0,
    maxWidth: '45%',
  },
  value: {
    flex: 1,
  },
}));
