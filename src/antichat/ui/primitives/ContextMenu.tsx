import React from 'react';
import {Platform, type StyleProp, type ViewStyle} from 'react-native';
import {MenuView, type MenuAction} from '@react-native-menu/menu';
import {useUnistyles} from 'react-native-unistyles';

import {haptics} from './haptics';
import {SF_SYMBOLS, type IconName} from './icons';

export interface MenuItem {
  id: string;
  title: string;
  subtitle?: string;
  icon?: IconName;
  destructive?: boolean;
  disabled?: boolean;
  /** Shows a check mark (the current model, the current theme). */
  checked?: boolean;
  /**
   * Items of a group. With `inline` they are listed in place under a
   * divider (a section); without it they open as a submenu.
   */
  children?: MenuItem[];
  inline?: boolean;
}

export interface ContextMenuProps {
  items: MenuItem[];
  onSelect: (id: string) => void;
  /** `press` for dropdowns (model menu, •••), `longPress` for rows. */
  trigger?: 'press' | 'longPress';
  title?: string;
  children: React.ReactNode;
  style?: StyleProp<ViewStyle>;
  testID?: string;
  onOpen?: () => void;
  onClose?: () => void;
}

/**
 * A native menu anchored to its child: UIMenu on iOS, PopupMenu on Android.
 * The child keeps its own accessibility label and press handling.
 */
export function ContextMenu({
  items,
  onSelect,
  trigger = 'press',
  title,
  children,
  style,
  testID,
  onOpen,
  onClose,
}: ContextMenuProps) {
  const {theme} = useUnistyles();
  const toAction = (item: MenuItem): MenuAction => ({
    id: item.id,
    title: item.title,
    subtitle: item.subtitle,
    state: item.checked ? 'on' : undefined,
    attributes: {
      destructive: item.destructive,
      disabled: item.disabled,
    },
    // System icons only inside native menus, and only on iOS.
    image:
      Platform.OS === 'ios' && item.icon ? SF_SYMBOLS[item.icon] : undefined,
    imageColor: item.destructive
      ? theme.colors.danger
      : theme.colors.textPrimary,
    titleColor:
      Platform.OS === 'android' && item.destructive
        ? theme.colors.danger
        : undefined,
    subactions: item.children?.map(toAction),
    displayInline: item.children ? item.inline : undefined,
  });
  // Android's popup has no sections: an inline group would become a
  // submenu there, so its items are listed in place instead.
  const flat =
    Platform.OS === 'android'
      ? items.flatMap(item =>
          item.children && item.inline ? item.children : [item],
        )
      : items;
  const actions: MenuAction[] = flat.map(toAction);
  return (
    <MenuView
      testID={testID}
      title={title}
      actions={actions}
      shouldOpenOnLongPress={trigger === 'longPress'}
      themeVariant={theme.scheme}
      onOpenMenu={() => {
        if (trigger === 'longPress') {
          haptics.press();
        }
        onOpen?.();
      }}
      onCloseMenu={onClose}
      onPressAction={({nativeEvent}) => onSelect(nativeEvent.event)}
      style={style}>
      {children}
    </MenuView>
  );
}
