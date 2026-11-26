/**
 * The composer: a floating pill that grows with the text, with + on one side
 * and the four-state button on the other. It rides the keyboard frame by
 * frame (`KeyboardStickyView`), and the conversation scrolls behind it.
 *
 * Growth and the keyboard offset come from the M0 spike
 * (`src/antichat/spike-ui/Composer.tsx`).
 */
import React, {
  forwardRef,
  useCallback,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
} from 'react';
import {
  Image,
  ScrollView,
  TextInput,
  View,
  type LayoutChangeEvent,
} from 'react-native';
import {
  KeyboardStickyView,
  useKeyboardState,
} from 'react-native-keyboard-controller';
import Animated, {
  Easing,
  FadeIn,
  FadeOut,
  LinearTransition,
  useReducedMotion,
  type SharedValue,
} from 'react-native-reanimated';
import {observer} from 'mobx-react';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import {currentBackend} from '../../adapters/backend';
import type {SendInput} from '../../contracts';
import {useT} from '../../locales';
import {typography} from '../../theme';
import {chatUi, type EditTarget} from '../chat/chatUi';
import {isLoadableImage} from '../chat/format';
import {
  Chip,
  ContextMenu,
  EdgeFade,
  GlassSurface,
  Icon,
  IconButton,
  PressableScale,
  Text,
  haptics,
  toast,
  type SheetHandle,
} from '../primitives';
import {DictationButton, DictationLayer, useDictating} from '../voice';
import {AttachSheet} from './AttachSheet';
import {
  MAX_LINES,
  composeMessage,
  detectLargePaste,
  pasteLimitFor,
  trailingState,
  type PastedText,
} from './composerState';
import {drafts} from './drafts';
import {TOOL_ICONS, toolChipName} from './toolKinds';
import {TRAILING_SIZE, TrailingButton} from './TrailingButton';

export const COMPOSER_INPUT_ID = 'antichat-composer-input';

const FONT_SIZE = 16;
const LINE_HEIGHT = 22;
const INPUT_PAD = 7;
const PILL_PAD = 8;
const BUTTON = TRAILING_SIZE;
/** The input's largest text scale; above it the pill would eat the screen. */
const MAX_SCALE = 1.8;
/** After focus, how long the software keyboard gets to show up. */
const HARDWARE_KEYBOARD_GRACE_MS = 600;

const GROW = LinearTransition.duration(180).easing(Easing.bezier(0.2, 0, 0, 1));

export interface ComposerHandle {
  focus(): void;
  blur(): void;
  setText(text: string): void;
  /** Adds text at the end of what is typed (dictation). */
  insertText(text: string): void;
}

export interface ComposerProps {
  conversationId: string | null;
  generating: boolean;
  temporary?: boolean;
  /** Offline chat: the + sheet greys out what needs the network. */
  offline?: boolean;
  onSend: (input: SendInput) => void;
  onEdit: (target: EditTarget, text: string) => void;
  onStop: () => void;
  /** Receives the height of the dock, for the list's bottom inset. */
  height: SharedValue<number>;
  /** Rides above the pill (the starters of an empty chat). */
  above?: React.ReactNode;
}

