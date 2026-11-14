// M6.T09 step 6 (R-273, P-files-tools-05): the AntiChat document AST (DocumentAST.swift, JSON) → a `docx` 9.15.0
// Document → base64 .docx. Runs inside RenderHost (offscreen WKWebView, block-all content rules, no message
// handlers); called with callAsyncJavaScript: `return await AntiChatRender.docx(payload)`.
(function () {
  "use strict";
  const D = window.docx;
  const TWIP_MM = 56.6929;  // twips per mm
  const SIZES = { A4: { width: 11906, height: 16838 }, Letter: { width: 12240, height: 15840 } };
  const HEADING = [D.HeadingLevel.HEADING_1, D.HeadingLevel.HEADING_2, D.HeadingLevel.HEADING_3,
                   D.HeadingLevel.HEADING_4, D.HeadingLevel.HEADING_5, D.HeadingLevel.HEADING_6];
  const BULLETS = ["•", "◦", "▪", "•", "◦", "▪", "•", "◦", "▪"];

  function b64ToBytes(b64) {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function runs(list, opts) {
    opts = opts || {};
    const out = [];
    for (const r of list || []) {
      const parts = String(r.text).split("\n");
      parts.forEach((t, i) => {
        const o = { text: t, bold: !!(r.bold || opts.bold), italics: !!(r.italic || opts.italic),
                    strike: !!r.strike, rightToLeft: !!opts.rtl };
        if (i > 0) o.break = 1;
        if (r.code) { o.font = "Courier New"; o.shading = { type: D.ShadingType.CLEAR, color: "auto", fill: "F2F2F2" }; }
        if (opts.color) o.color = opts.color;
        if (r.link) {
          o.style = "Hyperlink";
          out.push(new D.ExternalHyperlink({ link: r.link, children: [new D.TextRun(o)] }));
        } else {
          out.push(new D.TextRun(o));
        }
      });
    }
    return out;
  }

  function align(a, rtl) {
    if (a === "center") return D.AlignmentType.CENTER;
    if (a === "right") return rtl ? D.AlignmentType.LEFT : D.AlignmentType.RIGHT;
    return undefined;
  }

  function build(spec) {
    let listInstance = 0;
    const pageSize = SIZES[spec.page_size] || SIZES.A4;
    const textWidth = pageSize.width - 2 * Math.round(20 * TWIP_MM);
    const children = [];

    function paragraph(node, extra) {
      extra = extra || {};
      const rtl = !!node.rtl;
      return new D.Paragraph(Object.assign({
        children: runs(node.runs, { rtl: rtl, italic: extra.italic, color: extra.color }),
        bidirectional: rtl || undefined,
        spacing: { after: 120 },
      }, extra.para || {}));
    }

    function block(node, ctx) {
      ctx = ctx || { level: -1, indent: 0 };
      switch (node.type) {
        case "heading":
          children.push(new D.Paragraph({
            heading: HEADING[Math.min(Math.max(node.level || 1, 1), 6) - 1],
            bidirectional: node.rtl || undefined,
            children: runs(node.runs, { rtl: !!node.rtl }),
          }));
          break;
        case "paragraph":
          children.push(paragraph(node, ctx.indent ? { para: { indent: { left: ctx.indent } } } : {}));
          break;
        case "list": {
          const level = ctx.level + 1;
          const ordered = !!node.ordered;
          const instance = ++listInstance;
          (node.items || []).forEach((item) => {
            let first = true;
            for (const b of item) {
              if (first && b.type === "paragraph") {
                children.push(paragraph(b, { para: { numbering: { reference: ordered ? "numbered" : "bullets",
                                                                   level: Math.min(level, 8), instance: instance } } }));
              } else {
                block(b, { level: level, indent: 720 * (level + 1) });
              }
              first = false;
            }
          });
          break;
        }
        case "table": {
          const border = { style: D.BorderStyle.SINGLE, size: 4, color: "BFBFBF" };
          const head = node.header || [];
          const rows = node.rows || [];
          const cols = Math.max(head.length, ...rows.map((r) => r.length), 1);
          const aligns = node.align || [];
          // Fixed twip widths (not only a percentage): Pages and Quick Look ignore pct table widths.
          const colW = Math.floor(textWidth / cols);
          const cell = (rs, c, isHead) => {
            const plain = (rs || []).map((r) => r.text).join("");
            const rtl = /^[^A-Za-z]*[֐-ࣿיִ-﷿ﹰ-﻿]/.test(plain);
            return new D.TableCell({
              width: { size: colW, type: D.WidthType.DXA },
              children: [new D.Paragraph({ children: runs(rs, { bold: isHead, rtl: rtl }), bidirectional: rtl || undefined,
                                           alignment: align(aligns[c], rtl) })],
              shading: isHead ? { type: D.ShadingType.CLEAR, color: "auto", fill: "EDEDED" } : undefined,
            });
          };
          const trs = [new D.TableRow({ tableHeader: true,
                                        children: Array.from({ length: cols }, (_, c) => cell(head[c], c, true)) })];
          for (const r of rows) trs.push(new D.TableRow({ children: Array.from({ length: cols }, (_, c) => cell(r[c], c, false)) }));
          children.push(new D.Table({
            width: { size: colW * cols, type: D.WidthType.DXA },
            columnWidths: Array.from({ length: cols }, () => colW),
            borders: { top: border, bottom: border, left: border, right: border, insideHorizontal: border, insideVertical: border },
            rows: trs,
          }));
          children.push(new D.Paragraph({ children: [] }));
          break;
        }
        case "code":
          String(node.text || "").split("\n").forEach((line) => {
            children.push(new D.Paragraph({
              children: [new D.TextRun({ text: line, font: "Courier New", size: 19 })],
              shading: { type: D.ShadingType.CLEAR, color: "auto", fill: "F2F2F2" },
              spacing: { after: 0 },
              indent: ctx.indent ? { left: ctx.indent } : undefined,
            }));
          });
          children.push(new D.Paragraph({ children: [] }));
          break;
        case "quote":
          for (const c of node.children || []) {
            if (c.type === "paragraph") {
              children.push(paragraph(c, { italic: true, color: "595959",
                                           para: { indent: { left: (ctx.indent || 0) + 567 } } }));
            } else {
              block(c, { level: ctx.level, indent: (ctx.indent || 0) + 567 });
            }
          }
          break;
        case "image": {
          const img = (spec.images || {})[node.ref];
          if (!img) {
            children.push(new D.Paragraph({ children: [new D.TextRun({ text: "[" + (node.alt || "image") + "]", italics: true })] }));
            break;
          }
          const maxW = 620;
          const w = Math.min(maxW, img.width || maxW);
          const h = img.width ? Math.round(w * img.height / img.width) : (img.height || w);
          children.push(new D.Paragraph({
            children: [new D.ImageRun({
              type: img.type, data: b64ToBytes(img.base64),
              transformation: { width: w, height: h },
              altText: { title: node.alt || "", description: node.alt || "", name: node.ref },
            })],
          }));
          if (node.alt) {
            children.push(new D.Paragraph({ children: [new D.TextRun({ text: node.alt, italics: true, color: "595959", size: 18 })] }));
          }
          break;
        }
        case "rule":
          children.push(new D.Paragraph({ children: [],
                                          border: { bottom: { style: D.BorderStyle.SINGLE, size: 6, color: "CCCCCC", space: 1 } } }));
          break;
      }
    }

    for (const n of spec.blocks || []) block(n);

    const levels = (ordered) => Array.from({ length: 9 }, (_, i) => ({
      level: i,
      format: ordered ? [D.LevelFormat.DECIMAL, D.LevelFormat.LOWER_LETTER, D.LevelFormat.LOWER_ROMAN][i % 3] : D.LevelFormat.BULLET,
      text: ordered ? "%" + (i + 1) + "." : BULLETS[i],
      alignment: D.AlignmentType.LEFT,
      style: { paragraph: { indent: { left: 720 * (i + 1), hanging: 360 } } },
    }));
    const size = pageSize;
    const margin = Math.round(20 * TWIP_MM);
    const font = spec.style === "report" ? "Times New Roman" : "Arial";
    const small = { size: 17, color: "6B6B6B" };

    return new D.Document({
      creator: "AntiChat",
      lastModifiedBy: "AntiChat",
      title: spec.title,
      description: "",
      styles: { default: { document: { run: { font: font, size: 22 } } } },
      numbering: { config: [{ reference: "bullets", levels: levels(false) }, { reference: "numbered", levels: levels(true) }] },
      sections: [{
        properties: { page: { size: size, margin: { top: margin, right: margin, bottom: margin, left: margin } } },
        headers: { default: new D.Header({ children: [new D.Paragraph({ alignment: D.AlignmentType.CENTER,
                                                                          children: [new D.TextRun(Object.assign({ text: spec.title }, small))] })] }) },
        footers: { default: new D.Footer({ children: [new D.Paragraph({ alignment: D.AlignmentType.CENTER, children: [
          new D.TextRun(Object.assign({ children: ["Page ", D.PageNumber.CURRENT, " of ", D.PageNumber.TOTAL_PAGES] }, small)),
        ] })] }) },
        children: children,
      }],
    });
  }

  window.AntiChatRender = window.AntiChatRender || {};
  window.AntiChatRender.docx = async function (payload) {
    const spec = typeof payload === "string" ? JSON.parse(payload) : payload;
    return await D.Packer.toBase64String(build(spec));
  };
})();
