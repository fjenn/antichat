/**
 * The hidden WebView behind `webViewScraper`. Mount once near the app root
 * (M8 UI half / M1 adapter); it draws nothing. Navigation is locked to the
 * engines' own hosts and their challenge providers, cookies stay inside the
 * WebView's own store, and nothing from the app is exposed to the page.
 */
import React, {useEffect, useRef, useState} from 'react';
import {StyleSheet, View} from 'react-native';
import {WebView} from 'react-native-webview';

import {BROWSER_USER_AGENT} from '../http';
import {
  isAllowedScrapeNavigation,
  webViewScraper,
  type WebViewScrapeController,
} from './scraper';
import {buildSerpParserJs} from './serpScript';

interface Props {
  controller?: WebViewScrapeController;
}

/** Result pages render late; the parser runs again after this delay. */
const REINJECT_MS = 1400;

export function ScrapeWebViewHost({controller = webViewScraper}: Props) {
  const ref = useRef<WebView>(null);
  const nonceRef = useRef(0);
  const [target, setTarget] = useState<{url: string; nonce: number} | null>(
    null,
  );

  useEffect(() => {
    controller.attachHost({
      navigate: (url, nonce) => {
        nonceRef.current = nonce;
        setTarget({url, nonce});
      },
      reset: () => setTarget(null),
    });
    return () => controller.detachHost();
  }, [controller]);

  if (!target) {
    return null;
  }
  return (
    <View style={styles.offscreen} pointerEvents="none">
      <WebView
        ref={ref}
        key={target.nonce}
        source={{uri: target.url}}
        userAgent={BROWSER_USER_AGENT}
        javaScriptEnabled
        domStorageEnabled
        incognito={false}
        thirdPartyCookiesEnabled={false}
        setSupportMultipleWindows={false}
        originWhitelist={['https://*']}
        onShouldStartLoadWithRequest={request =>
          isAllowedScrapeNavigation(request.url)
        }
        onLoadEnd={() => {
          const nonce = nonceRef.current;
          ref.current?.injectJavaScript(buildSerpParserJs(false, nonce));
          setTimeout(() => {
            if (nonceRef.current === nonce) {
              ref.current?.injectJavaScript(buildSerpParserJs(true, nonce));
            }
          }, REINJECT_MS);
        }}
        onMessage={event => controller.handleMessage(event.nativeEvent.data)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  offscreen: {
    position: 'absolute',
    top: -10000,
    left: 0,
    width: 390,
    height: 600,
    opacity: 0,
  },
});
