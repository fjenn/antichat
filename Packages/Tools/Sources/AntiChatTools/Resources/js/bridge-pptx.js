// M6.T11 (R-275, P-files-tools-05): a create_presentation spec + theme → PptxGenJS 4.0.1 deck → base64 .pptx. Runs in
// RenderHost; called with callAsyncJavaScript: `return await AntiChatRender.pptx(payload)`. Four layouts (title,
// bullets, image, title_bullets_image) as slide masters per theme; speaker notes; images from base64; 16:9.
(function () {
  "use strict";
  const W = 13.333, H = 7.5;  // LAYOUT_WIDE, inches

  function masters(pptx, t) {
    const footer = { rect: { x: 0, y: H - 0.12, w: W, h: 0.12, fill: { color: t.accent } } };
    const num = { x: W - 1.0, y: H - 0.55, w: 0.6, h: 0.3, color: t.muted, fontFace: t.bodyFont, fontSize: 10, align: "right" };
    pptx.defineSlideMaster({ title: "title", background: { color: t.background }, objects: [footer], slideNumber: num });
    for (const name of ["bullets", "image", "title_bullets_image"]) {
      pptx.defineSlideMaster({
        title: name, background: { color: t.background },
        objects: [footer, { rect: { x: 0.6, y: 1.35, w: 1.2, h: 0.06, fill: { color: t.accent } } }],
        slideNumber: num,
      });
    }
  }

  function title(slide, t, text, opts) {
    slide.addText(text || "", Object.assign({ x: 0.6, y: 0.4, w: W - 1.2, h: 0.9, fontFace: t.titleFont, fontSize: 32,
                                              bold: true, color: t.title, valign: "bottom", fit: "shrink" }, opts || {}));
  }

  function bullets(slide, t, items, box) {
    if (!items || !items.length) return;
    slide.addText(items.map((b) => ({ text: b, options: { bullet: { indent: 18 }, breakLine: true } })),
                  Object.assign({ fontFace: t.bodyFont, fontSize: 20, color: t.body, valign: "top", paraSpaceAfter: 8,
                                  fit: "shrink" }, box));
  }

  function image(slide, img, box) {
    if (!img) return;
    // Fit inside the box, keeping the aspect ratio.
    const r = Math.min(box.w / img.width, box.h / img.height);
    const w = img.width * r, h = img.height * r;
    slide.addImage({ data: img.mime + ";base64," + img.base64, x: box.x + (box.w - w) / 2, y: box.y + (box.h - h) / 2, w: w, h: h,
                     altText: img.alt || "" });
  }

  function build(spec) {
    const t = spec.theme;
    const pptx = new PptxGenJS();
    pptx.layout = "LAYOUT_WIDE";
    pptx.author = "AntiChat";
    pptx.company = "AntiChat";
    pptx.title = spec.title || "";
    pptx.subject = "";
    masters(pptx, t);
    for (const s of spec.slides) {
      const slide = pptx.addSlide({ masterName: s.layout });
      const img = s.image_ref ? (spec.images || {})[s.image_ref] : null;
      switch (s.layout) {
        case "title":
          slide.addText(s.title || "", { x: 0.8, y: 2.3, w: W - 1.6, h: 1.4, fontFace: t.titleFont, fontSize: 44, bold: true,
                                         color: t.title, align: "center", valign: "middle", fit: "shrink" });
          if (s.subtitle) {
            slide.addText(s.subtitle, { x: 0.8, y: 3.8, w: W - 1.6, h: 0.9, fontFace: t.bodyFont, fontSize: 22, color: t.muted,
                                        align: "center", valign: "top", fit: "shrink" });
          }
          break;
        case "bullets":
          title(slide, t, s.title);
          bullets(slide, t, s.bullets, { x: 0.6, y: 1.65, w: W - 1.2, h: H - 2.4 });
          break;
        case "image":
          title(slide, t, s.title);
          image(slide, img, { x: 0.6, y: 1.65, w: W - 1.2, h: H - 2.4 });
          break;
        case "title_bullets_image":
          title(slide, t, s.title);
          bullets(slide, t, s.bullets, { x: 0.6, y: 1.65, w: W / 2 - 0.8, h: H - 2.4 });
          image(slide, img, { x: W / 2 + 0.2, y: 1.65, w: W / 2 - 0.8, h: H - 2.4 });
          break;
      }
      if (s.notes) slide.addNotes(s.notes);
    }
    return pptx;
  }

  window.AntiChatRender = window.AntiChatRender || {};
  window.AntiChatRender.pptx = async function (payload) {
    const spec = typeof payload === "string" ? JSON.parse(payload) : payload;
    return await build(spec).write({ outputType: "base64" });
  };
})();
