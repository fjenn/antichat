/**
 * Web image results without a key: Wikimedia Commons (and Wikipedia page
 * images through the same API). Enough for "what does X look like" strips
 * under an answer; keyed providers with image search (Brave, Serper) can be
 * added behind the same function.
 */
import type {ToolImage} from '../tools/types';
import {defaultHttpGet} from './http';
import {textOf} from './html';
import type {HttpGet} from './types';

export interface ImageSearchOptions {
  httpGet?: HttpGet;
  signal?: AbortSignal;
  limit?: number;
  /** Thumbnail width in pixels. */
  thumbWidth?: number;
}

const COMMONS = 'https://commons.wikimedia.org/w/api.php';
const ALLOWED = /\.(?:jpe?g|png|webp|gif)$/i;

export async function searchImages(
  query: string,
  options: ImageSearchOptions = {},
): Promise<ToolImage[]> {
  const httpGet = options.httpGet ?? defaultHttpGet;
  const limit = Math.min(options.limit ?? 6, 12);
  const url =
    `${COMMONS}?action=query&format=json&origin=*&generator=search&gsrnamespace=6` +
    `&gsrlimit=${limit * 2}&gsrsearch=${encodeURIComponent(`${query} filetype:bitmap`)}` +
    `&prop=imageinfo&iiprop=url|size|extmetadata&iiurlwidth=${options.thumbWidth ?? 480}`;
  let body: any;
  try {
    const response = await httpGet(url, {
      signal: options.signal,
      timeoutMs: 6000,
      headers: {Accept: 'application/json'},
    });
    if (response.status >= 400) {
      return [];
    }
    body = JSON.parse(response.text);
  } catch {
    return [];
  }
  const pages: any[] = Object.values(body?.query?.pages ?? {});
  pages.sort((a, b) => (a.index ?? 0) - (b.index ?? 0));
  const out: ToolImage[] = [];
  for (const page of pages) {
    const info = page?.imageinfo?.[0];
    if (!info?.url || !ALLOWED.test(info.url) || (info.width ?? 0) < 200) {
      continue;
    }
    out.push({
      url: info.url,
      thumbnailUrl: info.thumburl ?? info.url,
      title: textOf(
        String(page.title ?? '')
          .replace(/^File:/, '')
          .replace(/\.[a-z]+$/i, ''),
      ),
      sourceUrl: info.descriptionurl,
      width: info.width,
      height: info.height,
      license:
        textOf(info.extmetadata?.LicenseShortName?.value ?? '') || undefined,
    });
    if (out.length >= limit) {
      break;
    }
  }
  return out;
}

/** Does the question ask to see something? */
export const WANTS_IMAGES =
  /\b(?:what does .{1,60} look like|show me (?:a |an |some )?(?:picture|photo|image)s?|pictures? of|photos? of|images? of|wie sieht .{1,60} aus|bilder? von|fotos? de|im[aá]genes de|photos? de|images? de)\b/i;
