/**
 * Auto-growing composer: one line at rest, grows with the text up to
 * MAX_LINES, then scrolls inside. Sits in a KeyboardStickyView so it rides
 * the keyboard frame by frame (including interactive dismissal).
 */
import React, {forwardRef, useImperativeHandle, useRef, useState} from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  TextInput,
  View,
  type LayoutChangeEvent,
} from 'react-native';
import {KeyboardStickyView} from 'react-native-keyboard-controller';
import Animated, {LinearTransition, Easing} from 'react-native-reanimated';
import {useSafeAreaInsets} from 'react-native-safe-area-context';

const LINE_HEIGHT = 22;
const MAX_LINES = 6;
const INPUT_PAD = 6;
const MIN_INPUT_HEIGHT = LINE_HEIGHT + INPUT_PAD * 2;
const MAX_INPUT_HEIGHT = LINE_HEIGHT * MAX_LINES + INPUT_PAD * 2;
export const COMPOSER_INPUT_ID = 'antichat-spike-composer';

const GROW = LinearTransition.duration(160).easing(Easing.out(Easing.ease));

export type ComposerHandle = {
  focus(): void;
  blur(): void;
  setText(text: string): void;
};

type Props = {
  generating: boolean;
  onSend: (text: string) => void;
  onStop: () => void;
  onLayout: (event: LayoutChangeEvent) => void;
};

export const Composer = forwardRef<ComposerHandle, Props>(function ComposerBar(
  {generating, onSend, onStop, onLayout},
  ref,
) {
  const insets = useSafeAreaInsets();
  const input = useRef<React.ComponentRef<typeof TextInput>>(null);
  const [text, setText] = useState('');
  useImperativeHandle(ref, () => ({
    focus: () => input.current?.focus(),
    blur: () => input.current?.blur(),
    setText,
  }));

  const canSend = text.trim().length > 0;
  const submit = () => {
    if (generating) {
      onStop();
    } else if (canSend) {
      onSend(text.trim());
      setText('');
    }
  };

  return (
    <KeyboardStickyView
      style={styles.sticky}
      offset={{closed: 0, opened: insets.bottom}}>
      <View
        onLayout={onLayout}
        style={[styles.bar, {paddingBottom: insets.bottom + 8}]}>
        <Animated.View layout={GROW} style={styles.pill}>
          <TextInput
            ref={input}
            nativeID={COMPOSER_INPUT_ID}
            testID="spike-composer-input"
            // The input sizes itself to its text between the min and max
            // height. Emptied from code (every send) it would keep its old
            // height on iOS, so an empty input gets the one-line height.
            style={[styles.input, text === '' && styles.inputEmpty]}
            value={text}
            onChangeText={setText}
            placeholder="Ask anything"
            placeholderTextColor="#8e8e93"
            multiline
            scrollEnabled
            textAlignVertical="center"
          />
          <Pressable
            testID="spike-composer-send"
            accessibilityRole="button"
            accessibilityLabel={generating ? 'Stop' : 'Send'}
            onPress={submit}
            style={[
              styles.button,
              !generating && !canSend && styles.buttonIdle,
            ]}>
            <Text style={styles.buttonText}>{generating ? '■' : '↑'}</Text>
          </Pressable>
        </Animated.View>
      </View>
    </KeyboardStickyView>
  );
});

const styles = StyleSheet.create({
  sticky: {position: 'absolute', left: 0, right: 0, bottom: 0},
  bar: {paddingHorizontal: 12, paddingTop: 8, backgroundColor: '#ffffffee'},
  pill: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    borderRadius: 24,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#d0d0d0',
    backgroundColor: '#fff',
    paddingLeft: 16,
    paddingRight: 6,
    paddingVertical: 6,
  },
  input: {
    flex: 1,
    fontSize: 16,
    lineHeight: LINE_HEIGHT,
    minHeight: MIN_INPUT_HEIGHT,
    maxHeight: MAX_INPUT_HEIGHT,
    paddingTop: INPUT_PAD,
    paddingBottom: INPUT_PAD,
    color: '#0d0d0d',
  },
  inputEmpty: {height: MIN_INPUT_HEIGHT},
  button: {
    width: 34,
    height: 34,
    borderRadius: 17,
    backgroundColor: '#0d0d0d',
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonIdle: {backgroundColor: '#c7c7cc'},
  buttonText: {color: '#fff', fontSize: 16, fontWeight: '700'},
});
