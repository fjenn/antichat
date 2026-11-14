// M6.T12 (R-274, P-files-tools-06): headless Vega-Lite → SVG + PNG@2x in RenderHost. The host has already injected the
// rows (spec.data.values) from the query result; nothing here loads a URL (a spec with data.url is rejected in Swift and
// the content rules block every load anyway). Renderer "none": no DOM, the view renders straight to SVG / canvas.
(function () {
  window.AntiChatRender = window.AntiChatRender || {};

  window.AntiChatRender.vega = async function (payload) {
    var p = JSON.parse(payload);
    var compiled;
    try {
      compiled = vegaLite.compile(p.spec);
    } catch (e) {
      throw new Error("spec: " + (e && e.message ? e.message : String(e)));
    }
    var warnings = [];
    var logger = vega.logger(vega.Warn);
    logger.warn = function () { warnings.push(Array.prototype.join.call(arguments, " ")); return logger; };
    var view = new vega.View(vega.parse(compiled.spec), { renderer: "none", logger: logger });
    try {
      await view.runAsync();
      var svg = await view.toSVG();
      var png = await view.toImageURL("png", p.scale || 2);
      return JSON.stringify({ svg: svg, png: png.slice(png.indexOf(",") + 1), warnings: warnings });
    } finally {
      view.finalize();
    }
  };
})();
