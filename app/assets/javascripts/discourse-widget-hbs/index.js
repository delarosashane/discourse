"use strict";

const WidgetHbsCompiler = require("../../../../lib/javascripts/widget-hbs-compiler")
  .WidgetHbsCompiler;

module.exports = {
  name: require("./package").name,

  included() {
    this._super.included.apply(this, arguments);
    let addonOptions = this._getAddonOptions();
    addonOptions.babel = addonOptions.babel || {};
    addonOptions.babel.plugins = addonOptions.babel.plugins || [];
    let babelPlugins = addonOptions.babel.plugins;

    WidgetHbsCompiler.cacheKey = () => "discourse-widget-hbs";
    babelPlugins.push(WidgetHbsCompiler);
  },

  _getAddonOptions() {
    return (
      (this.parent && this.parent.options) ||
      (this.app && this.app.options) ||
      {}
    );
  },
};
