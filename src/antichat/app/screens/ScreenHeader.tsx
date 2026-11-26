import React from 'react';
import {View} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import {StyleSheet} from 'react-native-unistyles';

import {useT} from '../../locales';
import {IconButton, Text} from '../../ui/primitives';

/** Top bar of a pushed screen: glass back button and a centred title. */
export function ScreenHeader({title}: {title: string}) {
  const t = useT();
  const navigation = useNavigation();
  return (
    <View style={styles.bar}>
      <IconButton
        testID="header-back"
        icon="chevronBack"
        variant="glass"
        accessibilityLabel={t('shell.back')}
        onPress={() => navigation.goBack()}
      />
      <Text
        variant="headline"
        align="center"
        numberOfLines={1}
        accessibilityRole="header"
        style={styles.title}>
        {title}
      </Text>
      <View style={styles.spacer} />
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  bar: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingTop: rt.insets.top + theme.spacing.xs,
    paddingBottom: theme.spacing.sm,
    paddingHorizontal: theme.spacing.lg,
  },
  title: {
    flex: 1,
  },
  spacer: {
    width: theme.sizes.topBarButton,
  },
}));