export const Composer = observer(
  forwardRef<ComposerHandle, ComposerProps>(function ComposerDock(
    {
      conversationId,
      generating,
      temporary = false,
      offline = false,
      onSend,
      onEdit,
      onStop,
      height,
      above,
    },
    ref,
  ) {
    const t = useT();
    const {theme, rt} = useUnistyles();
    const reduceMotion = useReducedMotion();
    const ports = getPorts();
    const input = useRef<React.ComponentRef<typeof TextInput>>(null);
    const sheet = useRef<SheetHandle>(null);
    const dictating = useDictating();
    const [text, setTextState] = useState(() => drafts.get(conversationId));
    const [pastes, setPastes] = useState<PastedText[]>([]);
    const [focused, setFocused] = useState(false);
    const [hardwareKeyboard, setHardwareKeyboard] = useState(false);
    const [dockHeight, setDockHeight] = useState(0);
    const textRef = useRef(text);
    /** A paste the user chose to keep in the field stays there. */
    const keepInField = useRef(false);
    const beforeEdit = useRef<string | null>(null);

    const attachments = usePort(ports.files, port =>
      port.drafts(conversationId),
    );
    const tools = usePort(ports.tools, port => port.tools);
    const activeToolIds = usePort(ports.tools, port =>
      port.activeToolIds(conversationId),
    );
    const deviceClass = usePort(ports.model, port => port.deviceClass);
    const models = usePort(ports.model, port => port.models);
    const activeModelId = usePort(ports.model, port => port.activeModelId);
    const keyboardVisible = useKeyboardState(state => state.isVisible);

    const editing = chatUi.editing;
    const quote = chatUi.quote;

    const setText = useCallback(
      (next: string) => {
        textRef.current = next;
        setTextState(next);
        if (!chatUi.editing) {
          drafts.set(conversationId, next);
        }
      },
      [conversationId],
    );

    useImperativeHandle(ref, () => ({
      focus: () => input.current?.focus(),
      blur: () => input.current?.blur(),
      setText,
      insertText: (added: string) => {
        const current = textRef.current;
        const gap = current && !/\s$/.test(current) ? ' ' : '';
        setText(current + gap + added);
      },
    }));

    // Another chat: its own draft, nothing carried over.
    const shownFor = useRef(conversationId);
    useEffect(() => {
      if (shownFor.current === conversationId) {
        return;
      }
      shownFor.current = conversationId;
      const draft = drafts.get(conversationId);
      textRef.current = draft;
      setTextState(draft);
      setPastes([]);
      keepInField.current = false;
    }, [conversationId]);

    // Drafts are read from disk after the first frame.
    useEffect(() => {
      drafts.persistent = currentBackend() === 'real';
      drafts
        .load()
        .then(() => {
          if (textRef.current === '' && !chatUi.editing) {
            const draft = drafts.get(shownFor.current);
            if (draft) {
              textRef.current = draft;
              setTextState(draft);
            }
          }
        })
        .catch(() => {});
    }, []);

    // Editing a message: its text goes into the field, the draft waits.
    const editingId = editing?.messageId ?? null;
    useEffect(() => {
      if (editing) {
        beforeEdit.current = textRef.current;
        textRef.current = editing.text;
        setTextState(editing.text);
        keepInField.current = true;
        input.current?.focus();
      } else if (beforeEdit.current !== null) {
        const draft = beforeEdit.current;
        beforeEdit.current = null;
        textRef.current = draft;
        setTextState(draft);
        keepInField.current = false;
      }
      // Only the message being edited matters here.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [editingId]);

    // Quoting part of an answer is the start of a question about it.
    useEffect(() => {
      if (quote) {
        input.current?.focus();
      }
    }, [quote]);

    // A focused field without a software keyboard means a hardware one:
    // there, Return sends.
    useEffect(() => {
      if (!focused || keyboardVisible) {
        setHardwareKeyboard(false);
        return;
      }
      const timer = setTimeout(
        () => setHardwareKeyboard(true),
        HARDWARE_KEYBOARD_GRACE_MS,
      );
      return () => clearTimeout(timer);
    }, [focused, keyboardVisible]);

    const onChangeText = (next: string) => {
      if (!keepInField.current) {
        const split = detectLargePaste(
          textRef.current,
          next,
          pasteLimitFor(deviceClass),
        );
        if (split) {
          haptics.selection();
          setPastes(list => [
            ...list,
            {id: `paste-${Date.now()}`, text: split.pasted},
          ]);
          setText(split.text);
          return;
        }
      }
      if (next.length === 0) {
        keepInField.current = false;
      }
      setText(next);
    };

    const showInField = (paste: PastedText) => {
      keepInField.current = true;
      setPastes(list => list.filter(item => item.id !== paste.id));
      const current = textRef.current;
      setText(current ? `${current}\n${paste.text}` : paste.text);
    };

    const ready = attachments.filter(item => item.state.status === 'ready');
    const preparing = attachments.some(
      item => item.state.status === 'processing',
    );
    const state = trailingState({
      text,
      attachments: ready.length + pastes.length,
      preparing,
      generating,
    });

    // An offline chat never sends a tool that needs the network.
    const activeTools = tools.filter(
      tool => activeToolIds.includes(tool.id) && !(offline && tool.online),
    );
    const expanded = activeTools.length > 0;

    const send = (modelId?: string) => {
      if (state !== 'send') {
        return;
      }
      haptics.tap();
      if (editing) {
        const target = editing;
        const edited = composeMessage({text: textRef.current, pastes});
        beforeEdit.current = null;
        chatUi.cancelEdit();
        textRef.current = '';
        setTextState('');
        setPastes([]);
        keepInField.current = false;
        onEdit(target, edited);
        return;
      }
      const message: SendInput = {
        text: composeMessage({text: textRef.current, quote, pastes}),
        attachments: ready.length
          ? ready.map(item => item.attachment)
          : undefined,
        toolIds: activeTools.length
          ? activeTools
              .filter(tool => tool.kind !== 'think')
              .map(tool => tool.id)
          : undefined,
        thinking:
          chatUi.effort === 'think' ||
          activeTools.some(tool => tool.kind === 'think'),
        modelId,
      };
      setText('');
      drafts.clear(conversationId);
      setPastes([]);
      keepInField.current = false;
      chatUi.setQuote(null);
      ports.files.clear(conversationId);
      ports.tools.clearActive(conversationId);
      onSend(message);
    };

    const onTrailing = () => {
      if (state === 'send') {
        send();
      } else if (state === 'stop') {
        haptics.press();
        onStop();
      } else if (state === 'voice') {
        haptics.tap();
        // The voice session itself is M11's; until then, say so.
        toast.show({message: t('toast.comingSoon')});
      }
    };

    const onLayout = (event: LayoutChangeEvent) => {
      const next = Math.round(event.nativeEvent.layout.height);
      height.value = next;
      setDockHeight(next);
    };

    const bottomPad = Math.max(rt.insets.bottom, theme.spacing.sm);
    const scale = Math.min(rt.fontScale, MAX_SCALE);
    const lineHeight = Math.round(LINE_HEIGHT * scale);
    const minInput = lineHeight + INPUT_PAD * 2;
    const maxInput = lineHeight * MAX_LINES + INPUT_PAD * 2;
    const otherModels = models.filter(
      model =>
        model.supported &&
        model.id !== activeModelId &&
        (model.state.status === 'ready' || model.state.status === 'loaded'),
    );

    const trailing = <TrailingButton state={state} onPress={onTrailing} />;

    return (
      <KeyboardStickyView
        style={styles.sticky}
        offset={{closed: 0, opened: rt.insets.bottom}}>
        {/* The conversation fades out behind the pill and never shows
            between it and the edge of the screen. */}
        {dockHeight > 0 ? (
          <EdgeFade
            edge="bottom"
            height={dockHeight}
            solid={bottomPad + theme.sizes.composerMinHeight / 2}
          />
        ) : null}
        <View
          onLayout={onLayout}
          pointerEvents="box-none"
          style={styles.dock(bottomPad)}>
          {text.length === 0 &&
          attachments.length + pastes.length === 0 &&
          !expanded
            ? above
            : null}
          <Animated.View
            testID="composer"
            layout={reduceMotion ? undefined : GROW}
            // Kept mounted while dictating, so what was typed stays.
            style={[styles.pill, dictating && styles.gone]}>
            <View style={StyleSheet.absoluteFill} pointerEvents="none">
              <GlassSurface radius={26} style={styles.glass} />
            </View>

            {editing ? (
              <Animated.View
                entering={reduceMotion ? undefined : FadeIn.duration(150)}
                exiting={reduceMotion ? undefined : FadeOut.duration(100)}
                style={styles.banner}>
                <Icon name="rename" size={16} color="textSecondary" />
                <Text
                  variant="footnote"
                  color="textSecondary"
                  style={styles.bannerText}>
                  {t('composer.editing')}
                </Text>
                <PressableScale
                  testID="composer-cancel-edit"
                  accessibilityRole="button"
                  accessibilityLabel={t('composer.cancelEdit')}
                  haptic
                  hitSlop={12}
                  onPress={() => chatUi.cancelEdit()}>
                  <Icon name="close" size={16} color="textSecondary" />
                </PressableScale>
              </Animated.View>
            ) : quote ? (
              <Animated.View
                entering={reduceMotion ? undefined : FadeIn.duration(150)}
                exiting={reduceMotion ? undefined : FadeOut.duration(100)}
                style={styles.banner}>
                <Icon name="quote" size={16} color="textSecondary" />
                <Text
                  testID="composer-quote"
                  variant="footnote"
                  color="textSecondary"
                  numberOfLines={2}
                  accessibilityLabel={`${t('composer.quote')}: ${quote}`}
                  style={styles.bannerText}>
                  {quote}
                </Text>
                <PressableScale
                  accessibilityRole="button"
                  accessibilityLabel={t('composer.removeQuote')}
                  haptic
                  hitSlop={12}
                  onPress={() => chatUi.setQuote(null)}>
                  <Icon name="close" size={16} color="textSecondary" />
                </PressableScale>
              </Animated.View>
            ) : null}

            {attachments.length + pastes.length > 0 ? (
              <ScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                keyboardShouldPersistTaps="handled"
                accessibilityLabel={t('composer.attachmentsLabel')}
                contentContainerStyle={styles.tray}
                style={styles.trayScroller}>
                {attachments.map(({attachment, state: ingest}) => (
                  <View
                    key={attachment.id}
                    testID="composer-attachment"
                    style={styles.attachment(attachment.kind === 'image')}>
                    {attachment.kind === 'image' &&
                    !isLoadableImage(attachment.uri) ? (
                      <View style={styles.thumbnailMissing}>
                        <Icon name="image" size={22} color="textTertiary" />
                      </View>
                    ) : attachment.kind === 'image' ? (
                      <Image
                        source={{uri: attachment.uri}}
                        accessibilityLabel={attachment.name}
                        style={styles.thumbnail}
                      />
                    ) : (
                      <>
                        <Icon name="document" size={18} color="textSecondary" />
                        <Text
                          variant="footnote"
                          numberOfLines={2}
                          style={styles.attachmentName}>
                          {attachment.name}
                        </Text>
                      </>
                    )}
                    {ingest.status === 'processing' ? (
                      <View style={styles.attachmentVeil} />
                    ) : null}
                    <PressableScale
                      accessibilityRole="button"
                      accessibilityLabel={t('common.remove', {
                        name: attachment.name,
                      })}
                      haptic
                      hitSlop={10}
                      onPress={() =>
                        ports.files.remove(conversationId, attachment.id)
                      }
                      style={styles.attachmentRemove}>
                      <Icon
                        name="close"
                        size={12}
                        color="onInverse"
                        strokeWidth={3}
                      />
                    </PressableScale>
                  </View>
                ))}
                {pastes.map(paste => (
                  <View
                    key={paste.id}
                    testID="composer-paste"
                    style={styles.attachment(false)}>
                    <ContextMenu
                      items={[
                        {id: 'show', title: t('composer.showInField')},
                        {
                          id: 'remove',
                          title: t('common.remove', {
                            name: t('composer.pasted'),
                          }),
                          destructive: true,
                        },
                      ]}
                      onSelect={id =>
                        id === 'show'
                          ? showInField(paste)
                          : setPastes(list =>
                              list.filter(item => item.id !== paste.id),
                            )
                      }>
                      <View
                        accessible
                        accessibilityRole="button"
                        accessibilityLabel={`${t('composer.pasted')}, ${t(
                          'composer.pastedChars',
                          {count: paste.text.length},
                        )}`}
                        style={styles.paste}>
                        <Icon name="paste" size={18} color="textSecondary" />
                        <View style={styles.pasteTexts}>
                          <Text variant="footnote" numberOfLines={1}>
                            {t('composer.pasted')}
                          </Text>
                          <Text
                            variant="caption"
                            color="textSecondary"
                            numberOfLines={1}>
                            {t('composer.pastedChars', {
                              count: paste.text.length.toLocaleString(),
                            })}
                          </Text>
                        </View>
                      </View>
                    </ContextMenu>
                  </View>
                ))}
              </ScrollView>
            ) : null}

            <TextInput
              ref={input}
              nativeID={COMPOSER_INPUT_ID}
              testID="composer-input"
              accessibilityLabel={t('composer.field')}
              // The field sizes itself to its text between the two heights.
              // Emptied from code it would keep its old height on iOS, so an
              // empty field gets the one-line height.
              style={[
                styles.input(expanded),
                {
                  fontSize: FONT_SIZE,
                  lineHeight,
                  minHeight: minInput,
                  maxHeight: maxInput,
                },
                text === '' && {height: minInput},
              ]}
              value={text}
              onChangeText={onChangeText}
              onFocus={() => setFocused(true)}
              onBlur={() => setFocused(false)}
              placeholder={t(
                offline
                  ? 'composer.offlinePlaceholder'
                  : temporary
                    ? 'composer.temporaryPlaceholder'
                    : 'composer.placeholder',
              )}
              placeholderTextColor={theme.colors.textTertiary}
              selectionColor={theme.colors.accent}
              cursorColor={theme.colors.accent}
              keyboardAppearance={theme.dark ? 'dark' : 'light'}
              maxFontSizeMultiplier={MAX_SCALE}
              multiline
              scrollEnabled
              textAlignVertical="center"
              underlineColorAndroid="transparent"
              submitBehavior={hardwareKeyboard ? 'submit' : 'newline'}
              onSubmitEditing={hardwareKeyboard ? () => send() : undefined}
            />

            <View style={styles.leading} pointerEvents="box-none">
              <IconButton
                testID="composer-add"
                icon="add"
                size={BUTTON}
                accessibilityLabel={t('composer.add')}
                onPress={() => {
                  sheet.current?.present().catch(() => {});
                }}
              />
            </View>

            {expanded ? (
              <ScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                keyboardShouldPersistTaps="handled"
                accessibilityLabel={t('composer.toolsLabel')}
                contentContainerStyle={styles.chips}
                style={styles.chipScroller}>
                {activeTools.map(tool => (
                  <Chip
                    key={tool.id}
                    testID={`composer-chip-${tool.id}`}
                    label={tool.displayName ?? t(toolChipName(tool.kind))}
                    icon={TOOL_ICONS[tool.kind]}
                    selected
                    onRemove={() =>
                      ports.tools.setActive(conversationId, tool.id, false)
                    }
                  />
                ))}
              </ScrollView>
            ) : null}

            <View style={styles.trailing} pointerEvents="box-none">
              {state !== 'stop' ? <DictationButton size={BUTTON} /> : null}
              {state === 'send' && otherModels.length > 0 ? (
                // Touch and hold: answer this one message with another model.
                <ContextMenu
                  trigger="longPress"
                  title={t('model.models')}
                  items={otherModels.map(model => ({
                    id: model.id,
                    title: model.displayName,
                  }))}
                  onSelect={send}>
                  {trailing}
                </ContextMenu>
              ) : (
                trailing
              )}
            </View>
          </Animated.View>
          {/* M11: the dictation bar takes the place of the field. */}
          {dictating ? <DictationLayer /> : null}
        </View>
        <AttachSheet
          ref={sheet}
          conversationId={conversationId}
          offline={offline}
        />
      </KeyboardStickyView>
    );
  }),
);

const styles = StyleSheet.create(theme => ({
  gone: {display: 'none'},
  sticky: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
  },
  dock: (bottom: number) => ({
    paddingHorizontal: theme.spacing.md,
    paddingTop: theme.spacing.sm,
    paddingBottom: bottom,
    gap: theme.spacing.sm,
  }),
  pill: {
    minHeight: theme.sizes.composerMinHeight,
    borderRadius: 26,
    borderCurve: 'continuous',
    justifyContent: 'flex-end',
  },
  glass: {
    flex: 1,
  },
  banner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    marginHorizontal: theme.spacing.lg,
    marginTop: theme.spacing.md,
    paddingBottom: theme.spacing.sm,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.colors.border,
  },
  bannerText: {
    flex: 1,
  },
  trayScroller: {
    flexGrow: 0,
    marginTop: PILL_PAD,
  },
  tray: {
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.md,
    paddingTop: theme.spacing.xs,
  },
  attachment: (image: boolean) => ({
    width: image ? 64 : 148,
    height: 64,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: image ? 0 : theme.spacing.md,
    borderRadius: theme.radii.md,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
  }),
  thumbnail: {
    width: 64,
    height: 64,
    borderRadius: theme.radii.md,
  },
  thumbnailMissing: {
    width: 64,
    height: 64,
    alignItems: 'center',
    justifyContent: 'center',
  },
  attachmentName: {
    flex: 1,
  },
  attachmentVeil: {
    ...StyleSheet.absoluteFillObject,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.scrim,
  },
  attachmentRemove: {
    position: 'absolute',
    top: -4,
    right: -4,
    width: 20,
    height: 20,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors.inverse,
  },
  paste: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
  },
  pasteTexts: {
    flex: 1,
  },
  input: (expanded: boolean) => ({
    marginStart: expanded ? theme.spacing.lg : PILL_PAD + BUTTON + 2,
    marginEnd: expanded ? theme.spacing.lg : PILL_PAD + BUTTON * 2 + 6,
    marginTop: PILL_PAD,
    marginBottom: expanded ? PILL_PAD + BUTTON + 4 : PILL_PAD,
    paddingTop: INPUT_PAD,
    paddingBottom: INPUT_PAD,
    paddingHorizontal: 0,
    color: theme.colors.textPrimary,
    letterSpacing: typography.body.letterSpacing,
    includeFontPadding: false,
  }),
  leading: {
    position: 'absolute',
    left: PILL_PAD,
    bottom: PILL_PAD,
  },
  chipScroller: {
    position: 'absolute',
    left: PILL_PAD + BUTTON + 4,
    right: PILL_PAD + BUTTON * 2 + 8,
    bottom: PILL_PAD,
    height: BUTTON,
  },
  chips: {
    alignItems: 'center',
    gap: theme.spacing.xs,
  },
  trailing: {
    position: 'absolute',
    right: PILL_PAD,
    bottom: PILL_PAD,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 2,
  },
}));
