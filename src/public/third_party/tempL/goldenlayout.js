(function webpackUniversalModuleDefinition(root, factory) {
  console.log(root, factory, define, define.amd)
	if(typeof exports === 'object' && typeof module === 'object')
		module.exports = factory(require("jquery"));
	// else if(typeof define === 'function' && define.amd)
		// define(["jquery"], factory);
	else if(typeof exports === 'object')
		exports["GoldenLayout"] = factory(require("jquery"));
	else
		root["GoldenLayout"] = factory(root["$"]);
})(window, function(__WEBPACK_EXTERNAL_MODULE_jquery__) {
return /******/ (function(modules) { // webpackBootstrap
/******/ 	// The module cache
/******/ 	var installedModules = {};
/******/
/******/ 	// The require function
/******/ 	function __webpack_require__(moduleId) {
/******/
/******/ 		// Check if module is in cache
/******/ 		if(installedModules[moduleId]) {
/******/ 			return installedModules[moduleId].exports;
/******/ 		}
/******/ 		// Create a new module (and put it into the cache)
/******/ 		var module = installedModules[moduleId] = {
/******/ 			i: moduleId,
/******/ 			l: false,
/******/ 			exports: {}
/******/ 		};
/******/
/******/ 		// Execute the module function
/******/ 		modules[moduleId].call(module.exports, module, module.exports, __webpack_require__);
/******/
/******/ 		// Flag the module as loaded
/******/ 		module.l = true;
/******/
/******/ 		// Return the exports of the module
/******/ 		return module.exports;
/******/ 	}
/******/
/******/
/******/ 	// expose the modules object (__webpack_modules__)
/******/ 	__webpack_require__.m = modules;
/******/
/******/ 	// expose the module cache
/******/ 	__webpack_require__.c = installedModules;
/******/
/******/ 	// define getter function for harmony exports
/******/ 	__webpack_require__.d = function(exports, name, getter) {
/******/ 		if(!__webpack_require__.o(exports, name)) {
/******/ 			Object.defineProperty(exports, name, { enumerable: true, get: getter });
/******/ 		}
/******/ 	};
/******/
/******/ 	// define __esModule on exports
/******/ 	__webpack_require__.r = function(exports) {
/******/ 		if(typeof Symbol !== 'undefined' && Symbol.toStringTag) {
/******/ 			Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
/******/ 		}
/******/ 		Object.defineProperty(exports, '__esModule', { value: true });
/******/ 	};
/******/
/******/ 	// create a fake namespace object
/******/ 	// mode & 1: value is a module id, require it
/******/ 	// mode & 2: merge all properties of value into the ns
/******/ 	// mode & 4: return value when already ns object
/******/ 	// mode & 8|1: behave like require
/******/ 	__webpack_require__.t = function(value, mode) {
/******/ 		if(mode & 1) value = __webpack_require__(value);
/******/ 		if(mode & 8) return value;
/******/ 		if((mode & 4) && typeof value === 'object' && value && value.__esModule) return value;
/******/ 		var ns = Object.create(null);
/******/ 		__webpack_require__.r(ns);
/******/ 		Object.defineProperty(ns, 'default', { enumerable: true, value: value });
/******/ 		if(mode & 2 && typeof value != 'string') for(var key in value) __webpack_require__.d(ns, key, function(key) { return value[key]; }.bind(null, key));
/******/ 		return ns;
/******/ 	};
/******/
/******/ 	// getDefaultExport function for compatibility with non-harmony modules
/******/ 	__webpack_require__.n = function(module) {
/******/ 		var getter = module && module.__esModule ?
/******/ 			function getDefault() { return module['default']; } :
/******/ 			function getModuleExports() { return module; };
/******/ 		__webpack_require__.d(getter, 'a', getter);
/******/ 		return getter;
/******/ 	};
/******/
/******/ 	// Object.prototype.hasOwnProperty.call
/******/ 	__webpack_require__.o = function(object, property) { return Object.prototype.hasOwnProperty.call(object, property); };
/******/
/******/ 	// __webpack_public_path__
/******/ 	__webpack_require__.p = "";
/******/
/******/
/******/ 	// Load entry module and return exports
/******/ 	return __webpack_require__(__webpack_require__.s = "./src/index.js");
/******/ })
/************************************************************************/
/******/ ({

/***/ "./src/index.js":
/*!**********************!*\
  !*** ./src/index.js ***!
  \**********************/
/*! exports provided: default, ItemContainer, BrowserPopout, Header, HeaderButton, Tab, Component, Root, RowOrColumn, Stack, BubblingEvent, ConfigMinifier, DragListener, EventEmitter, EventHub, ReactComponentHandler */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony import */ var _js_es6_LayoutManager__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ./js_es6/LayoutManager */ "./src/js_es6/LayoutManager.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "default", function() { return _js_es6_LayoutManager__WEBPACK_IMPORTED_MODULE_0__["default"]; });

/* harmony import */ var _js_es6_container_ItemContainer__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ./js_es6/container/ItemContainer */ "./src/js_es6/container/ItemContainer.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "ItemContainer", function() { return _js_es6_container_ItemContainer__WEBPACK_IMPORTED_MODULE_1__["default"]; });

/* harmony import */ var _js_es6_controls_BrowserPopout__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ./js_es6/controls/BrowserPopout */ "./src/js_es6/controls/BrowserPopout.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "BrowserPopout", function() { return _js_es6_controls_BrowserPopout__WEBPACK_IMPORTED_MODULE_2__["default"]; });

/* harmony import */ var _js_es6_controls_Header__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ./js_es6/controls/Header */ "./src/js_es6/controls/Header.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "Header", function() { return _js_es6_controls_Header__WEBPACK_IMPORTED_MODULE_3__["default"]; });

/* harmony import */ var _js_es6_controls_HeaderButton__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! ./js_es6/controls/HeaderButton */ "./src/js_es6/controls/HeaderButton.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "HeaderButton", function() { return _js_es6_controls_HeaderButton__WEBPACK_IMPORTED_MODULE_4__["default"]; });

/* harmony import */ var _js_es6_controls_Tab__WEBPACK_IMPORTED_MODULE_5__ = __webpack_require__(/*! ./js_es6/controls/Tab */ "./src/js_es6/controls/Tab.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "Tab", function() { return _js_es6_controls_Tab__WEBPACK_IMPORTED_MODULE_5__["default"]; });

/* harmony import */ var _js_es6_items_Component__WEBPACK_IMPORTED_MODULE_6__ = __webpack_require__(/*! ./js_es6/items/Component */ "./src/js_es6/items/Component.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "Component", function() { return _js_es6_items_Component__WEBPACK_IMPORTED_MODULE_6__["default"]; });

/* harmony import */ var _js_es6_items_Root__WEBPACK_IMPORTED_MODULE_7__ = __webpack_require__(/*! ./js_es6/items/Root */ "./src/js_es6/items/Root.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "Root", function() { return _js_es6_items_Root__WEBPACK_IMPORTED_MODULE_7__["default"]; });

/* harmony import */ var _js_es6_items_RowOrColumn__WEBPACK_IMPORTED_MODULE_8__ = __webpack_require__(/*! ./js_es6/items/RowOrColumn */ "./src/js_es6/items/RowOrColumn.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "RowOrColumn", function() { return _js_es6_items_RowOrColumn__WEBPACK_IMPORTED_MODULE_8__["default"]; });

/* harmony import */ var _js_es6_items_Stack__WEBPACK_IMPORTED_MODULE_9__ = __webpack_require__(/*! ./js_es6/items/Stack */ "./src/js_es6/items/Stack.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "Stack", function() { return _js_es6_items_Stack__WEBPACK_IMPORTED_MODULE_9__["default"]; });

/* harmony import */ var _js_es6_utils_BubblingEvent__WEBPACK_IMPORTED_MODULE_10__ = __webpack_require__(/*! ./js_es6/utils/BubblingEvent */ "./src/js_es6/utils/BubblingEvent.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "BubblingEvent", function() { return _js_es6_utils_BubblingEvent__WEBPACK_IMPORTED_MODULE_10__["default"]; });

/* harmony import */ var _js_es6_utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_11__ = __webpack_require__(/*! ./js_es6/utils/ConfigMinifier */ "./src/js_es6/utils/ConfigMinifier.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "ConfigMinifier", function() { return _js_es6_utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_11__["default"]; });

/* harmony import */ var _js_es6_utils_DragListener__WEBPACK_IMPORTED_MODULE_12__ = __webpack_require__(/*! ./js_es6/utils/DragListener */ "./src/js_es6/utils/DragListener.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "DragListener", function() { return _js_es6_utils_DragListener__WEBPACK_IMPORTED_MODULE_12__["default"]; });

/* harmony import */ var _js_es6_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_13__ = __webpack_require__(/*! ./js_es6/utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "EventEmitter", function() { return _js_es6_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_13__["default"]; });

/* harmony import */ var _js_es6_utils_EventHub__WEBPACK_IMPORTED_MODULE_14__ = __webpack_require__(/*! ./js_es6/utils/EventHub */ "./src/js_es6/utils/EventHub.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "EventHub", function() { return _js_es6_utils_EventHub__WEBPACK_IMPORTED_MODULE_14__["default"]; });

/* harmony import */ var _js_es6_utils_ReactComponentHandler__WEBPACK_IMPORTED_MODULE_15__ = __webpack_require__(/*! ./js_es6/utils/ReactComponentHandler */ "./src/js_es6/utils/ReactComponentHandler.js");
/* harmony reexport (safe) */ __webpack_require__.d(__webpack_exports__, "ReactComponentHandler", function() { return _js_es6_utils_ReactComponentHandler__WEBPACK_IMPORTED_MODULE_15__["default"]; });

// helper file for webpack build system
// whatever is imported/exported here will be included in the build
//import 'less/test.less'
//import './less/goldenlayout-base.less'
//import './less/goldenlayout-dark-theme.less'
//
// Layout
 //
// container

 //
// controls




 //
// items




 //
// utils








/***/ }),

/***/ "./src/js_es6/LayoutManager.js":
/*!*************************************!*\
  !*** ./src/js_es6/LayoutManager.js ***!
  \*************************************/
/*! exports provided: REACT_COMPONENT_ID, default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "REACT_COMPONENT_ID", function() { return REACT_COMPONENT_ID; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return LayoutManager; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ./utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ./utils/ConfigMinifier */ "./src/js_es6/utils/ConfigMinifier.js");
/* harmony import */ var _utils_EventHub__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ./utils/EventHub */ "./src/js_es6/utils/EventHub.js");
/* harmony import */ var _items_Root__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ./items/Root */ "./src/js_es6/items/Root.js");
/* harmony import */ var _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! ./items/RowOrColumn */ "./src/js_es6/items/RowOrColumn.js");
/* harmony import */ var _items_Stack__WEBPACK_IMPORTED_MODULE_5__ = __webpack_require__(/*! ./items/Stack */ "./src/js_es6/items/Stack.js");
/* harmony import */ var _items_Component__WEBPACK_IMPORTED_MODULE_6__ = __webpack_require__(/*! ./items/Component */ "./src/js_es6/items/Component.js");
/* harmony import */ var _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_7__ = __webpack_require__(/*! ./items/AbstractContentItem */ "./src/js_es6/items/AbstractContentItem.js");
/* harmony import */ var _controls_BrowserPopout__WEBPACK_IMPORTED_MODULE_8__ = __webpack_require__(/*! ./controls/BrowserPopout */ "./src/js_es6/controls/BrowserPopout.js");
/* harmony import */ var _controls_DragSource__WEBPACK_IMPORTED_MODULE_9__ = __webpack_require__(/*! ./controls/DragSource */ "./src/js_es6/controls/DragSource.js");
/* harmony import */ var _controls_DropTargetIndicator__WEBPACK_IMPORTED_MODULE_10__ = __webpack_require__(/*! ./controls/DropTargetIndicator */ "./src/js_es6/controls/DropTargetIndicator.js");
/* harmony import */ var _controls_TransitionIndicator__WEBPACK_IMPORTED_MODULE_11__ = __webpack_require__(/*! ./controls/TransitionIndicator */ "./src/js_es6/controls/TransitionIndicator.js");
/* harmony import */ var _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_12__ = __webpack_require__(/*! ./errors/ConfigurationError */ "./src/js_es6/errors/ConfigurationError.js");
/* harmony import */ var _config_defaultConfig__WEBPACK_IMPORTED_MODULE_13__ = __webpack_require__(/*! ./config/defaultConfig */ "./src/js_es6/config/defaultConfig.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_14__ = __webpack_require__(/*! ./utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_15__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_15___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_15__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }

















var REACT_COMPONENT_ID = 'lm-react-component';
/**
 * The main class that will be exposed as GoldenLayout.
 *
 * @public
 * @constructor
 * @param {GoldenLayout config} config
 * @param {[DOM element container]} container Can be a jQuery selector string or a Dom element. Defaults to body
 *
 * @returns {VOID}
 */

var LayoutManager = /*#__PURE__*/function (_EventEmitter) {
  _inherits(LayoutManager, _EventEmitter);

  var _super = _createSuper(LayoutManager);

  function LayoutManager(config, container) {
    var _this;

    _classCallCheck(this, LayoutManager);

    _this = _super.call(this);
    _this.isInitialised = false;
    _this._isFullPage = false;
    _this._resizeTimeoutId = null;
    _this._components = {};
    _this._itemAreas = [];
    _this._resizeFunction = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(_this._onResize, _assertThisInitialized(_this));
    _this._unloadFunction = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(_this._onUnload, _assertThisInitialized(_this));
    _this._maximisedItem = null;
    _this._maximisePlaceholder = jquery__WEBPACK_IMPORTED_MODULE_15___default()('<div class="lm_maximise_place"></div>');
    _this._creationTimeoutPassed = false;
    _this._subWindowsCreated = false;
    _this._dragSources = [];
    _this._updatingColumnsResponsive = false;
    _this._firstLoad = true;
    _this.width = null;
    _this.height = null;
    _this.root = null;
    _this.openPopouts = [];
    _this.selectedItem = null;
    _this.isSubWindow = false;
    _this.eventHub = new _utils_EventHub__WEBPACK_IMPORTED_MODULE_2__["default"](_assertThisInitialized(_this));
    _this.config = _this._createConfig(config);
    _this.container = container;
    _this.dropTargetIndicator = null;
    _this.transitionIndicator = null;
    _this.tabDropPlaceholder = jquery__WEBPACK_IMPORTED_MODULE_15___default()('<div class="lm_drop_tab_placeholder"></div>');

    if (_this.isSubWindow === true) {
      jquery__WEBPACK_IMPORTED_MODULE_15___default()('body').css('visibility', 'hidden');
    }

    _this._typeToItem = {
      'column': Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(_items_RowOrColumn__WEBPACK_IMPORTED_MODULE_4__["default"], _assertThisInitialized(_this), [true]),
      'row': Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(_items_RowOrColumn__WEBPACK_IMPORTED_MODULE_4__["default"], _assertThisInitialized(_this), [false]),
      'stack': _items_Stack__WEBPACK_IMPORTED_MODULE_5__["default"],
      'component': _items_Component__WEBPACK_IMPORTED_MODULE_6__["default"]
    };
    return _this;
  }
  /**
   * Takes a GoldenLayout configuration object and
   * replaces its keys and values recursively with
   * one letter codes
   *
   * @static
   * @public
   * @param   {Object} config A GoldenLayout config object
   *
   * @returns {Object} minified config
   */


  _createClass(LayoutManager, [{
    key: "minifyConfig",
    value: function minifyConfig(config) {
      return new _utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_1__["default"]().minifyConfig(config);
    }
    /**
     * Takes a configuration Object that was previously minified
     * using minifyConfig and returns its original version
     *
     * @static
     * @public
     * @param   {Object} minifiedConfig
     *
     * @returns {Object} the original configuration
     */

  }, {
    key: "unminifyConfig",
    value: function unminifyConfig(config) {
      return new _utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_1__["default"]().unminifyConfig(config);
    }
    /**
     * Register a component with the layout manager. If a configuration node
     * of type component is reached it will look up componentName and create the
     * associated component
     *
     *  {
     *    type: "component",
     *    componentName: "EquityNewsFeed",
     *    componentState: { "feedTopic": "us-bluechips" }
     *  }
     *
     * @public
     * @param   {String} name
     * @param   {Function} constructor
     *
     * @returns {void}
     */

  }, {
    key: "registerComponent",
    value: function registerComponent(name, constructor) {
      if (typeof constructor !== 'function') {
        throw new Error('Please register a constructor function');
      }

      if (this._components[name] !== undefined) {
        throw new Error('Component ' + name + ' is already registered');
      }

      this._components[name] = constructor;
    }
    /**
     * Register a component function with the layout manager. This function should
     * return a constructor for a component based on a config.  If undefined is returned, 
     * and no component has been registered under that name using registerComponent, an 
     * error will be thrown.
     *
     * @public
     * @param   {Function} callback
     *
     * @returns {void}
     */

  }, {
    key: "registerComponentFunction",
    value: function registerComponentFunction(callback) {
      if (typeof callback !== 'function') {
        throw new Error('Please register a callback function');
      }

      if (this._componentFunction !== undefined) {
        console.warn('Multiple component functions are being registered.  Only the final registered function will be used.');
      }

      this._componentFunction = callback;
    }
    /**
     * Creates a layout configuration object based on the the current state
     *
     * @public
     * @returns {Object} GoldenLayout configuration
     */

  }, {
    key: "toConfig",
    value: function toConfig(root) {
      var config, _next, i;

      if (this.isInitialised === false) {
        throw new Error('Can\'t create config, layout not yet initialised');
      }

      if (root && !(root instanceof _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_7__["default"])) {
        throw new Error('Root must be a ContentItem');
      }
      /*
       * settings & labels
       */


      config = {
        settings: Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["copy"])({}, this.config.settings),
        dimensions: Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["copy"])({}, this.config.dimensions),
        labels: Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["copy"])({}, this.config.labels)
      };
      /*
       * Content
       */

      config.content = [];

      _next = function next(configNode, item) {
        var key, i;

        for (key in item.config) {
          if (key !== 'content') {
            configNode[key] = item.config[key];
          }
        }

        if (item.contentItems.length) {
          configNode.content = [];

          for (i = 0; i < item.contentItems.length; i++) {
            configNode.content[i] = {};

            _next(configNode.content[i], item.contentItems[i]);
          }
        }
      };

      if (root) {
        _next(config, {
          contentItems: [root]
        });
      } else {
        _next(config, this.root);
      }
      /*
       * Retrieve config for subwindows
       */


      this._$reconcilePopoutWindows();

      config.openPopouts = [];

      for (i = 0; i < this.openPopouts.length; i++) {
        config.openPopouts.push(this.openPopouts[i].toConfig());
      }
      /*
       * Add maximised item
       */


      config.maximisedItemId = this._maximisedItem ? '__glMaximised' : null;
      return config;
    }
    /**
     * Returns a previously registered component.  Attempts to utilize registered 
     * component by name first, then falls back to the component function.  If either
     * lack a response for what the component should be, it throws an error.
     *
     * @public
     * @param {Object} config - The item config
     * 
     * @returns {Function}
     */

  }, {
    key: "getComponent",
    value: function getComponent(config) {
      var name = this.getComponentNameFromConfig(config);
      var componentToUse = this._components[name];

      if (this._componentFunction !== undefined) {
        componentToUse = componentToUse || this._componentFunction({
          config: config
        });
      }

      if (componentToUse === undefined) {
        throw new _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_12__["default"]('Unknown component "' + name + '"');
      }

      return componentToUse;
    }
    /**
     * Creates the actual layout. Must be called after all initial components
     * are registered. Recurses through the configuration and sets up
     * the item tree.
     *
     * If called before the document is ready it adds itself as a listener
     * to the document.ready event
     *
     * @public
     *
     * @returns {void}
     */

  }, {
    key: "init",
    value: function init() {
      /**
       * Create the popout windows straight away. If popouts are blocked
       * an error is thrown on the same 'thread' rather than a timeout and can
       * be caught. This also prevents any further initilisation from taking place.
       */
      if (this._subWindowsCreated === false) {
        this._createSubWindows();

        this._subWindowsCreated = true;
      }
      /**
       * If the document isn't ready yet, wait for it.
       */


      if (document.readyState === 'loading' || document.body === null) {
        jquery__WEBPACK_IMPORTED_MODULE_15___default()(document).ready(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(this.init, this));
        return;
      }
      /**
       * If this is a subwindow, wait a few milliseconds for the original
       * page's js calls to be executed, then replace the bodies content
       * with GoldenLayout
       */


      if (this.isSubWindow === true && this._creationTimeoutPassed === false) {
        setTimeout(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(this.init, this), 7);
        this._creationTimeoutPassed = true;
        return;
      }

      if (this.isSubWindow === true) {
        this._adjustToWindowMode();
      }

      this._setContainer();

      this.dropTargetIndicator = new _controls_DropTargetIndicator__WEBPACK_IMPORTED_MODULE_10__["default"](this.container);
      this.transitionIndicator = new _controls_TransitionIndicator__WEBPACK_IMPORTED_MODULE_11__["default"]();
      this.updateSize();

      this._create(this.config);

      this._bindEvents();

      this.isInitialised = true;

      this._adjustColumnsResponsive();

      this.emit('initialised');
    }
    /**
     * Updates the layout managers size
     *
     * @public
     * @param   {[int]} width  height in pixels
     * @param   {[int]} height width in pixels
     *
     * @returns {void}
     */

  }, {
    key: "updateSize",
    value: function updateSize(width, height) {
      if (arguments.length === 2) {
        this.width = width;
        this.height = height;
      } else {
        this.width = this.container.width();
        this.height = this.container.height();
      }

      if (this.isInitialised === true) {
        this.root.callDownwards('setSize', [this.width, this.height]);

        if (this._maximisedItem) {
          this._maximisedItem.element.width(this.container.width());

          this._maximisedItem.element.height(this.container.height());

          this._maximisedItem.callDownwards('setSize');
        }

        this._adjustColumnsResponsive();
      }
    }
    /**
     * Destroys the LayoutManager instance itself as well as every ContentItem
     * within it. After this is called nothing should be left of the LayoutManager.
     *
     * @public
     * @returns {void}
     */

  }, {
    key: "destroy",
    value: function destroy() {
      if (this.isInitialised === false) {
        return;
      }

      this._onUnload();

      jquery__WEBPACK_IMPORTED_MODULE_15___default()(window).off('resize', this._resizeFunction);
      jquery__WEBPACK_IMPORTED_MODULE_15___default()(window).off('unload beforeunload', this._unloadFunction);
      this.root.callDownwards('_$destroy', [], true);
      this.root.contentItems = [];
      this.tabDropPlaceholder.remove();
      this.dropTargetIndicator.destroy();
      this.transitionIndicator.destroy();
      this.eventHub.destroy();

      this._dragSources.forEach(function (dragSource) {
        dragSource._dragListener.destroy();

        dragSource._element = null;
        dragSource._itemConfig = null;
        dragSource._dragListener = null;
      });

      this._dragSources = [];
    }
    /**
     * Returns whether or not the config corresponds to a react component or a normal component.
     * 
     * At some point the type is mutated, but the componentName should then correspond to the
     * REACT_COMPONENT_ID.
     * 
     * @param {Object} config ItemConfig
     * 
     * @returns {Boolean}
     */

  }, {
    key: "isReactConfig",
    value: function isReactConfig(config) {
      return config.type === 'react-component' || config.componentName === REACT_COMPONENT_ID;
    }
    /**
     * Returns the name of the component for the config, taking into account whether it's a react component or not.
     * 
     * @param {Object} config ItemConfig
     * 
     * @returns {String}
     */

  }, {
    key: "getComponentNameFromConfig",
    value: function getComponentNameFromConfig(config) {
      if (this.isReactConfig(config)) {
        return config.component;
      }

      return config.componentName;
    }
    /**
     * Recursively creates new item tree structures based on a provided
     * ItemConfiguration object
     *
     * @public
     * @param   {Object} config ItemConfig
     * @param   {[ContentItem]} parent The item the newly created item should be a child of
     *
     * @returns {ContentItem}
     */

  }, {
    key: "createContentItem",
    value: function createContentItem(config, parent) {
      var typeErrorMsg, contentItem;

      if (typeof config.type !== 'string') {
        throw new _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_12__["default"]('Missing parameter \'type\'', config);
      }

      if (this.isReactConfig(config)) {
        config.type = 'component';
        config.componentName = REACT_COMPONENT_ID;
      }

      if (!this._typeToItem[config.type]) {
        typeErrorMsg = 'Unknown type \'' + config.type + '\'. ' + 'Valid types are ' + Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["objectKeys"])(this._typeToItem).join(',');
        throw new _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_12__["default"](typeErrorMsg);
      }
      /**
       * We add an additional stack around every component that's not within a stack anyways.
       */


      if ( // If this is a component
      config.type === 'component' && // and it's not already within a stack
      !(parent instanceof _items_Stack__WEBPACK_IMPORTED_MODULE_5__["default"]) && // and we have a parent
      !!parent && // and it's not the topmost item in a new window
      !(this.isSubWindow === true && parent instanceof _items_Root__WEBPACK_IMPORTED_MODULE_3__["default"])) {
        config = {
          type: 'stack',
          width: config.width,
          height: config.height,
          content: [config]
        };
      }

      contentItem = new this._typeToItem[config.type](this, config, parent);
      return contentItem;
    }
    /**
     * Creates a popout window with the specified content and dimensions
     *
     * @param   {Object|lm.itemsAbstractContentItem} configOrContentItem
     * @param   {[Object]} dimensions A map with width, height, left and top
     * @param    {[String]} parentId the id of the element this item will be appended to
     *                             when popIn is called
     * @param    {[Number]} indexInParent The position of this item within its parent element
     
     * @returns {BrowserPopout}
     */

  }, {
    key: "createPopout",
    value: function createPopout(configOrContentItem, dimensions, parentId, indexInParent) {
      var config = configOrContentItem,
          isItem = configOrContentItem instanceof _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_7__["default"],
          self = this,
          windowLeft,
          windowTop,
          offset,
          parent,
          child,
          browserPopout;
      parentId = parentId || null;

      if (isItem) {
        config = this.toConfig(configOrContentItem).content;
        parentId = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["getUniqueId"])();
        /**
         * If the item is the only component within a stack or for some
         * other reason the only child of its parent the parent will be destroyed
         * when the child is removed.
         *
         * In order to support this we move up the tree until we find something
         * that will remain after the item is being popped out
         */

        parent = configOrContentItem.parent;
        child = configOrContentItem;

        while (parent.contentItems.length === 1 && !parent.isRoot) {
          parent = parent.parent;
          child = child.parent;
        }

        parent.addId(parentId);

        if (isNaN(indexInParent)) {
          indexInParent = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["indexOf"])(child, parent.contentItems);
        }
      } else {
        if (!(config instanceof Array)) {
          config = [config];
        }
      }

      if (!dimensions && isItem) {
        windowLeft = window.screenX || window.screenLeft;
        windowTop = window.screenY || window.screenTop;
        offset = configOrContentItem.element.offset();
        dimensions = {
          left: windowLeft + offset.left,
          top: windowTop + offset.top,
          width: configOrContentItem.element.width(),
          height: configOrContentItem.element.height()
        };
      }

      if (!dimensions && !isItem) {
        dimensions = {
          left: window.screenX || window.screenLeft + 20,
          top: window.screenY || window.screenTop + 20,
          width: 500,
          height: 309
        };
      }

      if (isItem) {
        configOrContentItem.remove();
      }

      browserPopout = new _controls_BrowserPopout__WEBPACK_IMPORTED_MODULE_8__["default"](config, dimensions, parentId, indexInParent, this);
      browserPopout.on('initialised', function () {
        self.emit('windowOpened', browserPopout);
      });
      browserPopout.on('closed', function () {
        self._$reconcilePopoutWindows();
      });
      this.openPopouts.push(browserPopout);
      return browserPopout;
    }
    /**
     * Attaches DragListener to any given DOM element
     * and turns it into a way of creating new ContentItems
     * by 'dragging' the DOM element into the layout
     *
     * @param   {jQuery DOM element} element
     * @param   {Object|Function} itemConfig for the new item to be created, or a function which will provide it
     *
     * @returns {DragSource}  an opaque object that identifies the DOM element
    *          and the attached itemConfig. This can be used in
    *          removeDragSource() later to get rid of the drag listeners.
     */

  }, {
    key: "createDragSource",
    value: function createDragSource(element, itemConfig) {
      this.config.settings.constrainDragToContainer = false;
      var dragSource = new _controls_DragSource__WEBPACK_IMPORTED_MODULE_9__["default"](jquery__WEBPACK_IMPORTED_MODULE_15___default()(element), itemConfig, this);

      this._dragSources.push(dragSource);

      return dragSource;
    }
    /**
    * Removes a DragListener added by createDragSource() so the corresponding
    * DOM element is not a drag source any more.
    *
    * @param   {jQuery DOM element} element
    *
    * @returns {void}
    */

  }, {
    key: "removeDragSource",
    value: function removeDragSource(dragSource) {
      dragSource.destroy();
      lm.utils.removeFromArray(dragSource, this._dragSources);
    }
    /**
     * Programmatically selects an item. This deselects
     * the currently selected item, selects the specified item
     * and emits a selectionChanged event
     *
     * @param   {AbstractContentItem} item#
     * @param   {[Boolean]} _$silent Wheather to notify the item of its selection
     * @event    selectionChanged
     *
     * @returns {VOID}
     */

  }, {
    key: "selectItem",
    value: function selectItem(item, _$silent) {
      if (this.config.settings.selectionEnabled !== true) {
        throw new Error('Please set selectionEnabled to true to use this feature');
      }

      if (item === this.selectedItem) {
        return;
      }

      if (this.selectedItem !== null) {
        this.selectedItem.deselect();
      }

      if (item && _$silent !== true) {
        item.select();
      }

      this.selectedItem = item;
      this.emit('selectionChanged', item);
    }
    /*************************
     * PACKAGE PRIVATE
     *************************/

  }, {
    key: "_$maximiseItem",
    value: function _$maximiseItem(contentItem) {
      if (this._maximisedItem !== null) {
        this._$minimiseItem(this._maximisedItem);
      }

      this._maximisedItem = contentItem;
      contentItem.on('beforeItemDestroyed', this._$cleanupBeforeMaximisedItemDestroyed, this);

      this._maximisedItem.addId('__glMaximised');

      contentItem.element.addClass('lm_maximised');
      contentItem.element.after(this._maximisePlaceholder);
      this.root.element.prepend(contentItem.element);
      contentItem.element.width(this.container.width());
      contentItem.element.height(this.container.height());
      contentItem.callDownwards('setSize');

      this._maximisedItem.emit('maximised');

      this.emit('stateChanged');
    }
  }, {
    key: "_$minimiseItem",
    value: function _$minimiseItem(contentItem) {
      contentItem.element.removeClass('lm_maximised');
      contentItem.removeId('__glMaximised');

      this._maximisePlaceholder.after(contentItem.element);

      this._maximisePlaceholder.remove();

      contentItem.parent.callDownwards('setSize');
      this._maximisedItem = null;
      contentItem.off('beforeItemDestroyed', this._$cleanupBeforeMaximisedItemDestroyed, this);
      contentItem.emit('minimised');
      this.emit('stateChanged');
    }
  }, {
    key: "_$cleanupBeforeMaximisedItemDestroyed",
    value: function _$cleanupBeforeMaximisedItemDestroyed() {
      if (this._maximisedItem === event.origin) {
        this._maximisedItem.off('beforeItemDestroyed', this._$cleanupBeforeMaximisedItemDestroyed, this);

        this._maximisedItem = null;
      }
    }
    /**
     * This method is used to get around sandboxed iframe restrictions.
     * If 'allow-top-navigation' is not specified in the iframe's 'sandbox' attribute
     * (as is the case with codepens) the parent window is forbidden from calling certain
     * methods on the child, such as window.close() or setting document.location.href.
     *
     * This prevented GoldenLayout popouts from popping in in codepens. The fix is to call
     * _$closeWindow on the child window's gl instance which (after a timeout to disconnect
     * the invoking method from the close call) closes itself.
     *
     * @packagePrivate
     *
     * @returns {void}
     */

  }, {
    key: "_$closeWindow",
    value: function _$closeWindow() {
      window.setTimeout(function () {
        window.close();
      }, 1);
    }
  }, {
    key: "_$getArea",
    value: function _$getArea(x, y) {
      var i,
          area,
          smallestSurface = Infinity,
          mathingArea = null;

      for (i = 0; i < this._itemAreas.length; i++) {
        area = this._itemAreas[i];

        if (x > area.x1 && x < area.x2 && y > area.y1 && y < area.y2 && smallestSurface > area.surface) {
          smallestSurface = area.surface;
          mathingArea = area;
        }
      }

      return mathingArea;
    }
  }, {
    key: "_$createRootItemAreas",
    value: function _$createRootItemAreas() {
      var areaSize = 50;
      var sides = {
        y2: 'y1',
        x2: 'x1',
        y1: 'y2',
        x1: 'x2'
      };

      for (var side in sides) {
        var area = this.root._$getArea();

        area.side = side;
        if (sides[side][1] === '2') area[side] = area[sides[side]] - areaSize;else area[side] = area[sides[side]] + areaSize;
        area.surface = (area.x2 - area.x1) * (area.y2 - area.y1);

        this._itemAreas.push(area);
      }
    }
  }, {
    key: "_$calculateItemAreas",
    value: function _$calculateItemAreas() {
      var i,
          area,
          allContentItems = this._getAllContentItems();

      this._itemAreas = [];
      /**
       * If the last item is dragged out, highlight the entire container size to
       * allow to re-drop it. allContentItems[ 0 ] === this.root at this point
       *
       * Don't include root into the possible drop areas though otherwise since it
       * will used for every gap in the layout, e.g. splitters
       */

      if (allContentItems.length === 1) {
        this._itemAreas.push(this.root._$getArea());

        return;
      }

      this._$createRootItemAreas();

      for (i = 0; i < allContentItems.length; i++) {
        if (!allContentItems[i].isStack) {
          continue;
        }

        area = allContentItems[i]._$getArea();

        if (area === null) {
          continue;
        } else if (area instanceof Array) {
          this._itemAreas = this._itemAreas.concat(area);
        } else {
          this._itemAreas.push(area);

          var header = {};
          Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["copy"])(header, area);
          Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["copy"])(header, area.contentItem._contentAreaDimensions.header.highlightArea);
          header.surface = (header.x2 - header.x1) * (header.y2 - header.y1);

          this._itemAreas.push(header);
        }
      }
    }
    /**
     * Takes a contentItem or a configuration and optionally a parent
     * item and returns an initialised instance of the contentItem.
     * If the contentItem is a function, it is first called
     *
     * @packagePrivate
     *
     * @param   {AbtractContentItem|Object|Function} contentItemOrConfig
     * @param   {AbtractContentItem} parent Only necessary when passing in config
     *
     * @returns {AbtractContentItem}
     */

  }, {
    key: "_$normalizeContentItem",
    value: function _$normalizeContentItem(contentItemOrConfig, parent) {
      if (!contentItemOrConfig) {
        throw new Error('No content item defined');
      }

      if (Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["isFunction"])(contentItemOrConfig)) {
        contentItemOrConfig = contentItemOrConfig();
      }

      if (contentItemOrConfig instanceof _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_7__["default"]) {
        return contentItemOrConfig;
      }

      if (jquery__WEBPACK_IMPORTED_MODULE_15___default.a.isPlainObject(contentItemOrConfig) && contentItemOrConfig.type) {
        var newContentItem = this.createContentItem(contentItemOrConfig, parent);
        newContentItem.callDownwards('_$init');
        return newContentItem;
      } else {
        throw new Error('Invalid contentItem');
      }
    }
    /**
     * Iterates through the array of open popout windows and removes the ones
     * that are effectively closed. This is necessary due to the lack of reliably
     * listening for window.close / unload events in a cross browser compatible fashion.
     *
     * @packagePrivate
     *
     * @returns {void}
     */

  }, {
    key: "_$reconcilePopoutWindows",
    value: function _$reconcilePopoutWindows() {
      var openPopouts = [],
          i;

      for (i = 0; i < this.openPopouts.length; i++) {
        if (this.openPopouts[i].getWindow().closed === false) {
          openPopouts.push(this.openPopouts[i]);
        } else {
          this.emit('windowClosed', this.openPopouts[i]);
        }
      }

      if (this.openPopouts.length !== openPopouts.length) {
        this.openPopouts = openPopouts;
        this.emit('stateChanged');
      }
    }
    /***************************
     * PRIVATE
     ***************************/

    /**
     * Returns a flattened array of all content items,
     * regardles of level or type
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_getAllContentItems",
    value: function _getAllContentItems() {
      var allContentItems = [];

      var addChildren = function addChildren(contentItem) {
        allContentItems.push(contentItem);

        if (contentItem.contentItems instanceof Array) {
          for (var i = 0; i < contentItem.contentItems.length; i++) {
            addChildren(contentItem.contentItems[i]);
          }
        }
      };

      addChildren(this.root);
      return allContentItems;
    }
    /**
     * Binds to DOM/BOM events on init
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_bindEvents",
    value: function _bindEvents() {
      if (this._isFullPage) {
        jquery__WEBPACK_IMPORTED_MODULE_15___default()(window).resize(this._resizeFunction);
      }

      jquery__WEBPACK_IMPORTED_MODULE_15___default()(window).on('unload beforeunload', this._unloadFunction);
    }
    /**
     * Debounces resize events
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_onResize",
    value: function _onResize() {
      clearTimeout(this._resizeTimeoutId);
      this._resizeTimeoutId = setTimeout(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(this.updateSize, this), 100);
    }
    /**
     * Extends the default config with the user specific settings and applies
     * derivations. Please note that there's a separate method (AbstractContentItem._extendItemNode)
     * that deals with the extension of item configs
     *
     * @param   {Object} config
     * @static
     * @returns {Object} config
     */

  }, {
    key: "_createConfig",
    value: function _createConfig(config) {
      var _this2 = this;

      var windowConfigKey = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["getQueryStringParam"])('gl-window');

      if (windowConfigKey) {
        this.isSubWindow = true;
        config = localStorage.getItem(windowConfigKey);
        config = JSON.parse(config);
        config = new _utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_1__["default"]().unminifyConfig(config);
        localStorage.removeItem(windowConfigKey);
      }

      config = jquery__WEBPACK_IMPORTED_MODULE_15___default.a.extend(true, {}, _config_defaultConfig__WEBPACK_IMPORTED_MODULE_13__["default"], config);

      var nextNode = function nextNode(node) {
        for (var key in node) {
          if (key !== 'props' && _typeof(node[key]) === 'object') {
            nextNode(node[key]);
          } else if (key === 'type' && _this2.isReactConfig(node)) {
            node.type = 'component';
            node.componentName = REACT_COMPONENT_ID;
          }
        }
      };

      nextNode(config);

      if (config.settings.hasHeaders === false) {
        config.dimensions.headerHeight = 0;
      }

      return config;
    }
    /**
     * This is executed when GoldenLayout detects that it is run
     * within a previously opened popout window.
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_adjustToWindowMode",
    value: function _adjustToWindowMode() {
      var popInButton = jquery__WEBPACK_IMPORTED_MODULE_15___default()('<div class="lm_popin" title="' + this.config.labels.popin + '">' + '<div class="lm_icon"></div>' + '<div class="lm_bg"></div>' + '</div>');
      popInButton.click(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(function () {
        this.emit('popIn');
      }, this));
      document.title = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["stripTags"])(this.config.content[0].title);
      jquery__WEBPACK_IMPORTED_MODULE_15___default()('head').append(jquery__WEBPACK_IMPORTED_MODULE_15___default()('body link, body style, template, .gl_keep'));
      this.container = jquery__WEBPACK_IMPORTED_MODULE_15___default()('body').html('').css('visibility', 'visible').append(popInButton);
      /*
       * This seems a bit pointless, but actually causes a reflow/re-evaluation getting around
       * slickgrid's "Cannot find stylesheet." bug in chrome
       */

      var x = document.body.offsetHeight; // jshint ignore:line

      /*
       * Expose this instance on the window object
       * to allow the opening window to interact with
       * it
       */

      window.__glInstance = this;
    }
    /**
     * Creates Subwindows (if there are any). Throws an error
     * if popouts are blocked.
     *
     * @returns {void}
     */

  }, {
    key: "_createSubWindows",
    value: function _createSubWindows() {
      var i, popout;

      for (i = 0; i < this.config.openPopouts.length; i++) {
        popout = this.config.openPopouts[i];
        this.createPopout(popout.content, popout.dimensions, popout.parentId, popout.indexInParent);
      }
    }
    /**
     * Determines what element the layout will be created in
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_setContainer",
    value: function _setContainer() {
      var container = jquery__WEBPACK_IMPORTED_MODULE_15___default()(this.container || 'body');

      if (container.length === 0) {
        throw new Error('GoldenLayout container not found');
      }

      if (container.length > 1) {
        throw new Error('GoldenLayout more than one container element specified');
      }

      if (container[0] === document.body) {
        this._isFullPage = true;
        jquery__WEBPACK_IMPORTED_MODULE_15___default()('html, body').css({
          height: '100%',
          margin: 0,
          padding: 0,
          overflow: 'hidden'
        });
      }

      this.container = container;
    }
    /**
     * Kicks of the initial, recursive creation chain
     *
     * @param   {Object} config GoldenLayout Config
     *
     * @returns {void}
     */

  }, {
    key: "_create",
    value: function _create(config) {
      var errorMsg;

      if (!(config.content instanceof Array)) {
        if (config.content === undefined) {
          errorMsg = 'Missing setting \'content\' on top level of configuration';
        } else {
          errorMsg = 'Configuration parameter \'content\' must be an array';
        }

        throw new _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_12__["default"](errorMsg, config);
      }

      if (config.content.length > 1) {
        errorMsg = 'Top level content can\'t contain more then one element.';
        throw new _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_12__["default"](errorMsg, config);
      }

      this.root = new _items_Root__WEBPACK_IMPORTED_MODULE_3__["default"](this, {
        content: config.content
      }, this.container);
      this.root.callDownwards('_$init');

      if (config.maximisedItemId === '__glMaximised') {
        this.root.getItemsById(config.maximisedItemId)[0].toggleMaximise();
      }
    }
    /**
     * Called when the window is closed or the user navigates away
     * from the page
     *
     * @returns {void}
     */

  }, {
    key: "_onUnload",
    value: function _onUnload() {
      if (this.config.settings.closePopoutsOnUnload === true) {
        for (var i = 0; i < this.openPopouts.length; i++) {
          this.openPopouts[i].close();
        }
      }
    }
    /**
     * Adjusts the number of columns to be lower to fit the screen and still maintain minItemWidth.
     *
     * @returns {void}
     */

  }, {
    key: "_adjustColumnsResponsive",
    value: function _adjustColumnsResponsive() {
      // If there is no min width set, or not content items, do nothing.
      if (!this._useResponsiveLayout() || this._updatingColumnsResponsive || !this.config.dimensions || !this.config.dimensions.minItemWidth || this.root.contentItems.length === 0 || !this.root.contentItems[0].isRow) {
        this._firstLoad = false;
        return;
      }

      this._firstLoad = false; // If there is only one column, do nothing.

      var columnCount = this.root.contentItems[0].contentItems.length;

      if (columnCount <= 1) {
        return;
      } // If they all still fit, do nothing.


      var minItemWidth = this.config.dimensions.minItemWidth;
      var totalMinWidth = columnCount * minItemWidth;

      if (totalMinWidth <= this.width) {
        return;
      } // Prevent updates while it is already happening.


      this._updatingColumnsResponsive = true; // Figure out how many columns to stack, and put them all in the first stack container.

      var finalColumnCount = Math.max(Math.floor(this.width / minItemWidth), 1);
      var stackColumnCount = columnCount - finalColumnCount;
      var rootContentItem = this.root.contentItems[0];

      var firstStackContainer = this._findAllStackContainers()[0];

      for (var i = 0; i < stackColumnCount; i++) {
        // Stack from right.
        var column = rootContentItem.contentItems[rootContentItem.contentItems.length - 1];

        this._addChildContentItemsToContainer(firstStackContainer, column);
      }

      this._updatingColumnsResponsive = false;
    }
    /**
     * Determines if responsive layout should be used.
     *
     * @returns {bool} - True if responsive layout should be used; otherwise false.
     */

  }, {
    key: "_useResponsiveLayout",
    value: function _useResponsiveLayout() {
      return this.config.settings && (this.config.settings.responsiveMode == 'always' || this.config.settings.responsiveMode == 'onload' && this._firstLoad);
    }
    /**
     * Adds all children of a node to another container recursively.
     * @param {object} container - Container to add child content items to.
     * @param {object} node - Node to search for content items.
     * @returns {void}
     */

  }, {
    key: "_addChildContentItemsToContainer",
    value: function _addChildContentItemsToContainer(container, node) {
      if (node.type === 'stack') {
        node.contentItems.forEach(function (item) {
          container.addChild(item);
          node.removeChild(item, true);
        });
      } else {
        node.contentItems.forEach(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(function (item) {
          this._addChildContentItemsToContainer(container, item);
        }, this));
      }
    }
    /**
     * Finds all the stack containers.
     * @returns {array} - The found stack containers.
     */

  }, {
    key: "_findAllStackContainers",
    value: function _findAllStackContainers() {
      var stackContainers = [];

      this._findAllStackContainersRecursive(stackContainers, this.root);

      return stackContainers;
    }
    /**
     * Finds all the stack containers.
     *
     * @param {array} - Set of containers to populate.
     * @param {object} - Current node to process.
     *
     * @returns {void}
     */

  }, {
    key: "_findAllStackContainersRecursive",
    value: function _findAllStackContainersRecursive(stackContainers, node) {
      node.contentItems.forEach(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_14__["fnBind"])(function (item) {
        if (item.type == 'stack') {
          stackContainers.push(item);
        } else if (!item.isComponent) {
          this._findAllStackContainersRecursive(stackContainers, item);
        }
      }, this));
    }
  }]);

  return LayoutManager;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);
/**
 * Hook that allows to access private classes
 */
// LayoutManager.__lm = lm;




/***/ }),

/***/ "./src/js_es6/config/ItemDefaultConfig.js":
/*!************************************************!*\
  !*** ./src/js_es6/config/ItemDefaultConfig.js ***!
  \************************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
var itemDefaultConfig = {
  isClosable: true,
  reorderEnabled: true,
  title: ''
};
/* harmony default export */ __webpack_exports__["default"] = (itemDefaultConfig);

/***/ }),

/***/ "./src/js_es6/config/defaultConfig.js":
/*!********************************************!*\
  !*** ./src/js_es6/config/defaultConfig.js ***!
  \********************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
var defaultConfig = {
  openPopouts: [],
  settings: {
    hasHeaders: true,
    constrainDragToContainer: true,
    reorderEnabled: true,
    selectionEnabled: false,
    popoutWholeStack: false,
    blockedPopoutsThrowError: true,
    closePopoutsOnUnload: true,
    showPopoutIcon: true,
    showMaximiseIcon: true,
    showCloseIcon: true,
    responsiveMode: 'onload',
    // Can be onload, always, or none.
    tabOverlapAllowance: 0,
    // maximum pixel overlap per tab
    reorderOnTabMenuClick: true,
    tabControlOffset: 10
  },
  dimensions: {
    borderWidth: 5,
    borderGrabWidth: 15,
    minItemHeight: 10,
    minItemWidth: 10,
    headerHeight: 20,
    dragProxyWidth: 300,
    dragProxyHeight: 200
  },
  labels: {
    close: 'close',
    maximise: 'maximise',
    minimise: 'minimise',
    popout: 'open in new window',
    popin: 'pop in',
    tabDropdown: 'additional tabs'
  }
};
/* harmony default export */ __webpack_exports__["default"] = (defaultConfig);

/***/ }),

/***/ "./src/js_es6/container/ItemContainer.js":
/*!***********************************************!*\
  !*** ./src/js_es6/container/ItemContainer.js ***!
  \***********************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return ItemContainer; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_1___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_1__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }




var ItemContainer = /*#__PURE__*/function (_EventEmitter) {
  _inherits(ItemContainer, _EventEmitter);

  var _super = _createSuper(ItemContainer);

  function ItemContainer(config, parent, layoutManager) {
    var _this;

    _classCallCheck(this, ItemContainer);

    _this = _super.call(this);
    _this.width = null;
    _this.height = null;
    _this.title = config.componentName;
    _this.parent = parent;
    _this.layoutManager = layoutManager;
    _this.isHidden = false;
    _this._config = config;
    _this._element = jquery__WEBPACK_IMPORTED_MODULE_1___default()(['<div class="lm_item_container">', '<div class="lm_content"></div>', '</div>'].join(''));
    _this._contentElement = _this._element.find('.lm_content');
    return _this;
  }
  /**
   * Get the inner DOM element the container's content
   * is intended to live in
   *
   * @returns {DOM element}
   */


  _createClass(ItemContainer, [{
    key: "getElement",
    value: function getElement() {
      return this._contentElement;
    }
    /**
     * Hide the container. Notifies the containers content first
     * and then hides the DOM node. If the container is already hidden
     * this should have no effect
     *
     * @returns {void}
     */

  }, {
    key: "hide",
    value: function hide() {
      this.emit('hide');
      this.isHidden = true;

      this._element.hide();
    }
    /**
     * Shows a previously hidden container. Notifies the
     * containers content first and then shows the DOM element.
     * If the container is already visible this has no effect.
     *
     * @returns {void}
     */

  }, {
    key: "show",
    value: function show() {
      this.emit('show');
      this.isHidden = false;

      this._element.show(); // call shown only if the container has a valid size


      if (this.height != 0 || this.width != 0) {
        this.emit('shown');
      }
    }
    /**
     * Set the size from within the container. Traverses up
     * the item tree until it finds a row or column element
     * and resizes its items accordingly.
     *
     * If this container isn't a descendant of a row or column
     * it returns false
     * @todo  Rework!!!
     * @param {Number} width  The new width in pixel
     * @param {Number} height The new height in pixel
     *
     * @returns {Boolean} resizeSuccesful
     */

  }, {
    key: "setSize",
    value: function setSize(width, height) {
      var rowOrColumn = this.parent,
          rowOrColumnChild = this,
          totalPixel,
          percentage,
          direction,
          newSize,
          delta,
          i;

      while (!rowOrColumn.isColumn && !rowOrColumn.isRow) {
        rowOrColumnChild = rowOrColumn;
        rowOrColumn = rowOrColumn.parent;
        /**
         * No row or column has been found
         */

        if (rowOrColumn.isRoot) {
          return false;
        }
      }

      direction = rowOrColumn.isColumn ? "height" : "width";
      newSize = direction === "height" ? height : width;
      totalPixel = this[direction] * (1 / (rowOrColumnChild.config[direction] / 100));
      percentage = newSize / totalPixel * 100;
      delta = (rowOrColumnChild.config[direction] - percentage) / (rowOrColumn.contentItems.length - 1);

      for (i = 0; i < rowOrColumn.contentItems.length; i++) {
        if (rowOrColumn.contentItems[i] === rowOrColumnChild) {
          rowOrColumn.contentItems[i].config[direction] = percentage;
        } else {
          rowOrColumn.contentItems[i].config[direction] += delta;
        }
      }

      rowOrColumn.callDownwards('setSize');
      return true;
    }
    /**
     * Closes the container if it is closable. Can be called by
     * both the component within at as well as the contentItem containing
     * it. Emits a close event before the container itself is closed.
     *
     * @returns {void}
     */

  }, {
    key: "close",
    value: function close() {
      if (this._config.isClosable) {
        this.emit('close');
        this.parent.close();
      }
    }
    /**
     * Returns the current state object
     *
     * @returns {Object} state
     */

  }, {
    key: "getState",
    value: function getState() {
      return this._config.componentState;
    }
    /**
     * Merges the provided state into the current one
     *
     * @param   {Object} state
     *
     * @returns {void}
     */

  }, {
    key: "extendState",
    value: function extendState(state) {
      this.setState(jquery__WEBPACK_IMPORTED_MODULE_1___default.a.extend(true, this.getState(), state));
    }
    /**
     * Notifies the layout manager of a stateupdate
     *
     * @param {serialisable} state
     */

  }, {
    key: "setState",
    value: function setState(state) {
      this._config.componentState = state;
      this.parent.emitBubblingEvent('stateChanged');
    }
    /**
     * Set's the components title
     *
     * @param {String} title
     */

  }, {
    key: "setTitle",
    value: function setTitle(title) {
      this.parent.setTitle(title);
    }
    /**
     * Set's the containers size. Called by the container's component.
     * To set the size programmatically from within the container please
     * use the public setSize method
     *
     * @param {[Int]} width  in px
     * @param {[Int]} height in px
     *
     * @returns {void}
     */

  }, {
    key: "_$setSize",
    value: function _$setSize(width, height) {
      if (width !== this.width || height !== this.height) {
        this.width = width;
        this.height = height;
        jquery__WEBPACK_IMPORTED_MODULE_1___default.a.zepto ? this._contentElement.width(width) : this._contentElement.outerWidth(width);
        jquery__WEBPACK_IMPORTED_MODULE_1___default.a.zepto ? this._contentElement.height(height) : this._contentElement.outerHeight(height);
        this.emit('resize');
      }
    }
  }]);

  return ItemContainer;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/controls/BrowserPopout.js":
/*!**********************************************!*\
  !*** ./src/js_es6/controls/BrowserPopout.js ***!
  \**********************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return BrowserPopout; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../utils/ConfigMinifier */ "./src/js_es6/utils/ConfigMinifier.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_3__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }





/**
 * Pops a content item out into a new browser window.
 * This is achieved by
 *
 *    - Creating a new configuration with the content item as root element
 *    - Serializing and minifying the configuration
 *    - Opening the current window's URL with the configuration as a GET parameter
 *    - GoldenLayout when opened in the new window will look for the GET parameter
 *      and use it instead of the provided configuration
 *
 * @param {Object} config GoldenLayout item config
 * @param {Object} dimensions A map with width, height, top and left
 * @param {String} parentId The id of the element the item will be appended to on popIn
 * @param {Number} indexInParent The position of this element within its parent
 * @param {lm.LayoutManager} layoutManager
 */

var BrowserPopout = /*#__PURE__*/function (_EventEmitter) {
  _inherits(BrowserPopout, _EventEmitter);

  var _super = _createSuper(BrowserPopout);

  function BrowserPopout(config, dimensions, parentId, indexInParent, layoutManager) {
    var _this;

    _classCallCheck(this, BrowserPopout);

    _this = _super.call(this);
    _this.isInitialised = false;
    _this._config = config;
    _this._dimensions = dimensions;
    _this._parentId = parentId;
    _this._indexInParent = indexInParent;
    _this._layoutManager = layoutManager;
    _this._popoutWindow = null;
    _this._id = null;

    _this._createWindow();

    return _this;
  }

  _createClass(BrowserPopout, [{
    key: "toConfig",
    value: function toConfig() {
      if (this.isInitialised === false) {
        throw new Error('Can\'t create config, layout not yet initialised');
      }

      return {
        dimensions: {
          width: this.getGlInstance().width,
          height: this.getGlInstance().height,
          left: this._popoutWindow.screenX || this._popoutWindow.screenLeft,
          top: this._popoutWindow.screenY || this._popoutWindow.screenTop
        },
        content: this.getGlInstance().toConfig().content,
        parentId: this._parentId,
        indexInParent: this._indexInParent
      };
    }
  }, {
    key: "getGlInstance",
    value: function getGlInstance() {
      return this._popoutWindow.__glInstance;
    }
  }, {
    key: "getWindow",
    value: function getWindow() {
      return this._popoutWindow;
    }
  }, {
    key: "close",
    value: function close() {
      if (this.getGlInstance()) {
        this.getGlInstance()._$closeWindow();
      } else {
        try {
          this.getWindow().close();
        } catch (e) {//
        }
      }
    }
    /**
     * Returns the popped out item to its original position. If the original
     * parent isn't available anymore it falls back to the layout's topmost element
     */

  }, {
    key: "popIn",
    value: function popIn() {
      var childConfig,
          parentItem,
          index = this._indexInParent;

      if (this._parentId) {
        /*
         * The $.extend call seems a bit pointless, but it's crucial to
         * copy the config returned by this.getGlInstance().toConfig()
         * onto a new object. Internet Explorer keeps the references
         * to objects on the child window, resulting in the following error
         * once the child window is closed:
         *
         * The callee (server [not server application]) is not available and disappeared
         */
        childConfig = jquery__WEBPACK_IMPORTED_MODULE_3___default.a.extend(true, {}, this.getGlInstance().toConfig()).content[0];
        parentItem = this._layoutManager.root.getItemsById(this._parentId)[0];
        /*
         * Fallback if parentItem is not available. Either add it to the topmost
         * item or make it the topmost item if the layout is empty
         */

        if (!parentItem) {
          if (this._layoutManager.root.contentItems.length > 0) {
            parentItem = this._layoutManager.root.contentItems[0];
          } else {
            parentItem = this._layoutManager.root;
          }

          index = 0;
        }
      }

      parentItem.addChild(childConfig, this._indexInParent);
      this.close();
    }
    /**
     * Creates the URL and window parameter
     * and opens a new window
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_createWindow",
    value: function _createWindow() {
      var checkReadyInterval,
          url = this._createUrl(),

      /**
       * Bogus title to prevent re-usage of existing window with the
       * same title. The actual title will be set by the new window's
       * GoldenLayout instance if it detects that it is in subWindowMode
       */
      title = Math.floor(Math.random() * 1000000).toString(36),

      /**
       * The options as used in the window.open string
       */
      options = this._serializeWindowOptions({
        width: this._dimensions.width,
        height: this._dimensions.height,
        innerWidth: this._dimensions.width,
        innerHeight: this._dimensions.height,
        menubar: 'no',
        toolbar: 'no',
        location: 'no',
        personalbar: 'no',
        resizable: 'yes',
        scrollbars: 'no',
        status: 'no'
      });

      this._popoutWindow = window.open(url, title, options);

      if (!this._popoutWindow) {
        if (this._layoutManager.config.settings.blockedPopoutsThrowError === true) {
          var error = new Error('Popout blocked');
          error.type = 'popoutBlocked';
          throw error;
        } else {
          return;
        }
      }

      jquery__WEBPACK_IMPORTED_MODULE_3___default()(this._popoutWindow).on('load', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["fnBind"])(this._positionWindow, this)).on('unload beforeunload', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["fnBind"])(this._onClose, this));
      /**
       * Polling the childwindow to find out if GoldenLayout has been initialised
       * doesn't seem optimal, but the alternatives - adding a callback to the parent
       * window or raising an event on the window object - both would introduce knowledge
       * about the parent to the child window which we'd rather avoid
       */

      checkReadyInterval = setInterval(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["fnBind"])(function () {
        if (this._popoutWindow.__glInstance && this._popoutWindow.__glInstance.isInitialised) {
          this._onInitialised();

          clearInterval(checkReadyInterval);
        }
      }, this), 10);
    }
    /**
     * Serialises a map of key:values to a window options string
     *
     * @param   {Object} windowOptions
     *
     * @returns {String} serialised window options
     */

  }, {
    key: "_serializeWindowOptions",
    value: function _serializeWindowOptions(windowOptions) {
      var windowOptionsString = [],
          key;

      for (key in windowOptions) {
        windowOptionsString.push(key + '=' + windowOptions[key]);
      }

      return windowOptionsString.join(',');
    }
    /**
     * Creates the URL for the new window, including the
     * config GET parameter
     *
     * @returns {String} URL
     */

  }, {
    key: "_createUrl",
    value: function _createUrl() {
      var config = {
        content: this._config
      },
          storageKey = 'gl-window-config-' + Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["getUniqueId"])(),
          urlParts;
      config = new _utils_ConfigMinifier__WEBPACK_IMPORTED_MODULE_1__["default"]().minifyConfig(config);

      try {
        localStorage.setItem(storageKey, JSON.stringify(config));
      } catch (e) {
        throw new Error('Error while writing to localStorage ' + e.toString());
      }

      urlParts = document.location.href.split('?'); // URL doesn't contain GET-parameters

      if (urlParts.length === 1) {
        return urlParts[0] + '?gl-window=' + storageKey; // URL contains GET-parameters
      } else {
        return document.location.href + '&gl-window=' + storageKey;
      }
    }
    /**
     * Move the newly created window roughly to
     * where the component used to be.
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_positionWindow",
    value: function _positionWindow() {
      this._popoutWindow.moveTo(this._dimensions.left, this._dimensions.top);

      this._popoutWindow.focus();
    }
    /**
     * Callback when the new window is opened and the GoldenLayout instance
     * within it is initialised
     *
     * @returns {void}
     */

  }, {
    key: "_onInitialised",
    value: function _onInitialised() {
      this.isInitialised = true;
      this.getGlInstance().on('popIn', this.popIn, this);
      this.emit('initialised');
    }
    /**
     * Invoked 50ms after the window unload event
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_onClose",
    value: function _onClose() {
      setTimeout(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["fnBind"])(this.emit, this, ['closed']), 50);
    }
  }]);

  return BrowserPopout;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/controls/DragProxy.js":
/*!******************************************!*\
  !*** ./src/js_es6/controls/DragProxy.js ***!
  \******************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return DragProxy; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_2__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }





var _template = '<div class="lm_dragProxy">' + '<div class="lm_header">' + '<ul class="lm_tabs">' + '<li class="lm_tab lm_active"><i class="lm_left"></i>' + '<span class="lm_title"></span>' + '<i class="lm_right"></i></li>' + '</ul>' + '</div>' + '<div class="lm_content"></div>' + '</div>';
/**
 * This class creates a temporary container
 * for the component whilst it is being dragged
 * and handles drag events
 *
 * @constructor
 * @private
 *
 * @param {Number} x              The initial x position
 * @param {Number} y              The initial y position
 * @param {DragListener} dragListener
 * @param {lm.LayoutManager} layoutManager
 * @param {AbstractContentItem} contentItem
 * @param {AbstractContentItem} originalParent
 */


var DragProxy = /*#__PURE__*/function (_EventEmitter) {
  _inherits(DragProxy, _EventEmitter);

  var _super = _createSuper(DragProxy);

  function DragProxy(x, y, dragListener, layoutManager, contentItem, originalParent) {
    var _this;

    _classCallCheck(this, DragProxy);

    _this = _super.call(this);
    _this._dragListener = dragListener;
    _this._layoutManager = layoutManager;
    _this._contentItem = contentItem;
    _this._originalParent = originalParent;
    _this._area = null;
    _this._lastValidArea = null;

    _this._dragListener.on('drag', _this._onDrag, _assertThisInitialized(_this));

    _this._dragListener.on('dragStop', _this._onDrop, _assertThisInitialized(_this));

    _this.element = jquery__WEBPACK_IMPORTED_MODULE_2___default()(_template);

    if (originalParent && originalParent._side) {
      _this._sided = originalParent._sided;

      _this.element.addClass('lm_' + originalParent._side);

      if (['right', 'bottom'].indexOf(originalParent._side) >= 0) _this.element.find('.lm_content').after(_this.element.find('.lm_header'));
    }

    _this.element.css({
      left: x,
      top: y
    });

    _this.element.find('.lm_tab').attr('title', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["stripTags"])(_this._contentItem.config.title));

    _this.element.find('.lm_title').html(_this._contentItem.config.title);

    _this.childElementContainer = _this.element.find('.lm_content');

    _this.childElementContainer.append(contentItem.element);

    _this._undisplayTree();

    _this._layoutManager._$calculateItemAreas();

    _this._setDimensions();

    jquery__WEBPACK_IMPORTED_MODULE_2___default()(document.body).append(_this.element);

    var offset = _this._layoutManager.container.offset();

    _this._minX = offset.left;
    _this._minY = offset.top;
    _this._maxX = _this._layoutManager.container.width() + _this._minX;
    _this._maxY = _this._layoutManager.container.height() + _this._minY;
    _this._width = _this.element.width();
    _this._height = _this.element.height();

    _this._setDropPosition(x, y);

    return _this;
  }
  /**
   * Callback on every mouseMove event during a drag. Determines if the drag is
   * still within the valid drag area and calls the layoutManager to highlight the
   * current drop area
   *
   * @param   {Number} offsetX The difference from the original x position in px
   * @param   {Number} offsetY The difference from the original y position in px
   * @param   {jQuery DOM event} event
   *
   * @private
   *
   * @returns {void}
   */


  _createClass(DragProxy, [{
    key: "_onDrag",
    value: function _onDrag(offsetX, offsetY, event) {
      event = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["getTouchEvent"])(event);
      var x = event.pageX,
          y = event.pageY,
          isWithinContainer = x > this._minX && x < this._maxX && y > this._minY && y < this._maxY;

      if (!isWithinContainer && this._layoutManager.config.settings.constrainDragToContainer === true) {
        return;
      }

      this._setDropPosition(x, y);
    }
    /**
     * Sets the target position, highlighting the appropriate area
     *
     * @param   {Number} x The x position in px
     * @param   {Number} y The y position in px
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_setDropPosition",
    value: function _setDropPosition(x, y) {
      this.element.css({
        left: x,
        top: y
      });
      this._area = this._layoutManager._$getArea(x, y);

      if (this._area !== null) {
        this._lastValidArea = this._area;

        this._area.contentItem._$highlightDropZone(x, y, this._area);
      }
    }
    /**
     * Callback when the drag has finished. Determines the drop area
     * and adds the child to it
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_onDrop",
    value: function _onDrop() {
      this._updateTree();

      this._layoutManager.dropTargetIndicator.hide();
      /*
       * Valid drop area found
       */


      if (this._area !== null) {
        this._area.contentItem._$onDrop(this._contentItem, this._area);
        /**
         * No valid drop area available at present, but one has been found before.
         * Use it
         */

      } else if (this._lastValidArea !== null) {
        this._lastValidArea.contentItem._$onDrop(this._contentItem, this._lastValidArea);
        /**
         * No valid drop area found during the duration of the drag. Return
         * content item to its original position if a original parent is provided.
         * (Which is not the case if the drag had been initiated by createDragSource)
         */

      } else if (this._originalParent) {
        this._originalParent.addChild(this._contentItem);
        /**
         * The drag didn't ultimately end up with adding the content item to
         * any container. In order to ensure clean up happens, destroy the
         * content item.
         */

      } else {
        this._contentItem._$destroy();
      }

      this.element.remove();

      this._layoutManager.emit('itemDropped', this._contentItem);
    }
    /**
     * Undisplays the item from its original position within the tree
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_undisplayTree",
    value: function _undisplayTree() {
      /**
       * parent is null if the drag had been initiated by a external drag source
       */
      if (this._contentItem.parent) {
        this._contentItem.parent.undisplayChild(this._contentItem);
      }
    }
    /**
     * Removes the item from its original position within the tree
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_updateTree",
    value: function _updateTree() {
      /**
       * parent is null if the drag had been initiated by a external drag source
       */
      if (this._contentItem.parent) {
        this._contentItem.parent.removeChild(this._contentItem, true);
      }

      this._contentItem._$setParent(this);
    }
    /**
     * Updates the Drag Proxie's dimensions
     *
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_setDimensions",
    value: function _setDimensions() {
      var dimensions = this._layoutManager.config.dimensions,
          width = dimensions.dragProxyWidth,
          height = dimensions.dragProxyHeight;
      this.element.width(width);
      this.element.height(height);
      width -= this._sided ? dimensions.headerHeight : 0;
      height -= !this._sided ? dimensions.headerHeight : 0;
      this.childElementContainer.width(width);
      this.childElementContainer.height(height);

      this._contentItem.element.width(width);

      this._contentItem.element.height(height);

      this._contentItem.callDownwards('_$show');

      this._contentItem.callDownwards('setSize');
    }
  }]);

  return DragProxy;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/controls/DragSource.js":
/*!*******************************************!*\
  !*** ./src/js_es6/controls/DragSource.js ***!
  \*******************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return DragSource; });
/* harmony import */ var _utils_DragListener__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/DragListener */ "./src/js_es6/utils/DragListener.js");
/* harmony import */ var _controls_DragProxy__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../controls/DragProxy */ "./src/js_es6/controls/DragProxy.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_3__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }





/**
 * Allows for any DOM item to create a component on drag
 * start tobe dragged into the Layout
 *
 * @param {jQuery element} element
 * @param {Object} itemConfig the configuration for the contentItem that will be created
 * @param {LayoutManager} layoutManager
 *
 * @constructor
 */

var DragSource = /*#__PURE__*/function () {
  function DragSource(element, itemConfig, layoutManager) {
    _classCallCheck(this, DragSource);

    this._element = element;
    this._itemConfig = itemConfig;
    this._layoutManager = layoutManager;
    this._dragListener = null;

    this._createDragListener();
  }
  /**
   * Disposes of the drag listeners so the drag source is not usable any more.
   *
   * @returns {void}
   */


  _createClass(DragSource, [{
    key: "destroy",
    value: function destroy() {
      this._removeDragListener();
    }
    /**
     * Called initially and after every drag
     *
     * @returns {void}
     */

  }, {
    key: "_createDragListener",
    value: function _createDragListener() {
      this._removeDragListener();

      this._dragListener = new _utils_DragListener__WEBPACK_IMPORTED_MODULE_0__["default"](this._element);

      this._dragListener.on('dragStart', this._onDragStart, this);

      this._dragListener.on('dragStop', this._createDragListener, this);
    }
    /**
     * Callback for the DragListener's dragStart event
     *
     * @param   {int} x the x position of the mouse on dragStart
     * @param   {int} y the x position of the mouse on dragStart
     *
     * @returns {void}
     */

  }, {
    key: "_onDragStart",
    value: function _onDragStart(x, y) {
      var itemConfig = this._itemConfig;

      if (Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["isFunction"])(itemConfig)) {
        itemConfig = itemConfig();
      }

      var contentItem = this._layoutManager._$normalizeContentItem(jquery__WEBPACK_IMPORTED_MODULE_3___default.a.extend(true, {}, itemConfig)),
          dragProxy = new _controls_DragProxy__WEBPACK_IMPORTED_MODULE_1__["default"](x, y, this._dragListener, this._layoutManager, contentItem, null);

      this._layoutManager.transitionIndicator.transitionElements(this._element, dragProxy.element);
    }
    /**
    * Called after every drag and when the drag source is being disposed of.
    *
    * @returns {void}
    */

  }, {
    key: "_removeDragListener",
    value: function _removeDragListener() {
      if (this._dragListener !== null) {
        this._dragListener.destroy();
      }
    }
  }]);

  return DragSource;
}();



/***/ }),

/***/ "./src/js_es6/controls/DropTargetIndicator.js":
/*!****************************************************!*\
  !*** ./src/js_es6/controls/DropTargetIndicator.js ***!
  \****************************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return DropTargetIndicator; });
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_0__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }


var _template = '<div class="lm_dropTargetIndicator"><div class="lm_inner"></div></div>';

var DropTargetIndicator = /*#__PURE__*/function () {
  function DropTargetIndicator() {
    _classCallCheck(this, DropTargetIndicator);

    this.element = jquery__WEBPACK_IMPORTED_MODULE_0___default()(_template);
    jquery__WEBPACK_IMPORTED_MODULE_0___default()(document.body).append(this.element);
  }

  _createClass(DropTargetIndicator, [{
    key: "destroy",
    value: function destroy() {
      this.element.remove();
    }
  }, {
    key: "highlight",
    value: function highlight(x1, y1, x2, y2) {
      this.highlightArea({
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2
      });
    }
  }, {
    key: "highlightArea",
    value: function highlightArea(area) {
      this.element.css({
        left: area.x1,
        top: area.y1,
        width: area.x2 - area.x1,
        height: area.y2 - area.y1
      }).show();
    }
  }, {
    key: "hide",
    value: function hide() {
      this.element.hide();
    }
  }]);

  return DropTargetIndicator;
}();



/***/ }),

/***/ "./src/js_es6/controls/Header.js":
/*!***************************************!*\
  !*** ./src/js_es6/controls/Header.js ***!
  \***************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return Header; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _controls_Tab__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../controls/Tab */ "./src/js_es6/controls/Tab.js");
/* harmony import */ var _controls_HeaderButton__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../controls/HeaderButton */ "./src/js_es6/controls/HeaderButton.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_4___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_4__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }







var _template = ['<div class="lm_header">', '<ul class="lm_tabs"></ul>', '<ul class="lm_controls"></ul>', '<ul class="lm_tabdropdown_list"></ul>', '</div>'].join('');
/**
 * This class represents a header above a Stack ContentItem.
 *
 * @param {lm.LayoutManager} layoutManager
 * @param {AbstractContentItem} parent
 */


var Header = /*#__PURE__*/function (_EventEmitter) {
  _inherits(Header, _EventEmitter);

  var _super = _createSuper(Header);

  function Header(layoutManager, parent) {
    var _this;

    _classCallCheck(this, Header);

    _this = _super.call(this);
    _this.layoutManager = layoutManager;
    _this.element = jquery__WEBPACK_IMPORTED_MODULE_4___default()(_template);

    if (_this.layoutManager.config.settings.selectionEnabled === true) {
      _this.element.addClass('lm_selectable');

      _this.element.on('click touchstart', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(_this._onHeaderClick, _assertThisInitialized(_this)));
    }

    _this.tabsContainer = _this.element.find('.lm_tabs');
    _this.tabDropdownContainer = _this.element.find('.lm_tabdropdown_list');

    _this.tabDropdownContainer.hide();

    _this.controlsContainer = _this.element.find('.lm_controls');
    _this.parent = parent;

    _this.parent.on('resize', _this._updateTabSizes, _assertThisInitialized(_this));

    _this.tabs = [];
    _this.tabsMarkedForRemoval = [];
    _this.activeContentItem = null;
    _this.closeButton = null;
    _this.dockButton = null;
    _this.tabDropdownButton = null;
    _this.hideAdditionalTabsDropdown = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(_this._hideAdditionalTabsDropdown, _assertThisInitialized(_this));
    jquery__WEBPACK_IMPORTED_MODULE_4___default()(document).mouseup(_this.hideAdditionalTabsDropdown);
    _this._lastVisibleTabIndex = -1;
    _this._tabControlOffset = _this.layoutManager.config.settings.tabControlOffset;

    _this._createControls();

    return _this;
  }
  /**
   * Creates a new tab and associates it with a contentItem
   *
   * @param    {AbstractContentItem} contentItem
   * @param    {Integer} index The position of the tab
   *
   * @returns {void}
   */


  _createClass(Header, [{
    key: "createTab",
    value: function createTab(contentItem, index) {
      var tab, i; //If there's already a tab relating to the
      //content item, don't do anything

      for (i = 0; i < this.tabs.length; i++) {
        if (this.tabs[i].contentItem === contentItem) {
          return;
        }
      }

      tab = new _controls_Tab__WEBPACK_IMPORTED_MODULE_1__["default"](this, contentItem);

      if (this.tabs.length === 0) {
        this.tabs.push(tab);
        this.tabsContainer.append(tab.element);
        return;
      }

      if (index === undefined) {
        index = this.tabs.length;
      }

      if (index > 0) {
        this.tabs[index - 1].element.after(tab.element);
      } else {
        this.tabs[0].element.before(tab.element);
      }

      this.tabs.splice(index, 0, tab);

      this._updateTabSizes();
    }
    /**
     * Finds a tab based on the contentItem its associated with and removes it.
     *
     * @param    {AbstractContentItem} contentItem
     *
     * @returns {void}
     */

  }, {
    key: "removeTab",
    value: function removeTab(contentItem) {
      for (var i = 0; i < this.tabs.length; i++) {
        if (this.tabs[i].contentItem === contentItem) {
          this.tabs[i]._$destroy();

          this.tabs.splice(i, 1);
          return;
        }
      }

      for (i = 0; i < this.tabsMarkedForRemoval.length; i++) {
        if (this.tabsMarkedForRemoval[i].contentItem === contentItem) {
          this.tabsMarkedForRemoval[i]._$destroy();

          this.tabsMarkedForRemoval.splice(i, 1);
          return;
        }
      }

      throw new Error('contentItem is not controlled by this header');
    }
    /**
     * Finds a tab based on the contentItem its associated with and marks it
     * for removal, hiding it too.
     *
     * @param    {AbstractContentItem} contentItem
     *
     * @returns {void}
     */

  }, {
    key: "hideTab",
    value: function hideTab(contentItem) {
      for (var i = 0; i < this.tabs.length; i++) {
        if (this.tabs[i].contentItem === contentItem) {
          this.tabs[i].element.hide();
          this.tabsMarkedForRemoval.push(this.tabs[i]);
          this.tabs.splice(i, 1);
          return;
        }
      }

      throw new Error('contentItem is not controlled by this header');
    }
    /**
     * The programmatical equivalent of clicking a Tab.
     *
     * @param {AbstractContentItem} contentItem
     */

  }, {
    key: "setActiveContentItem",
    value: function setActiveContentItem(contentItem) {
      var i, j, isActive, activeTab;
      if (this.activeContentItem === contentItem) return;

      for (i = 0; i < this.tabs.length; i++) {
        isActive = this.tabs[i].contentItem === contentItem;
        this.tabs[i].setActive(isActive);

        if (isActive === true) {
          this.activeContentItem = contentItem;
          this.parent.config.activeItemIndex = i;
        }
      }

      if (this.layoutManager.config.settings.reorderOnTabMenuClick) {
        /**
         * If the tab selected was in the dropdown, move everything down one to make way for this one to be the first.
         * This will make sure the most used tabs stay visible.
         */
        if (this._lastVisibleTabIndex !== -1 && this.parent.config.activeItemIndex > this._lastVisibleTabIndex) {
          activeTab = this.tabs[this.parent.config.activeItemIndex];

          for (j = this.parent.config.activeItemIndex; j > 0; j--) {
            this.tabs[j] = this.tabs[j - 1];
          }

          this.tabs[0] = activeTab;
          this.parent.config.activeItemIndex = 0;
        }
      }

      this._updateTabSizes();

      this.parent.emitBubblingEvent('stateChanged');
    }
    /**
     * Programmatically operate with header position.
     *
     * @param {string} position one of ('top','left','right','bottom') to set or empty to get it.
     *
     * @returns {string} previous header position
     */

  }, {
    key: "position",
    value: function position(_position) {
      var previous = this.parent._header.show;
      if (this.parent._docker && this.parent._docker.docked) throw new Error('Can\'t change header position in docked stack');
      if (previous && !this.parent._side) previous = 'top';

      if (_position !== undefined && this.parent._header.show != _position) {
        this.parent._header.show = _position;
        this.parent.config.header ? this.parent.config.header.show = _position : this.parent.config.header = {
          show: _position
        };

        this.parent._setupHeaderPosition();
      }

      return previous;
    }
    /**
     * Programmatically set closability.
     *
     * @package private
     * @param {Boolean} isClosable Whether to enable/disable closability.
     *
     * @returns {Boolean} Whether the action was successful
     */

  }, {
    key: "_$setClosable",
    value: function _$setClosable(isClosable) {
      this._canDestroy = isClosable || this.tabs.length > 1;

      if (this.closeButton && this._isClosable()) {
        this.closeButton.element[isClosable ? "show" : "hide"]();
        return true;
      }

      return false;
    }
    /**
     * Programmatically set ability to dock.
     *
     * @package private
     * @param {Boolean} isDockable Whether to enable/disable ability to dock.
     *
     * @returns {Boolean} Whether the action was successful
     */

  }, {
    key: "_setDockable",
    value: function _setDockable(isDockable) {
      if (this.dockButton && this.parent._header && this.parent._header.dock) {
        this.dockButton.element.toggle(!!isDockable);
        return true;
      }

      return false;
    }
    /**
     * Destroys the entire header
     *
     * @package private
     *
     * @returns {void}
     */

  }, {
    key: "_$destroy",
    value: function _$destroy() {
      this.emit('destroy', this);

      for (var i = 0; i < this.tabs.length; i++) {
        this.tabs[i]._$destroy();
      }

      jquery__WEBPACK_IMPORTED_MODULE_4___default()(document).off('mouseup', this.hideAdditionalTabsDropdown);
      this.element.remove();
    }
    /**
     * get settings from header
     *
     * @returns {string} when exists
     */

  }, {
    key: "_getHeaderSetting",
    value: function _getHeaderSetting(name) {
      if (name in this.parent._header) return this.parent._header[name];
    }
    /**
     * Creates the popout, maximise and close buttons in the header's top right corner
     *
     * @returns {void}
     */

  }, {
    key: "_createControls",
    value: function _createControls() {
      var closeStack, popout, label, maximiseLabel, minimiseLabel, maximise, maximiseButton, tabDropdownLabel, showTabDropdown;
      /**
       * Dropdown to show additional tabs.
       */

      showTabDropdown = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this._showAdditionalTabsDropdown, this);
      tabDropdownLabel = this.layoutManager.config.labels.tabDropdown;
      this.tabDropdownButton = new _controls_HeaderButton__WEBPACK_IMPORTED_MODULE_2__["default"](this, tabDropdownLabel, 'lm_tabdropdown', showTabDropdown);
      this.tabDropdownButton.element.hide();

      if (this.parent._header && this.parent._header.dock) {
        var button = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this.parent.dock, this.parent);
        label = this._getHeaderSetting('dock');
        this.dockButton = new _controls_HeaderButton__WEBPACK_IMPORTED_MODULE_2__["default"](this, label, 'lm_dock', button);
      }
      /**
       * Popout control to launch component in new window.
       */


      if (this._getHeaderSetting('popout')) {
        popout = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this._onPopoutClick, this);
        label = this._getHeaderSetting('popout');
        new _controls_HeaderButton__WEBPACK_IMPORTED_MODULE_2__["default"](this, label, 'lm_popout', popout);
      }
      /**
       * Maximise control - set the component to the full size of the layout
       */


      if (this._getHeaderSetting('maximise')) {
        maximise = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this.parent.toggleMaximise, this.parent);
        maximiseLabel = this._getHeaderSetting('maximise');
        minimiseLabel = this._getHeaderSetting('minimise');
        maximiseButton = new _controls_HeaderButton__WEBPACK_IMPORTED_MODULE_2__["default"](this, maximiseLabel, 'lm_maximise', maximise);
        this.parent.on('maximised', function () {
          maximiseButton.element.attr('title', minimiseLabel);
        });
        this.parent.on('minimised', function () {
          maximiseButton.element.attr('title', maximiseLabel);
        });
      }
      /**
       * Close button
       */


      if (this._isClosable()) {
        closeStack = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this.parent.remove, this.parent);
        label = this._getHeaderSetting('close');
        this.closeButton = new _controls_HeaderButton__WEBPACK_IMPORTED_MODULE_2__["default"](this, label, 'lm_close', closeStack);
      }
    }
    /**
     * Shows drop down for additional tabs when there are too many to display.
     *
     * @returns {void}
     */

  }, {
    key: "_showAdditionalTabsDropdown",
    value: function _showAdditionalTabsDropdown() {
      this.tabDropdownContainer.show();
    }
    /**
     * Hides drop down for additional tabs when there are too many to display.
     *
     * @returns {void}
     */

  }, {
    key: "_hideAdditionalTabsDropdown",
    value: function _hideAdditionalTabsDropdown(e) {
      this.tabDropdownContainer.hide();
    }
    /**
     * Checks whether the header is closable based on the parent config and
     * the global config.
     *
     * @returns {Boolean} Whether the header is closable.
     */

  }, {
    key: "_isClosable",
    value: function _isClosable() {
      return this.parent.config.isClosable && this.layoutManager.config.settings.showCloseIcon;
    }
  }, {
    key: "_onPopoutClick",
    value: function _onPopoutClick() {
      if (this.layoutManager.config.settings.popoutWholeStack === true) {
        this.parent.popout();
      } else {
        this.activeContentItem.popout();
      }
    }
    /**
     * Invoked when the header's background is clicked (not it's tabs or controls)
     *
     * @param    {jQuery DOM event} event
     *
     * @returns {void}
     */

  }, {
    key: "_onHeaderClick",
    value: function _onHeaderClick(event) {
      if (event.target === this.element[0]) {
        this.parent.select();
      }
    }
    /**
     * Pushes the tabs to the tab dropdown if the available space is not sufficient
     *
     * @returns {void}
     */

  }, {
    key: "_updateTabSizes",
    value: function _updateTabSizes(showTabMenu) {
      if (this.tabs.length === 0) {
        return;
      } //Show the menu based on function argument


      this.tabDropdownButton.element.toggle(showTabMenu === true);

      var size = function size(val) {
        return val ? 'width' : 'height';
      };

      this.element.css(size(!this.parent._sided), '');
      this.element[size(this.parent._sided)](this.layoutManager.config.dimensions.headerHeight);

      var availableWidth = this.element.outerWidth() - this.controlsContainer.outerWidth() - this._tabControlOffset,
          cumulativeTabWidth = 0,
          visibleTabWidth = 0,
          tabElement,
          i,
          j,
          marginLeft,
          overlap = 0,
          tabWidth,
          tabOverlapAllowance = this.layoutManager.config.settings.tabOverlapAllowance,
          tabOverlapAllowanceExceeded = false,
          activeIndex = this.activeContentItem ? this.tabs.indexOf(this.activeContentItem.tab) : 0,
          activeTab = this.tabs[activeIndex];

      if (this.parent._sided) availableWidth = this.element.outerHeight() - this.controlsContainer.outerHeight() - this._tabControlOffset;
      this._lastVisibleTabIndex = -1;

      for (i = 0; i < this.tabs.length; i++) {
        tabElement = this.tabs[i].element; //Put the tab in the tabContainer so its true width can be checked

        this.tabsContainer.append(tabElement);
        tabWidth = tabElement.outerWidth() + parseInt(tabElement.css('margin-right'), 10);
        cumulativeTabWidth += tabWidth; //Include the active tab's width if it isn't already
        //This is to ensure there is room to show the active tab

        if (activeIndex <= i) {
          visibleTabWidth = cumulativeTabWidth;
        } else {
          visibleTabWidth = cumulativeTabWidth + activeTab.element.outerWidth() + parseInt(activeTab.element.css('margin-right'), 10);
        } // If the tabs won't fit, check the overlap allowance.


        if (visibleTabWidth > availableWidth) {
          //Once allowance is exceeded, all remaining tabs go to menu.
          if (!tabOverlapAllowanceExceeded) {
            //No overlap for first tab or active tab
            //Overlap spreads among non-active, non-first tabs
            if (activeIndex > 0 && activeIndex <= i) {
              overlap = (visibleTabWidth - availableWidth) / (i - 1);
            } else {
              overlap = (visibleTabWidth - availableWidth) / i;
            } //Check overlap against allowance.


            if (overlap < tabOverlapAllowance) {
              for (j = 0; j <= i; j++) {
                marginLeft = j !== activeIndex && j !== 0 ? '-' + overlap + 'px' : '';
                this.tabs[j].element.css({
                  'z-index': i - j,
                  'margin-left': marginLeft
                });
              }

              this._lastVisibleTabIndex = i;
              this.tabsContainer.append(tabElement);
            } else {
              tabOverlapAllowanceExceeded = true;
            }
          } else if (i === activeIndex) {
            //Active tab should show even if allowance exceeded. (We left room.)
            tabElement.css({
              'z-index': 'auto',
              'margin-left': ''
            });
            this.tabsContainer.append(tabElement);
          }

          if (tabOverlapAllowanceExceeded && i !== activeIndex) {
            if (showTabMenu) {
              //Tab menu already shown, so we just add to it.
              tabElement.css({
                'z-index': 'auto',
                'margin-left': ''
              });
              this.tabDropdownContainer.append(tabElement);
            } else {
              //We now know the tab menu must be shown, so we have to recalculate everything.
              this._updateTabSizes(true);

              return;
            }
          }
        } else {
          this._lastVisibleTabIndex = i;
          tabElement.css({
            'z-index': 'auto',
            'margin-left': ''
          });
          this.tabsContainer.append(tabElement);
        }
      }
    }
  }]);

  return Header;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/controls/HeaderButton.js":
/*!*********************************************!*\
  !*** ./src/js_es6/controls/HeaderButton.js ***!
  \*********************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return HeaderButton; });
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_0__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }



var HeaderButton = /*#__PURE__*/function () {
  function HeaderButton(header, label, cssClass, action) {
    _classCallCheck(this, HeaderButton);

    this._header = header;
    this.element = jquery__WEBPACK_IMPORTED_MODULE_0___default()('<li class="' + cssClass + '" title="' + label + '"></li>');

    this._header.on('destroy', this._$destroy, this);

    this._action = action;
    this.element.on('click touchstart', this._action);

    this._header.controlsContainer.append(this.element);
  }

  _createClass(HeaderButton, [{
    key: "_$destroy",
    value: function _$destroy() {
      this.element.off();
      this.element.remove();
    }
  }]);

  return HeaderButton;
}();



/***/ }),

/***/ "./src/js_es6/controls/Splitter.js":
/*!*****************************************!*\
  !*** ./src/js_es6/controls/Splitter.js ***!
  \*****************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return Splitter; });
/* harmony import */ var _utils_DragListener__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/DragListener */ "./src/js_es6/utils/DragListener.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_1___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_1__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }




var Splitter = /*#__PURE__*/function () {
  function Splitter(isVertical, size, grabSize) {
    _classCallCheck(this, Splitter);

    this._isVertical = isVertical;
    this._size = size;
    this._grabSize = grabSize < size ? size : grabSize;
    this.element = this._createElement();
    this._dragListener = new _utils_DragListener__WEBPACK_IMPORTED_MODULE_0__["default"](this.element);
  }

  _createClass(Splitter, [{
    key: "on",
    value: function on(event, callback, context) {
      this._dragListener.on(event, callback, context);
    }
  }, {
    key: "_$destroy",
    value: function _$destroy() {
      this.element.remove();
    }
  }, {
    key: "_createElement",
    value: function _createElement() {
      var dragHandle = jquery__WEBPACK_IMPORTED_MODULE_1___default()('<div class="lm_drag_handle"></div>');
      var element = jquery__WEBPACK_IMPORTED_MODULE_1___default()('<div class="lm_splitter"></div>');
      element.append(dragHandle);
      var handleExcessSize = this._grabSize - this._size;
      var handleExcessPos = handleExcessSize / 2;

      if (this._isVertical) {
        dragHandle.css('top', -handleExcessPos);
        dragHandle.css('height', this._size + handleExcessSize);
        element.addClass('lm_vertical');
        element['height'](this._size);
      } else {
        dragHandle.css('left', -handleExcessPos);
        dragHandle.css('width', this._size + handleExcessSize);
        element.addClass('lm_horizontal');
        element['width'](this._size);
      }

      return element;
    }
  }]);

  return Splitter;
}();



/***/ }),

/***/ "./src/js_es6/controls/Tab.js":
/*!************************************!*\
  !*** ./src/js_es6/controls/Tab.js ***!
  \************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return Tab; });
/* harmony import */ var _utils_DragListener__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/DragListener */ "./src/js_es6/utils/DragListener.js");
/* harmony import */ var _controls_DragProxy__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../controls/DragProxy */ "./src/js_es6/controls/DragProxy.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_3__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }





/**
 * Represents an individual tab within a Stack's header
 *
 * @param {Header} header
 * @param {AbstractContentItem} contentItem
 *
 * @constructor
 */

var _template = '<li class="lm_tab"><i class="lm_left"></i>' + '<span class="lm_title"></span><div class="lm_close_tab"></div>' + '<i class="lm_right"></i></li>';

var Tab = /*#__PURE__*/function () {
  function Tab(header, contentItem) {
    _classCallCheck(this, Tab);

    this.header = header;
    this.contentItem = contentItem;
    this.element = jquery__WEBPACK_IMPORTED_MODULE_3___default()(_template);
    this.titleElement = this.element.find('.lm_title');
    this.closeElement = this.element.find('.lm_close_tab');
    this.closeElement[contentItem.config.isClosable ? 'show' : 'hide']();
    this.isActive = false;
    this.setTitle(contentItem.config.title);
    this.contentItem.on('titleChanged', this.setTitle, this);
    this._layoutManager = this.contentItem.layoutManager;

    if (this._layoutManager.config.settings.reorderEnabled === true && contentItem.config.reorderEnabled === true) {
      this._dragListener = new _utils_DragListener__WEBPACK_IMPORTED_MODULE_0__["default"](this.element);

      this._dragListener.on('dragStart', this._onDragStart, this);

      this.contentItem.on('destroy', this._dragListener.destroy, this._dragListener);
    }

    this._onTabClickFn = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["fnBind"])(this._onTabClick, this);
    this._onCloseClickFn = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["fnBind"])(this._onCloseClick, this);
    this.element.on('mousedown touchstart', this._onTabClickFn);

    if (this.contentItem.config.isClosable) {
      this.closeElement.on('click touchstart', this._onCloseClickFn);
      this.closeElement.on('mousedown', this._onCloseMousedown);
    } else {
      this.closeElement.remove();
    }

    this.contentItem.tab = this;
    this.contentItem.emit('tab', this);
    this.contentItem.layoutManager.emit('tabCreated', this);

    if (this.contentItem.isComponent) {
      this.contentItem.container.tab = this;
      this.contentItem.container.emit('tab', this);
    }
  }
  /**
   * Sets the tab's title to the provided string and sets
   * its title attribute to a pure text representation (without
   * html tags) of the same string.
   *
   * @public
   * @param {String} title can contain html
   */


  _createClass(Tab, [{
    key: "setTitle",
    value: function setTitle(title) {
      this.element.attr('title', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_2__["stripTags"])(title));
      this.titleElement.html(title);
    }
    /**
     * Sets this tab's active state. To programmatically
     * switch tabs, use header.setActiveContentItem( item ) instead.
     *
     * @public
     * @param {Boolean} isActive
     */

  }, {
    key: "setActive",
    value: function setActive(isActive) {
      if (isActive === this.isActive) {
        return;
      }

      this.isActive = isActive;

      if (isActive) {
        this.element.addClass('lm_active');
      } else {
        this.element.removeClass('lm_active');
      }
    }
    /**
     * Destroys the tab
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_$destroy",
    value: function _$destroy() {
      this.element.off('mousedown touchstart', this._onTabClickFn);
      this.closeElement.off('click touchstart', this._onCloseClickFn);

      if (this._dragListener) {
        this.contentItem.off('destroy', this._dragListener.destroy, this._dragListener);

        this._dragListener.off('dragStart', this._onDragStart);

        this._dragListener = null;
      }

      this.element.remove();
    }
    /**
     * Callback for the DragListener
     *
     * @param   {Number} x The tabs absolute x position
     * @param   {Number} y The tabs absolute y position
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_onDragStart",
    value: function _onDragStart(x, y) {
      if (!this.header._canDestroy) return null;

      if (this.contentItem.parent.isMaximised === true) {
        this.contentItem.parent.toggleMaximise();
      }

      new _controls_DragProxy__WEBPACK_IMPORTED_MODULE_1__["default"](x, y, this._dragListener, this._layoutManager, this.contentItem, this.header.parent);
    }
    /**
     * Callback when the tab is clicked
     *
     * @param {jQuery DOM event} event
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_onTabClick",
    value: function _onTabClick(event) {
      // left mouse button or tap
      if (event.button === 0 || event.type === 'touchstart') {
        this.header.parent.setActiveContentItem(this.contentItem); // middle mouse button
      } else if (event.button === 1 && this.contentItem.config.isClosable) {
        this._onCloseClick(event);
      }
    }
    /**
     * Callback when the tab's close button is
     * clicked
     *
     * @param   {jQuery DOM event} event
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_onCloseClick",
    value: function _onCloseClick(event) {
      event.stopPropagation();
      if (!this.header._canDestroy) return;
      this.header.parent.removeChild(this.contentItem);
    }
    /**
     * Callback to capture tab close button mousedown
     * to prevent tab from activating.
     *
     * @param (jQuery DOM event) event
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_onCloseMousedown",
    value: function _onCloseMousedown(event) {
      event.stopPropagation();
    }
  }]);

  return Tab;
}();



/***/ }),

/***/ "./src/js_es6/controls/TransitionIndicator.js":
/*!****************************************************!*\
  !*** ./src/js_es6/controls/TransitionIndicator.js ***!
  \****************************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return TransitionIndicator; });
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_1___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_1__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }




var TransitionIndicator = /*#__PURE__*/function () {
  function TransitionIndicator() {
    _classCallCheck(this, TransitionIndicator);

    this._element = jquery__WEBPACK_IMPORTED_MODULE_1___default()('<div class="lm_transition_indicator"></div>');
    jquery__WEBPACK_IMPORTED_MODULE_1___default()(document.body).append(this._element);
    this._toElement = null;
    this._fromDimensions = null;
    this._totalAnimationDuration = 200;
    this._animationStartTime = null;
  }

  _createClass(TransitionIndicator, [{
    key: "destroy",
    value: function destroy() {
      this._element.remove();
    }
  }, {
    key: "transitionElements",
    value: function transitionElements(fromElement, toElement) {
      /**
       * TODO - This is not quite as cool as expected. Review.
       */
      return; // this._toElement = toElement;
      // this._animationStartTime = now();
      // this._fromDimensions = this._measure(fromElement);
      // this._fromDimensions.opacity = 0.8;
      // this._element.show().css(this._fromDimensions);
      // animFrame(fnBind(this._nextAnimationFrame, this));
    }
  }, {
    key: "_nextAnimationFrame",
    value: function _nextAnimationFrame() {
      var toDimensions = this._measure(this._toElement),
          animationProgress = (Object(_utils_utils__WEBPACK_IMPORTED_MODULE_0__["now"])() - this._animationStartTime) / this._totalAnimationDuration,
          currentFrameStyles = {},
          cssProperty;

      if (animationProgress >= 1) {
        this._element.hide();

        return;
      }

      toDimensions.opacity = 0;

      for (cssProperty in this._fromDimensions) {
        currentFrameStyles[cssProperty] = this._fromDimensions[cssProperty] + (toDimensions[cssProperty] - this._fromDimensions[cssProperty]) * animationProgress;
      }

      this._element.css(currentFrameStyles);

      Object(_utils_utils__WEBPACK_IMPORTED_MODULE_0__["animFrame"])(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_0__["fnBind"])(this._nextAnimationFrame, this));
    }
  }, {
    key: "_measure",
    value: function _measure(element) {
      var offset = element.offset();
      return {
        left: offset.left,
        top: offset.top,
        width: element.outerWidth(),
        height: element.outerHeight()
      };
    }
  }]);

  return TransitionIndicator;
}();



/***/ }),

/***/ "./src/js_es6/errors/ConfigurationError.js":
/*!*************************************************!*\
  !*** ./src/js_es6/errors/ConfigurationError.js ***!
  \*************************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return ConfigurationError; });
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _wrapNativeSuper(Class) { var _cache = typeof Map === "function" ? new Map() : undefined; _wrapNativeSuper = function _wrapNativeSuper(Class) { if (Class === null || !_isNativeFunction(Class)) return Class; if (typeof Class !== "function") { throw new TypeError("Super expression must either be null or a function"); } if (typeof _cache !== "undefined") { if (_cache.has(Class)) return _cache.get(Class); _cache.set(Class, Wrapper); } function Wrapper() { return _construct(Class, arguments, _getPrototypeOf(this).constructor); } Wrapper.prototype = Object.create(Class.prototype, { constructor: { value: Wrapper, enumerable: false, writable: true, configurable: true } }); return _setPrototypeOf(Wrapper, Class); }; return _wrapNativeSuper(Class); }

function _construct(Parent, args, Class) { if (_isNativeReflectConstruct()) { _construct = Reflect.construct; } else { _construct = function _construct(Parent, args, Class) { var a = [null]; a.push.apply(a, args); var Constructor = Function.bind.apply(Parent, a); var instance = new Constructor(); if (Class) _setPrototypeOf(instance, Class.prototype); return instance; }; } return _construct.apply(null, arguments); }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _isNativeFunction(fn) { return Function.toString.call(fn).indexOf("[native code]") !== -1; }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }

var ConfigurationError = /*#__PURE__*/function (_Error) {
  _inherits(ConfigurationError, _Error);

  var _super = _createSuper(ConfigurationError);

  function ConfigurationError(message, node) {
    var _this;

    _classCallCheck(this, ConfigurationError);

    _this = _super.call(this);
    _this.name = 'Configuration Error';
    _this.message = message;
    _this.node = node;
    return _this;
  }

  return ConfigurationError;
}( /*#__PURE__*/_wrapNativeSuper(Error));



/***/ }),

/***/ "./src/js_es6/items/AbstractContentItem.js":
/*!*************************************************!*\
  !*** ./src/js_es6/items/AbstractContentItem.js ***!
  \*************************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return AbstractContentItem; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _utils_BubblingEvent__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../utils/BubblingEvent */ "./src/js_es6/utils/BubblingEvent.js");
/* harmony import */ var _Root__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ./Root */ "./src/js_es6/items/Root.js");
/* harmony import */ var _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../errors/ConfigurationError */ "./src/js_es6/errors/ConfigurationError.js");
/* harmony import */ var _config_ItemDefaultConfig__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! ../config/ItemDefaultConfig */ "./src/js_es6/config/ItemDefaultConfig.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_5__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }








/**
 * This is the baseclass that all content items inherit from.
 * Most methods provide a subset of what the sub-classes do.
 *
 * It also provides a number of functions for tree traversal
 *
 * @param {lm.LayoutManager} layoutManager
 * @param {item node configuration} config
 * @param {lm.item} parent
 *
 * @event stateChanged
 * @event beforeItemDestroyed
 * @event itemDestroyed
 * @event itemCreated
 * @event componentCreated
 * @event rowCreated
 * @event columnCreated
 * @event stackCreated
 *
 * @constructor
 */

var AbstractContentItem = /*#__PURE__*/function (_EventEmitter) {
  _inherits(AbstractContentItem, _EventEmitter);

  var _super = _createSuper(AbstractContentItem);

  function AbstractContentItem(layoutManager, config, parent) {
    var _this;

    _classCallCheck(this, AbstractContentItem);

    _this = _super.call(this);
    _this.config = _this._extendItemNode(config);
    _this.type = config.type;
    _this.contentItems = [];
    _this.parent = parent;
    _this.isInitialised = false;
    _this.isMaximised = false;
    _this.isRoot = false;
    _this.isRow = false;
    _this.isColumn = false;
    _this.isStack = false;
    _this.isComponent = false;
    _this.layoutManager = layoutManager;
    _this._pendingEventPropagations = {};
    _this._throttledEvents = ['stateChanged'];

    _this.on(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["ALL_EVENT"], _this._propagateEvent, _assertThisInitialized(_this));

    if (config.content) {
      _this._createContentItems(config);
    }

    return _this;
  }
  /**
   * Set the size of the component and its children, called recursively
   *
   * @abstract
   * @returns void
   */


  _createClass(AbstractContentItem, [{
    key: "setSize",
    value: function setSize() {
      throw new Error('Abstract Method');
    }
    /**
     * Calls a method recursively downwards on the tree
     *
     * @param   {String} functionName      the name of the function to be called
     * @param   {[Array]}functionArguments optional arguments that are passed to every function
     * @param   {[bool]} bottomUp          Call methods from bottom to top, defaults to false
     * @param   {[bool]} skipSelf          Don't invoke the method on the class that calls it, defaults to false
     *
     * @returns {void}
     */

  }, {
    key: "callDownwards",
    value: function callDownwards(functionName, functionArguments, bottomUp, skipSelf) {
      var i;

      if (bottomUp !== true && skipSelf !== true) {
        this[functionName].apply(this, functionArguments || []);
      }

      for (i = 0; i < this.contentItems.length; i++) {
        this.contentItems[i].callDownwards(functionName, functionArguments, bottomUp);
      }

      if (bottomUp === true && skipSelf !== true) {
        this[functionName].apply(this, functionArguments || []);
      }
    }
    /**
     * Removes a child node (and its children) from the tree
     *
     * @param   {ContentItem} contentItem
     *
     * @returns {void}
     */

  }, {
    key: "removeChild",
    value: function removeChild(contentItem, keepChild) {
      /*
       * Get the position of the item that's to be removed within all content items this node contains
       */
      var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(contentItem, this.contentItems);
      /*
       * Make sure the content item to be removed is actually a child of this item
       */

      if (index === -1) {
        throw new Error('Can\'t remove child item. Unknown content item');
      }
      /**
      * Call ._$destroy on the content item. 
      * Then use 'callDownwards' to destroy any children
      */


      if (keepChild !== true) {
        this.contentItems[index]._$destroy();

        this.contentItems[index].callDownwards('_$destroy', [], true, true);
      }
      /**
       * Remove the content item from this nodes array of children
       */


      this.contentItems.splice(index, 1);
      /**
       * Remove the item from the configuration
       */

      this.config.content.splice(index, 1);
      /**
       * If this node still contains other content items, adjust their size
       */

      if (this.contentItems.length > 0) {
        this.callDownwards('setSize');
        /**
         * If this was the last content item, remove this node as well
         */
      } else if (!(this instanceof _Root__WEBPACK_IMPORTED_MODULE_2__["default"]) && this.config.isClosable === true) {
        this.parent.removeChild(this);
      }
    }
    /**
     * Hides a child node (and its children) from the tree reclaiming its space in the layout
     *
     * @param   {ContentItem} contentItem
     *
     * @returns {void}
     */

  }, {
    key: "undisplayChild",
    value: function undisplayChild(contentItem) {
      /*
       * Get the position of the item that's to be removed within all content items this node contains
       */
      var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(contentItem, this.contentItems);
      /*
       * Make sure the content item to be removed is actually a child of this item
       */

      if (index === -1) {
        throw new Error('Can\'t remove child item. Unknown content item');
      }

      if (!(this instanceof _Root__WEBPACK_IMPORTED_MODULE_2__["default"]) && this.config.isClosable === true) {
        this.parent.undisplayChild(this);
      }
    }
    /**
     * Sets up the tree structure for the newly added child
     * The responsibility for the actual DOM manipulations lies
     * with the concrete item
     *
     * @param {AbstractContentItem} contentItem
     * @param {[Int]} index If omitted item will be appended
     */

  }, {
    key: "addChild",
    value: function addChild(contentItem, index) {
      if (index === undefined) {
        index = this.contentItems.length;
      }

      this.contentItems.splice(index, 0, contentItem);

      if (this.config.content === undefined) {
        this.config.content = [];
      }

      this.config.content.splice(index, 0, contentItem.config);
      contentItem.parent = this;

      if (contentItem.parent.isInitialised === true && contentItem.isInitialised === false) {
        contentItem._$init();
      }
    }
    /**
     * Replaces oldChild with newChild. This used to use jQuery.replaceWith... which for
     * some reason removes all event listeners, so isn't really an option.
     *
     * @param   {AbstractContentItem} oldChild
     * @param   {AbstractContentItem} newChild
     *
     * @returns {void}
     */

  }, {
    key: "replaceChild",
    value: function replaceChild(oldChild, newChild, _$destroyOldChild) {
      newChild = this.layoutManager._$normalizeContentItem(newChild);
      var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(oldChild, this.contentItems),
          parentNode = oldChild.element[0].parentNode;

      if (index === -1) {
        throw new Error('Can\'t replace child. oldChild is not child of this');
      }

      parentNode.replaceChild(newChild.element[0], oldChild.element[0]);
      /*
       * Optionally destroy the old content item
       */

      if (_$destroyOldChild === true) {
        oldChild.parent = null;

        oldChild._$destroy();
      }
      /*
       * Wire the new contentItem into the tree
       */


      this.contentItems[index] = newChild;
      newChild.parent = this;
      /*
       * Update tab reference
       */

      if (this.isStack) {
        this.header.tabs[index].contentItem = newChild;
      } //TODO This doesn't update the config... refactor to leave item nodes untouched after creation


      if (newChild.parent.isInitialised === true && newChild.isInitialised === false) {
        newChild._$init();
      }

      this.callDownwards('setSize');
    }
    /**
     * Convenience method.
     * Shorthand for this.parent.removeChild( this )
     *
     * @returns {void}
     */

  }, {
    key: "remove",
    value: function remove() {
      this.parent.removeChild(this);
    }
    /**
     * Removes the component from the layout and creates a new
     * browser window with the component and its children inside
     *
     * @returns {BrowserPopout}
     */

  }, {
    key: "popout",
    value: function popout() {
      var browserPopout = this.layoutManager.createPopout(this);
      this.emitBubblingEvent('stateChanged');
      return browserPopout;
    }
    /**
     * Maximises the Item or minimises it if it is already maximised
     *
     * @returns {void}
     */

  }, {
    key: "toggleMaximise",
    value: function toggleMaximise(e) {
      e && e.preventDefault();

      if (this.isMaximised === true) {
        this.layoutManager._$minimiseItem(this);
      } else {
        this.layoutManager._$maximiseItem(this);
      }

      this.isMaximised = !this.isMaximised;
      this.emitBubblingEvent('stateChanged');
    }
    /**
     * Selects the item if it is not already selected
     *
     * @returns {void}
     */

  }, {
    key: "select",
    value: function select() {
      if (this.layoutManager.selectedItem !== this) {
        this.layoutManager.selectItem(this, true);
        this.element.addClass('lm_selected');
      }
    }
    /**
     * De-selects the item if it is selected
     *
     * @returns {void}
     */

  }, {
    key: "deselect",
    value: function deselect() {
      if (this.layoutManager.selectedItem === this) {
        this.layoutManager.selectedItem = null;
        this.element.removeClass('lm_selected');
      }
    }
    /**
     * Set this component's title
     *
     * @public
     * @param {String} title
     *
     * @returns {void}
     */

  }, {
    key: "setTitle",
    value: function setTitle(title) {
      this.config.title = title;
      this.emit('titleChanged', title);
      this.emit('stateChanged');
    }
    /**
     * Checks whether a provided id is present
     *
     * @public
     * @param   {String}  id
     *
     * @returns {Boolean} isPresent
     */

  }, {
    key: "hasId",
    value: function hasId(id) {
      if (!this.config.id) {
        return false;
      } else if (typeof this.config.id === 'string') {
        return this.config.id === id;
      } else if (this.config.id instanceof Array) {
        return Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(id, this.config.id) !== -1;
      }
    }
    /**
     * Adds an id. Adds it as a string if the component doesn't
     * have an id yet or creates/uses an array
     *
     * @public
     * @param {String} id
     *
     * @returns {void}
     */

  }, {
    key: "addId",
    value: function addId(id) {
      if (this.hasId(id)) {
        return;
      }

      if (!this.config.id) {
        this.config.id = id;
      } else if (typeof this.config.id === 'string') {
        this.config.id = [this.config.id, id];
      } else if (this.config.id instanceof Array) {
        this.config.id.push(id);
      }
    }
    /**
     * Removes an existing id. Throws an error
     * if the id is not present
     *
     * @public
     * @param   {String} id
     *
     * @returns {void}
     */

  }, {
    key: "removeId",
    value: function removeId(id) {
      if (!this.hasId(id)) {
        throw new Error('Id not found');
      }

      if (typeof this.config.id === 'string') {
        delete this.config.id;
      } else if (this.config.id instanceof Array) {
        var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(id, this.config.id);
        this.config.id.splice(index, 1);
      }
    }
    /****************************************
     * SELECTOR
     ****************************************/

  }, {
    key: "getItemsByFilter",
    value: function getItemsByFilter(filter) {
      var result = [],
          next = function next(contentItem) {
        for (var i = 0; i < contentItem.contentItems.length; i++) {
          if (filter(contentItem.contentItems[i]) === true) {
            result.push(contentItem.contentItems[i]);
          }

          next(contentItem.contentItems[i]);
        }
      };

      next(this);
      return result;
    }
  }, {
    key: "getItemsById",
    value: function getItemsById(id) {
      return this.getItemsByFilter(function (item) {
        if (item.config.id instanceof Array) {
          return Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(id, item.config.id) !== -1;
        } else {
          return item.config.id === id;
        }
      });
    }
  }, {
    key: "getItemsByType",
    value: function getItemsByType(type) {
      return this._$getItemsByProperty('type', type);
    }
  }, {
    key: "getComponentsByName",
    value: function getComponentsByName(componentName) {
      var components = this._$getItemsByProperty('componentName', componentName),
          instances = [],
          i;

      for (i = 0; i < components.length; i++) {
        instances.push(components[i].instance);
      }

      return instances;
    }
    /****************************************
     * PACKAGE PRIVATE
     ****************************************/

  }, {
    key: "_$getItemsByProperty",
    value: function _$getItemsByProperty(key, value) {
      return this.getItemsByFilter(function (item) {
        return item[key] === value;
      });
    }
  }, {
    key: "_$setParent",
    value: function _$setParent(parent) {
      this.parent = parent;
    }
  }, {
    key: "_$highlightDropZone",
    value: function _$highlightDropZone(x, y, area) {
      this.layoutManager.dropTargetIndicator.highlightArea(area);
    }
  }, {
    key: "_$onDrop",
    value: function _$onDrop(contentItem) {
      this.addChild(contentItem);
    }
  }, {
    key: "_$hide",
    value: function _$hide() {
      this._callOnActiveComponents('hide');

      this.element.hide();
      this.layoutManager.updateSize();
    }
  }, {
    key: "_$show",
    value: function _$show() {
      this._callOnActiveComponents('show');

      this.element.show();
      this.layoutManager.updateSize();
    }
  }, {
    key: "_callOnActiveComponents",
    value: function _callOnActiveComponents(methodName) {
      var stacks = this.getItemsByType('stack'),
          activeContentItem,
          i;

      for (i = 0; i < stacks.length; i++) {
        activeContentItem = stacks[i].getActiveContentItem();

        if (activeContentItem && activeContentItem.isComponent) {
          activeContentItem.container[methodName]();
        }
      }
    }
    /**
     * Destroys this item ands its children
     *
     * @returns {void}
     */

  }, {
    key: "_$destroy",
    value: function _$destroy() {
      this.emitBubblingEvent('beforeItemDestroyed');
      this.element.remove();
      this.emitBubblingEvent('itemDestroyed');
    }
    /**
     * Returns the area the component currently occupies in the format
     *
     * {
     *		x1: int
     *		xy: int
     *		y1: int
     *		y2: int
     *		contentItem: contentItem
     * }
     */

  }, {
    key: "_$getArea",
    value: function _$getArea(element) {
      element = element || this.element;
      var offset = element.offset(),
          width = element.width(),
          height = element.height();
      return {
        x1: offset.left,
        y1: offset.top,
        x2: offset.left + width,
        y2: offset.top + height,
        surface: width * height,
        contentItem: this
      };
    }
    /**
     * The tree of content items is created in two steps: First all content items are instantiated,
     * then init is called recursively from top to bottem. This is the basic init function,
     * it can be used, extended or overwritten by the content items
     *
     * Its behaviour depends on the content item
     *
     * @package private
     *
     * @returns {void}
     */

  }, {
    key: "_$init",
    value: function _$init() {
      var i;
      this.setSize();

      for (i = 0; i < this.contentItems.length; i++) {
        this.childElementContainer.append(this.contentItems[i].element);
      }

      this.isInitialised = true;
      this.emitBubblingEvent('itemCreated');
      this.emitBubblingEvent(this.type + 'Created');
    }
    /**
     * Emit an event that bubbles up the item tree.
     *
     * @param   {String} name The name of the event
     *
     * @returns {void}
     */

  }, {
    key: "emitBubblingEvent",
    value: function emitBubblingEvent(name) {
      var event = new _utils_BubblingEvent__WEBPACK_IMPORTED_MODULE_1__["default"](name, this);
      this.emit(name, event);
    }
    /**
     * Private method, creates all content items for this node at initialisation time
     * PLEASE NOTE, please see addChild for adding contentItems add runtime
     * @private
     * @param   {configuration item node} config
     *
     * @returns {void}
     */

  }, {
    key: "_createContentItems",
    value: function _createContentItems(config) {
      var oContentItem, i;

      if (!(config.content instanceof Array)) {
        throw new _errors_ConfigurationError__WEBPACK_IMPORTED_MODULE_3__["default"]('content must be an Array', config);
      }

      for (i = 0; i < config.content.length; i++) {
        oContentItem = this.layoutManager.createContentItem(config.content[i], this);
        this.contentItems.push(oContentItem);
      }
    }
    /**
     * Extends an item configuration node with default settings
     * @private
     * @param   {configuration item node} config
     *
     * @returns {configuration item node} extended config
     */

  }, {
    key: "_extendItemNode",
    value: function _extendItemNode(config) {
      for (var key in _config_ItemDefaultConfig__WEBPACK_IMPORTED_MODULE_4__["default"]) {
        if (config[key] === undefined) {
          config[key] = _config_ItemDefaultConfig__WEBPACK_IMPORTED_MODULE_4__["default"][key];
        }
      }

      return config;
    }
    /**
     * Called for every event on the item tree. Decides whether the event is a bubbling
     * event and propagates it to its parent
     *
     * @param    {String} name the name of the event
     * @param   {BubblingEvent} event
     *
     * @returns {void}
     */

  }, {
    key: "_propagateEvent",
    value: function _propagateEvent(name, event) {
      if (event instanceof _utils_BubblingEvent__WEBPACK_IMPORTED_MODULE_1__["default"] && event.isPropagationStopped === false && this.isInitialised === true) {
        /**
         * In some cases (e.g. if an element is created from a DragSource) it
         * doesn't have a parent and is not below root. If that's the case
         * propagate the bubbling event from the top level of the substree directly
         * to the layoutManager
         */
        if (this.isRoot === false && this.parent) {
          this.parent.emit.apply(this.parent, Array.prototype.slice.call(arguments, 0));
        } else {
          this._scheduleEventPropagationToLayoutManager(name, event);
        }
      }
    }
    /**
     * All raw events bubble up to the root element. Some events that
     * are propagated to - and emitted by - the layoutManager however are
     * only string-based, batched and sanitized to make them more usable
     *
     * @param {String} name the name of the event
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_scheduleEventPropagationToLayoutManager",
    value: function _scheduleEventPropagationToLayoutManager(name, event) {
      if (Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["indexOf"])(name, this._throttledEvents) === -1) {
        this.layoutManager.emit(name, event.origin);
      } else {
        if (this._pendingEventPropagations[name] !== true) {
          this._pendingEventPropagations[name] = true;
          Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["animFrame"])(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_5__["fnBind"])(this._propagateEventToLayoutManager, this, [name, event]));
        }
      }
    }
    /**
     * Callback for events scheduled by _scheduleEventPropagationToLayoutManager
     *
     * @param {String} name the name of the event
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_propagateEventToLayoutManager",
    value: function _propagateEventToLayoutManager(name, event) {
      this._pendingEventPropagations[name] = false;
      this.layoutManager.emit(name, event);
    }
  }]);

  return AbstractContentItem;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/items/Component.js":
/*!***************************************!*\
  !*** ./src/js_es6/items/Component.js ***!
  \***************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return Component; });
/* harmony import */ var _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../items/AbstractContentItem */ "./src/js_es6/items/AbstractContentItem.js");
/* harmony import */ var _container_ItemContainer__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../container/ItemContainer */ "./src/js_es6/container/ItemContainer.js");
/* harmony import */ var _utils_ReactComponentHandler__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../utils/ReactComponentHandler */ "./src/js_es6/utils/ReactComponentHandler.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_3___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_3__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }





/**
 * @param {[type]} layoutManager [description]
 * @param {[type]} config      [description]
 * @param {[type]} parent        [description]
 */

var Component = /*#__PURE__*/function (_AbstractContentItem) {
  _inherits(Component, _AbstractContentItem);

  var _super = _createSuper(Component);

  function Component(layoutManager, config, parent) {
    var _this;

    _classCallCheck(this, Component);

    _this = _super.call(this, layoutManager, config, parent);
    var ComponentConstructor = layoutManager.isReactConfig(config) ? _utils_ReactComponentHandler__WEBPACK_IMPORTED_MODULE_2__["default"] : layoutManager.getComponent(config),
        componentConfig = jquery__WEBPACK_IMPORTED_MODULE_3___default.a.extend(true, {}, _this.config.componentState || {});
    componentConfig.componentName = _this.config.componentName;
    _this.componentName = _this.config.componentName;

    if (_this.config.title === '') {
      _this.config.title = _this.config.componentName;
    }

    _this.isComponent = true;
    _this.container = new _container_ItemContainer__WEBPACK_IMPORTED_MODULE_1__["default"](_this.config, _assertThisInitialized(_this), layoutManager);
    _this.instance = new ComponentConstructor(_this.container, componentConfig);
    _this.element = _this.container._element;
    return _this;
  }

  _createClass(Component, [{
    key: "close",
    value: function close() {
      this.parent.removeChild(this);
    }
  }, {
    key: "setSize",
    value: function setSize() {
      if (this.element.css('display') !== 'none') {
        // Do not update size of hidden components to prevent unwanted reflows
        this.container._$setSize(this.element.width(), this.element.height());
      }
    }
  }, {
    key: "_$init",
    value: function _$init() {
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$init.call(this);

      this.container.emit('open');
    }
  }, {
    key: "_$hide",
    value: function _$hide() {
      this.container.hide();

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$hide.call(this);
    }
  }, {
    key: "_$show",
    value: function _$show() {
      this.container.show();

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$show.call(this);
    }
  }, {
    key: "_$shown",
    value: function _$shown() {
      this.container.shown();

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$shown.call(this);
    }
  }, {
    key: "_$destroy",
    value: function _$destroy() {
      this.container.emit('destroy', this);

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$destroy.call(this);
    }
    /**
     * Dragging onto a component directly is not an option
     *
     * @returns null
     */

  }, {
    key: "_$getArea",
    value: function _$getArea() {
      return null;
    }
  }]);

  return Component;
}(_items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/items/Root.js":
/*!**********************************!*\
  !*** ./src/js_es6/items/Root.js ***!
  \**********************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return Root; });
/* harmony import */ var _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../items/AbstractContentItem */ "./src/js_es6/items/AbstractContentItem.js");
/* harmony import */ var _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../items/RowOrColumn */ "./src/js_es6/items/RowOrColumn.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_2__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }





var Root = /*#__PURE__*/function (_AbstractContentItem) {
  _inherits(Root, _AbstractContentItem);

  var _super = _createSuper(Root);

  function Root(layoutManager, config, containerElement) {
    var _this;

    _classCallCheck(this, Root);

    _this = _super.call(this, layoutManager, config, null);
    _this.isRoot = true;
    _this.type = 'root';
    _this.element = jquery__WEBPACK_IMPORTED_MODULE_2___default()('<div class="lm_goldenlayout lm_item lm_root"></div>');
    _this.childElementContainer = _this.element;
    _this._containerElement = containerElement;

    _this._containerElement.append(_this.element);

    return _this;
  }

  _createClass(Root, [{
    key: "addChild",
    value: function addChild(contentItem) {
      if (this.contentItems.length > 0) {
        throw new Error('Root node can only have a single child');
      }

      contentItem = this.layoutManager._$normalizeContentItem(contentItem, this);
      this.childElementContainer.append(contentItem.element);
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.addChild.call(this, contentItem);
      this.callDownwards('setSize');
      this.emitBubblingEvent('stateChanged');
    }
  }, {
    key: "setSize",
    value: function setSize(width, height) {
      width = typeof width === 'undefined' ? this._containerElement.width() : width;
      height = typeof height === 'undefined' ? this._containerElement.height() : height;
      this.element.width(width);
      this.element.height(height);
      /*
       * Root can be empty
       */

      if (this.contentItems[0]) {
        this.contentItems[0].element.width(width);
        this.contentItems[0].element.height(height);
      }
    }
  }, {
    key: "_$highlightDropZone",
    value: function _$highlightDropZone(x, y, area) {
      this.layoutManager.tabDropPlaceholder.remove();

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$highlightDropZone.apply(this, arguments);
    }
  }, {
    key: "_$onDrop",
    value: function _$onDrop(contentItem, area) {
      var stack;

      if (contentItem.isComponent) {
        stack = this.layoutManager.createContentItem({
          type: 'stack',
          header: contentItem.config.header || {}
        }, this);

        stack._$init();

        stack.addChild(contentItem);
        contentItem = stack;
      }

      if (!this.contentItems.length) {
        this.addChild(contentItem);
      } else {
        /*
         * If the contentItem that's being dropped is not dropped on a Stack (cases which just passed above and 
         * which would wrap the contentItem in a Stack) we need to check whether contentItem is a RowOrColumn.
         * If it is, we need to re-wrap it in a Stack like it was when it was dragged by its Tab (it was dragged!).
         */
        if (contentItem.config.type === 'row' || contentItem.config.type === 'column') {
          stack = this.layoutManager.createContentItem({
            type: 'stack'
          }, this);
          stack.addChild(contentItem);
          contentItem = stack;
        }

        var type = area.side[0] == 'x' ? 'row' : 'column';
        var dimension = area.side[0] == 'x' ? 'width' : 'height';
        var insertBefore = area.side[1] == '2';
        var column = this.contentItems[0];

        if (!(column instanceof _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__["default"]) || column.type != type) {
          var rowOrColumn = this.layoutManager.createContentItem({
            type: type
          }, this);
          this.replaceChild(column, rowOrColumn);
          rowOrColumn.addChild(contentItem, insertBefore ? 0 : undefined, true);
          rowOrColumn.addChild(column, insertBefore ? undefined : 0, true);
          column.config[dimension] = 50;
          contentItem.config[dimension] = 50;
          rowOrColumn.callDownwards('setSize');
        } else {
          var sibbling = column.contentItems[insertBefore ? 0 : column.contentItems.length - 1];
          column.addChild(contentItem, insertBefore ? 0 : undefined, true);
          sibbling.config[dimension] *= 0.5;
          contentItem.config[dimension] = sibbling.config[dimension];
          column.callDownwards('setSize');
        }
      }
    }
  }]);

  return Root;
}(_items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/items/RowOrColumn.js":
/*!*****************************************!*\
  !*** ./src/js_es6/items/RowOrColumn.js ***!
  \*****************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return RowOrColumn; });
/* harmony import */ var _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../items/AbstractContentItem */ "./src/js_es6/items/AbstractContentItem.js");
/* harmony import */ var _items_Stack__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../items/Stack */ "./src/js_es6/items/Stack.js");
/* harmony import */ var _controls_Splitter__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../controls/Splitter */ "./src/js_es6/controls/Splitter.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_4___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_4__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }







var RowOrColumn = /*#__PURE__*/function (_AbstractContentItem) {
  _inherits(RowOrColumn, _AbstractContentItem);

  var _super = _createSuper(RowOrColumn);

  function RowOrColumn(isColumn, layoutManager, config, parent) {
    var _this;

    _classCallCheck(this, RowOrColumn);

    _this = _super.call(this, layoutManager, config, parent);
    _this.isRow = !isColumn;
    _this.isColumn = isColumn;
    _this.element = jquery__WEBPACK_IMPORTED_MODULE_4___default()('<div class="lm_item lm_' + (isColumn ? 'column' : 'row') + '"></div>');
    _this.childElementContainer = _this.element;
    _this._splitterSize = layoutManager.config.dimensions.borderWidth;
    _this._splitterGrabSize = layoutManager.config.dimensions.borderGrabWidth;
    _this._isColumn = isColumn;
    _this._dimension = isColumn ? 'height' : 'width';
    _this._splitter = [];
    _this._splitterPosition = null;
    _this._splitterMinPosition = null;
    _this._splitterMaxPosition = null;
    return _this;
  }
  /**
   * Add a new contentItem to the Row or Column
   *
   * @param {AbstractContentItem} contentItem
   * @param {[int]} index The position of the new item within the Row or Column.
   *                      If no index is provided the item will be added to the end
   * @param {[bool]} _$suspendResize If true the items won't be resized. This will leave the item in
   *                                 an inconsistent state and is only intended to be used if multiple
   *                                 children need to be added in one go and resize is called afterwards
   *
   * @returns {void}
   */


  _createClass(RowOrColumn, [{
    key: "addChild",
    value: function addChild(contentItem, index, _$suspendResize) {
      var newItemSize, itemSize, i, splitterElement;
      contentItem = this.layoutManager._$normalizeContentItem(contentItem, this);

      if (index === undefined) {
        index = this.contentItems.length;
      }

      if (this.contentItems.length > 0) {
        splitterElement = this._createSplitter(Math.max(0, index - 1)).element;

        if (index > 0) {
          this.contentItems[index - 1].element.after(splitterElement);
          splitterElement.after(contentItem.element);

          if (this._isDocked(index - 1)) {
            this._splitter[index - 1].element.hide();

            this._splitter[index].element.show();
          }
        } else {
          this.contentItems[0].element.before(splitterElement);
          splitterElement.before(contentItem.element);
        }
      } else {
        this.childElementContainer.append(contentItem.element);
      }

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.addChild.call(this, contentItem, index);
      newItemSize = 1 / this.contentItems.length * 100;

      if (_$suspendResize === true) {
        this.emitBubblingEvent('stateChanged');
        return;
      }

      for (i = 0; i < this.contentItems.length; i++) {
        if (this.contentItems[i] === contentItem) {
          contentItem.config[this._dimension] = newItemSize;
        } else {
          itemSize = this.contentItems[i].config[this._dimension] *= (100 - newItemSize) / 100;
          this.contentItems[i].config[this._dimension] = itemSize;
        }
      }

      this.callDownwards('setSize');
      this.emitBubblingEvent('stateChanged');

      this._validateDocking();
    }
    /**
     * Undisplays a child of this element
     *
     * @param   {AbstractContentItem} contentItem
     *
     * @returns {void}
     */

  }, {
    key: "undisplayChild",
    value: function undisplayChild(contentItem) {
      var undisplayedItemSize = contentItem.config[this._dimension],
          index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(contentItem, this.contentItems),
          splitterIndex = Math.max(index - 1, 0),
          i,
          childItem;

      if (index === -1) {
        throw new Error('Can\'t undisplay child. ContentItem is not child of this Row or Column');
      }
      /**
       * Hide the splitter before the item or after if the item happens
       * to be the first in the row/column
       */


      if (this._splitter[splitterIndex]) {
        this._splitter[splitterIndex].element.hide();
      }

      if (splitterIndex < this._splitter.length) {
        if (this._isDocked(splitterIndex)) this._splitter[splitterIndex].element.hide();
      }
      /**
       * Allocate the space that the hidden item occupied to the remaining items
       */


      var docked = this._isDocked();

      for (i = 0; i < this.contentItems.length; i++) {
        if (this.contentItems[i] !== contentItem) {
          if (!this._isDocked(i)) this.contentItems[i].config[this._dimension] += undisplayedItemSize / (this.contentItems.length - 1 - docked);
        } else {
          this.contentItems[i].config[this._dimension] = 0;
        }
      }

      if (this.contentItems.length === 1) {
        _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.undisplayChild.call(this, contentItem);
      }

      this.callDownwards('setSize');
      this.emitBubblingEvent('stateChanged');
    }
    /**
     * Removes a child of this element
     *
     * @param   {AbstractContentItem} contentItem
     * @param   {boolean} keepChild   If true the child will be removed, but not destroyed
     *
     * @returns {void}
     */

  }, {
    key: "removeChild",
    value: function removeChild(contentItem, keepChild) {
      var removedItemSize = contentItem.config[this._dimension],
          index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(contentItem, this.contentItems),
          splitterIndex = Math.max(index - 1, 0),
          i,
          childItem;

      if (index === -1) {
        throw new Error('Can\'t remove child. ContentItem is not child of this Row or Column');
      }
      /**
       * Remove the splitter before the item or after if the item happens
       * to be the first in the row/column
       */


      if (this._splitter[splitterIndex]) {
        this._splitter[splitterIndex]._$destroy();

        this._splitter.splice(splitterIndex, 1);
      }

      if (splitterIndex < this._splitter.length) {
        if (this._isDocked(splitterIndex)) this._splitter[splitterIndex].element.hide();
      }
      /**
       * Allocate the space that the removed item occupied to the remaining items
       */


      var docked = this._isDocked();

      for (i = 0; i < this.contentItems.length; i++) {
        if (this.contentItems[i] !== contentItem) {
          if (!this._isDocked(i)) this.contentItems[i].config[this._dimension] += removedItemSize / (this.contentItems.length - 1 - docked);
        }
      }

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.removeChild.call(this, contentItem, keepChild);

      if (this.contentItems.length === 1 && this.config.isClosable === true) {
        childItem = this.contentItems[0];
        this.contentItems = [];
        this.parent.replaceChild(this, childItem, true);

        this._validateDocking(this.parent);
      } else {
        this.callDownwards('setSize');
        this.emitBubblingEvent('stateChanged');

        this._validateDocking();
      }
    }
    /**
     * Replaces a child of this Row or Column with another contentItem
     *
     * @param   {AbstractContentItem} oldChild
     * @param   {AbstractContentItem} newChild
     *
     * @returns {void}
     */

  }, {
    key: "replaceChild",
    value: function replaceChild(oldChild, newChild) {
      var size = oldChild.config[this._dimension];
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.replaceChild.call(this, oldChild, newChild);
      newChild.config[this._dimension] = size;
      this.callDownwards('setSize');
      this.emitBubblingEvent('stateChanged');
    }
    /**
     * Called whenever the dimensions of this item or one of its parents change
     *
     * @returns {void}
     */

  }, {
    key: "setSize",
    value: function setSize() {
      if (this.contentItems.length > 0) {
        this._calculateRelativeSizes();

        this._setAbsoluteSizes();
      }

      this.emitBubblingEvent('stateChanged');
      this.emit('resize');
    }
    /**
     * Dock or undock a child if it posiible
     *
     * @param   {AbstractContentItem} contentItem
     * @param   {Boolean} mode or toggle if undefined
     * @param   {Boolean} collapsed after docking
     *
     * @returns {void}
     */

  }, {
    key: "dock",
    value: function dock(contentItem, mode, collapsed) {
      if (this.contentItems.length === 1) throw new Error('Can\'t dock child when it single');
      var removedItemSize = contentItem.config[this._dimension],
          headerSize = this.layoutManager.config.dimensions.headerHeight,
          index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(contentItem, this.contentItems),
          splitterIndex = Math.max(index - 1, 0);

      if (index === -1) {
        throw new Error('Can\'t dock child. ContentItem is not child of this Row or Column');
      }

      var isDocked = contentItem._docker && contentItem._docker.docked;
      var i;
      if (typeof mode != 'undefined') if (mode == isDocked) return;

      if (isDocked) {
        // undock it
        this._splitter[splitterIndex].element.show();

        for (i = 0; i < this.contentItems.length; i++) {
          var newItemSize = contentItem._docker.size;

          if (this.contentItems[i] === contentItem) {
            contentItem.config[this._dimension] = newItemSize;
          } else {
            itemSize = this.contentItems[i].config[this._dimension] *= (100 - newItemSize) / 100;
            this.contentItems[i].config[this._dimension] = itemSize;
          }
        }

        contentItem._docker = {
          docked: false
        };
      } else {
        // dock
        if (this.contentItems.length - this._isDocked() < 2) throw new Error('Can\'t dock child when it is last in ' + this.config.type);
        var autoside = {
          column: {
            first: 'top',
            last: 'bottom'
          },
          row: {
            first: 'left',
            last: 'right'
          }
        };
        var required = autoside[this.config.type][index ? 'last' : 'first'];
        if (contentItem.header.position() != required) contentItem.header.position(required);

        if (this._splitter[splitterIndex]) {
          this._splitter[splitterIndex].element.hide();
        }

        var docked = this._isDocked();

        for (i = 0; i < this.contentItems.length; i++) {
          if (this.contentItems[i] !== contentItem) {
            if (!this._isDocked(i)) this.contentItems[i].config[this._dimension] += removedItemSize / (this.contentItems.length - 1 - docked);
          } else this.contentItems[i].config[this._dimension] = 0;
        }

        contentItem._docker = {
          dimension: this._dimension,
          size: removedItemSize,
          realSize: contentItem.element[this._dimension]() - headerSize,
          docked: true
        };
        if (collapsed) contentItem.childElementContainer[this._dimension](0);
      }

      contentItem.element.toggleClass('lm_docked', contentItem._docker.docked);
      this.callDownwards('setSize');
      this.emitBubblingEvent('stateChanged');

      this._validateDocking();
    }
    /**
     * Invoked recursively by the layout manager. AbstractContentItem.init appends
     * the contentItem's DOM elements to the container, RowOrColumn init adds splitters
     * in between them
     *
     * @package private
     * @override AbstractContentItem._$init
     * @returns {void}
     */

  }, {
    key: "_$init",
    value: function _$init() {
      if (this.isInitialised === true) return;
      var i;

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$init.call(this);

      for (i = 0; i < this.contentItems.length - 1; i++) {
        this.contentItems[i].element.after(this._createSplitter(i).element);
      }

      for (i = 0; i < this.contentItems.length; i++) {
        if (this.contentItems[i]._header && this.contentItems[i]._header.docked) this.dock(this.contentItems[i], true, true);
      }
    }
    /**
     * Turns the relative sizes calculated by _calculateRelativeSizes into
     * absolute pixel values and applies them to the children's DOM elements
     *
     * Assigns additional pixels to counteract Math.floor
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_setAbsoluteSizes",
    value: function _setAbsoluteSizes() {
      var i,
          sizeData = this._calculateAbsoluteSizes();

      for (i = 0; i < this.contentItems.length; i++) {
        if (sizeData.additionalPixel - i > 0) {
          sizeData.itemSizes[i]++;
        }

        if (this._isColumn) {
          this.contentItems[i].element.width(sizeData.totalWidth);
          this.contentItems[i].element.height(sizeData.itemSizes[i]);
        } else {
          this.contentItems[i].element.width(sizeData.itemSizes[i]);
          this.contentItems[i].element.height(sizeData.totalHeight);
        }
      }
    }
    /**
     * Calculates the absolute sizes of all of the children of this Item.
     * @returns {object} - Set with absolute sizes and additional pixels.
     */

  }, {
    key: "_calculateAbsoluteSizes",
    value: function _calculateAbsoluteSizes() {
      var i,
          totalSplitterSize = (this.contentItems.length - 1) * this._splitterSize,
          headerSize = this.layoutManager.config.dimensions.headerHeight,
          totalWidth = this.element.width(),
          totalHeight = this.element.height(),
          totalAssigned = 0,
          additionalPixel,
          itemSize,
          itemSizes = [];

      if (this._isColumn) {
        totalHeight -= totalSplitterSize;
      } else {
        totalWidth -= totalSplitterSize;
      }

      for (i = 0; i < this.contentItems.length; i++) {
        if (this._isDocked(i)) if (this._isColumn) {
          totalHeight -= headerSize - this._splitterSize;
        } else {
          totalWidth -= headerSize - this._splitterSize;
        }
      }

      for (i = 0; i < this.contentItems.length; i++) {
        if (this._isColumn) {
          itemSize = Math.floor(totalHeight * (this.contentItems[i].config.height / 100));
        } else {
          itemSize = Math.floor(totalWidth * (this.contentItems[i].config.width / 100));
        }

        if (this._isDocked(i)) itemSize = headerSize;
        totalAssigned += itemSize;
        itemSizes.push(itemSize);
      }

      additionalPixel = Math.floor((this._isColumn ? totalHeight : totalWidth) - totalAssigned);
      return {
        itemSizes: itemSizes,
        additionalPixel: additionalPixel,
        totalWidth: totalWidth,
        totalHeight: totalHeight
      };
    }
    /**
     * Calculates the relative sizes of all children of this Item. The logic
     * is as follows:
     *
     * - Add up the total size of all items that have a configured size
     *
     * - If the total == 100 (check for floating point errors)
     *        Excellent, job done
     *
     * - If the total is > 100,
     *        set the size of items without set dimensions to 1/3 and add this to the total
     *        set the size off all items so that the total is hundred relative to their original size
     *
     * - If the total is < 100
     *        If there are items without set dimensions, distribute the remainder to 100 evenly between them
     *        If there are no items without set dimensions, increase all items sizes relative to
     *        their original size so that they add up to 100
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_calculateRelativeSizes",
    value: function _calculateRelativeSizes() {
      var i,
          total = 0,
          itemsWithoutSetDimension = [],
          dimension = this._isColumn ? 'height' : 'width';

      for (i = 0; i < this.contentItems.length; i++) {
        if (this.contentItems[i].config[dimension] !== undefined) {
          total += this.contentItems[i].config[dimension];
        } else {
          itemsWithoutSetDimension.push(this.contentItems[i]);
        }
      }
      /**
       * Everything adds up to hundred, all good :-)
       */


      if (Math.round(total) === 100) {
        this._respectMinItemWidth();

        return;
      }
      /**
       * Allocate the remaining size to the items without a set dimension
       */


      if (Math.round(total) < 100 && itemsWithoutSetDimension.length > 0) {
        for (i = 0; i < itemsWithoutSetDimension.length; i++) {
          itemsWithoutSetDimension[i].config[dimension] = (100 - total) / itemsWithoutSetDimension.length;
        }

        this._respectMinItemWidth();

        return;
      }
      /**
       * If the total is > 100, but there are also items without a set dimension left, assing 50
       * as their dimension and add it to the total
       *
       * This will be reset in the next step
       */


      if (Math.round(total) > 100) {
        for (i = 0; i < itemsWithoutSetDimension.length; i++) {
          itemsWithoutSetDimension[i].config[dimension] = 50;
          total += 50;
        }
      }
      /**
       * Set every items size relative to 100 relative to its size to total
       */


      for (i = 0; i < this.contentItems.length; i++) {
        this.contentItems[i].config[dimension] = this.contentItems[i].config[dimension] / total * 100;
      }

      this._respectMinItemWidth();
    }
    /**
     * Adjusts the column widths to respect the dimensions minItemWidth if set.
     * @returns {}
     */

  }, {
    key: "_respectMinItemWidth",
    value: function _respectMinItemWidth() {
      var minItemWidth = this.layoutManager.config.dimensions ? this.layoutManager.config.dimensions.minItemWidth || 0 : 0,
          sizeData = null,
          entriesOverMin = [],
          totalOverMin = 0,
          totalUnderMin = 0,
          remainingWidth = 0,
          itemSize = 0,
          contentItem = null,
          reducePercent,
          reducedWidth,
          allEntries = [],
          entry;

      if (this._isColumn || !minItemWidth || this.contentItems.length <= 1) {
        return;
      }

      sizeData = this._calculateAbsoluteSizes();
      /**
       * Figure out how much we are under the min item size total and how much room we have to use.
       */

      for (var i = 0; i < this.contentItems.length; i++) {
        contentItem = this.contentItems[i];
        itemSize = sizeData.itemSizes[i];

        if (itemSize < minItemWidth) {
          totalUnderMin += minItemWidth - itemSize;
          entry = {
            width: minItemWidth
          };
        } else {
          totalOverMin += itemSize - minItemWidth;
          entry = {
            width: itemSize
          };
          entriesOverMin.push(entry);
        }

        allEntries.push(entry);
      }
      /**
       * If there is nothing under min, or there is not enough over to make up the difference, do nothing.
       */


      if (totalUnderMin === 0 || totalUnderMin > totalOverMin) {
        return;
      }
      /**
       * Evenly reduce all columns that are over the min item width to make up the difference.
       */


      reducePercent = totalUnderMin / totalOverMin;
      remainingWidth = totalUnderMin;

      for (i = 0; i < entriesOverMin.length; i++) {
        entry = entriesOverMin[i];
        reducedWidth = Math.round((entry.width - minItemWidth) * reducePercent);
        remainingWidth -= reducedWidth;
        entry.width -= reducedWidth;
      }
      /**
       * Take anything remaining from the last item.
       */


      if (remainingWidth !== 0) {
        allEntries[allEntries.length - 1].width -= remainingWidth;
      }
      /**
       * Set every items size relative to 100 relative to its size to total
       */


      for (i = 0; i < this.contentItems.length; i++) {
        this.contentItems[i].config.width = allEntries[i].width / sizeData.totalWidth * 100;
      }
    }
    /**
     * Instantiates a new Splitter, binds events to it and adds
     * it to the array of splitters at the position specified as the index argument
     *
     * What it doesn't do though is append the splitter to the DOM
     *
     * @param   {Int} index The position of the splitter
     *
     * @returns {Splitter}
     */

  }, {
    key: "_createSplitter",
    value: function _createSplitter(index) {
      var splitter;
      splitter = new _controls_Splitter__WEBPACK_IMPORTED_MODULE_2__["default"](this._isColumn, this._splitterSize, this._splitterGrabSize);
      splitter.on('drag', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this._onSplitterDrag, this, [splitter]), this);
      splitter.on('dragStop', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this._onSplitterDragStop, this, [splitter]), this);
      splitter.on('dragStart', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this._onSplitterDragStart, this, [splitter]), this);

      this._splitter.splice(index, 0, splitter);

      return splitter;
    }
    /**
     * Locates the instance of Splitter in the array of
     * registered splitters and returns a map containing the contentItem
     * before and after the splitters, both of which are affected if the
     * splitter is moved
     *
     * @param   {Splitter} splitter
     *
     * @returns {Object} A map of contentItems that the splitter affects
     */

  }, {
    key: "_getItemsForSplitter",
    value: function _getItemsForSplitter(splitter) {
      var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(splitter, this._splitter);
      return {
        before: this.contentItems[index],
        after: this.contentItems[index + 1]
      };
    }
    /**
     * Gets docking information
     * @private
     */

  }, {
    key: "_isDocked",
    value: function _isDocked(index) {
      if (typeof index == 'undefined') {
        var count = 0;

        for (var i = 0; i < this.contentItems.length; ++i) {
          if (this._isDocked(i)) count++;
        }

        return count;
      }

      if (index < this.contentItems.length) return this.contentItems[index]._docker && this.contentItems[index]._docker.docked;
    }
    /**
     * Validate if row or column has ability to dock
     * @private
     */

  }, {
    key: "_validateDocking",
    value: function _validateDocking(that) {
      that = that || this;
      var can = that.contentItems.length - that._isDocked() > 1;

      for (var i = 0; i < that.contentItems.length; ++i) {
        if (that.contentItems[i] instanceof _items_Stack__WEBPACK_IMPORTED_MODULE_1__["default"]) {
          that.contentItems[i].header._setDockable(that._isDocked(i) || can);

          that.contentItems[i].header._$setClosable(can);
        }
      }
    }
    /**
     * Gets the minimum dimensions for the given item configuration array
     * @param item
     * @private
     */

  }, {
    key: "_getMinimumDimensions",
    value: function _getMinimumDimensions(arr) {
      var minWidth = 0,
          minHeight = 0;

      for (var i = 0; i < arr.length; ++i) {
        minWidth = Math.max(arr[i].minWidth || 0, minWidth);
        minHeight = Math.max(arr[i].minHeight || 0, minHeight);
      }

      return {
        horizontal: minWidth,
        vertical: minHeight
      };
    }
    /**
     * Invoked when a splitter's dragListener fires dragStart. Calculates the splitters
     * movement area once (so that it doesn't need calculating on every mousemove event)
     *
     * @param   {Splitter} splitter
     *
     * @returns {void}
     */

  }, {
    key: "_onSplitterDragStart",
    value: function _onSplitterDragStart(splitter) {
      var items = this._getItemsForSplitter(splitter),
          minSize = this.layoutManager.config.dimensions[this._isColumn ? 'minItemHeight' : 'minItemWidth'];

      var beforeMinDim = this._getMinimumDimensions(items.before.config.content);

      var beforeMinSize = this._isColumn ? beforeMinDim.vertical : beforeMinDim.horizontal;

      var afterMinDim = this._getMinimumDimensions(items.after.config.content);

      var afterMinSize = this._isColumn ? afterMinDim.vertical : afterMinDim.horizontal;
      this._splitterPosition = 0;
      this._splitterMinPosition = -1 * (items.before.element[this._dimension]() - (beforeMinSize || minSize));
      this._splitterMaxPosition = items.after.element[this._dimension]() - (afterMinSize || minSize);
    }
    /**
     * Invoked when a splitter's DragListener fires drag. Updates the splitters DOM position,
     * but not the sizes of the elements the splitter controls in order to minimize resize events
     *
     * @param   {Splitter} splitter
     * @param   {Int} offsetX  Relative pixel values to the splitters original position. Can be negative
     * @param   {Int} offsetY  Relative pixel values to the splitters original position. Can be negative
     *
     * @returns {void}
     */

  }, {
    key: "_onSplitterDrag",
    value: function _onSplitterDrag(splitter, offsetX, offsetY) {
      var offset = this._isColumn ? offsetY : offsetX;

      if (offset > this._splitterMinPosition && offset < this._splitterMaxPosition) {
        this._splitterPosition = offset;
        splitter.element.css(this._isColumn ? 'top' : 'left', offset);
      }
    }
    /**
     * Invoked when a splitter's DragListener fires dragStop. Resets the splitters DOM position,
     * and applies the new sizes to the elements before and after the splitter and their children
     * on the next animation frame
     *
     * @param   {Splitter} splitter
     *
     * @returns {void}
     */

  }, {
    key: "_onSplitterDragStop",
    value: function _onSplitterDragStop(splitter) {
      var items = this._getItemsForSplitter(splitter),
          sizeBefore = items.before.element[this._dimension](),
          sizeAfter = items.after.element[this._dimension](),
          splitterPositionInRange = (this._splitterPosition + sizeBefore) / (sizeBefore + sizeAfter),
          totalRelativeSize = items.before.config[this._dimension] + items.after.config[this._dimension];

      items.before.config[this._dimension] = splitterPositionInRange * totalRelativeSize;
      items.after.config[this._dimension] = (1 - splitterPositionInRange) * totalRelativeSize;
      splitter.element.css({
        'top': 0,
        'left': 0
      });
      Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["animFrame"])(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(this.callDownwards, this, ['setSize']));
    }
  }]);

  return RowOrColumn;
}(_items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/items/Stack.js":
/*!***********************************!*\
  !*** ./src/js_es6/items/Stack.js ***!
  \***********************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return Stack; });
/* harmony import */ var _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../items/AbstractContentItem */ "./src/js_es6/items/AbstractContentItem.js");
/* harmony import */ var _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../items/RowOrColumn */ "./src/js_es6/items/RowOrColumn.js");
/* harmony import */ var _controls_Header__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! ../controls/Header */ "./src/js_es6/controls/Header.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_3__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_4__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_4___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_4__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }







var Stack = /*#__PURE__*/function (_AbstractContentItem) {
  _inherits(Stack, _AbstractContentItem);

  var _super = _createSuper(Stack);

  function Stack(layoutManager, config, parent) {
    var _this;

    _classCallCheck(this, Stack);

    _this = _super.call(this, layoutManager, config, parent);
    _this.element = jquery__WEBPACK_IMPORTED_MODULE_4___default()('<div class="lm_item lm_stack"></div>');
    _this._activeContentItem = null;
    var cfg = layoutManager.config;
    _this._header = {
      // defaults' reconstruction from old configuration style
      show: cfg.settings.hasHeaders === true && config.hasHeaders !== false,
      popout: cfg.settings.showPopoutIcon && cfg.labels.popout,
      maximise: cfg.settings.showMaximiseIcon && cfg.labels.maximise,
      close: cfg.settings.showCloseIcon && cfg.labels.close,
      minimise: cfg.labels.minimise
    };
    if (cfg.header) // load simplified version of header configuration (https://github.com/deepstreamIO/golden-layout/pull/245)
      Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["copy"])(_this._header, cfg.header);
    if (config.header) // load from stack
      Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["copy"])(_this._header, config.header);
    if (config.content && config.content[0] && config.content[0].header) // load from component if stack omitted
      Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["copy"])(_this._header, config.content[0].header);
    _this._dropZones = {};
    _this._dropSegment = null;
    _this._contentAreaDimensions = null;
    _this._dropIndex = null;
    _this.isStack = true;
    _this.childElementContainer = jquery__WEBPACK_IMPORTED_MODULE_4___default()('<div class="lm_items"></div>');
    _this.header = new _controls_Header__WEBPACK_IMPORTED_MODULE_2__["default"](layoutManager, _assertThisInitialized(_this));

    _this.element.on('mouseleave mouseenter', Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["fnBind"])(function (event) {
      if (this._docker && this._docker.docked) this.childElementContainer[this._docker.dimension](event.type == 'mouseenter' ? this._docker.realSize : 0);
    }, _assertThisInitialized(_this)));

    _this.element.append(_this.header.element);

    _this.element.append(_this.childElementContainer);

    _this._setupHeaderPosition();

    _this._$validateClosability();

    return _this;
  }

  _createClass(Stack, [{
    key: "dock",
    value: function dock(mode) {
      if (this._header.dock) if (this.parent instanceof _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__["default"]) this.parent.dock(this, mode);
    }
  }, {
    key: "setSize",
    value: function setSize() {
      if (this.element.css('display') === 'none') return;
      var isDocked = this._docker && this._docker.docked,
          content = {
        width: this.element.width(),
        height: this.element.height()
      };
      if (this._header.show) content[this._sided ? 'width' : 'height'] -= this.layoutManager.config.dimensions.headerHeight;
      if (isDocked) content[this._docker.dimension] = this._docker.realSize;
      if (!isDocked || this._docker.dimension == 'height') this.childElementContainer.width(content.width);
      if (!isDocked || this._docker.dimension == 'width') this.childElementContainer.height(content.height);

      for (var i = 0; i < this.contentItems.length; i++) {
        this.contentItems[i].element.width(content.width);
        this.contentItems[i].element.height(content.height);
      }

      this.emit('resize');
      this.emitBubblingEvent('stateChanged');
    }
  }, {
    key: "_$init",
    value: function _$init() {
      var i, initialItem;
      if (this.isInitialised === true) return;

      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$init.call(this);

      for (i = 0; i < this.contentItems.length; i++) {
        this.header.createTab(this.contentItems[i]);

        this.contentItems[i]._$hide();
      }

      if (this.contentItems.length > 0) {
        initialItem = this.contentItems[this.config.activeItemIndex || 0];

        if (!initialItem) {
          throw new Error('Configured activeItemIndex out of bounds');
        }

        this.setActiveContentItem(initialItem);
      }

      this._$validateClosability();

      if (this.parent instanceof _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__["default"]) {
        this.parent._validateDocking();
      }
    }
  }, {
    key: "setActiveContentItem",
    value: function setActiveContentItem(contentItem) {
      if (this._activeContentItem === contentItem) return;

      if (Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(contentItem, this.contentItems) === -1) {
        throw new Error('contentItem is not a child of this stack');
      }

      if (this._activeContentItem !== null) {
        this._activeContentItem._$hide();
      }

      this._activeContentItem = contentItem;
      this.header.setActiveContentItem(contentItem);

      contentItem._$show();

      this.emit('activeContentItemChanged', contentItem);
      this.layoutManager.emit('activeContentItemChanged', contentItem);
      this.emitBubblingEvent('stateChanged');
    }
  }, {
    key: "getActiveContentItem",
    value: function getActiveContentItem() {
      return this.header.activeContentItem;
    }
  }, {
    key: "addChild",
    value: function addChild(contentItem, index) {
      if (index > this.contentItems.length) {
        /* 
         * UGLY PATCH: PR #428, commit a4e84ec5 fixed a bug appearing on touchscreens during the drag of a panel. 
         * The bug was caused by the physical removal of the element on drag: partial documentation is at issue #425. 
         * The fix introduced the function undisplayChild() (called 'undisplay' to differentiate it from jQuery.hide), 
         * which doesn't remove the element but only hides it: that's why when a tab is dragged & dropped into its 
         * original container (at the end), the index here could be off by one.
         */
        index -= 1;
      }

      contentItem = this.layoutManager._$normalizeContentItem(contentItem, this);
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.addChild.call(this, contentItem, index);
      this.childElementContainer.append(contentItem.element);
      this.header.createTab(contentItem, index);
      this.setActiveContentItem(contentItem);
      this.callDownwards('setSize');

      this._$validateClosability();

      if (this.parent instanceof _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__["default"]) this.parent._validateDocking();
      this.emitBubblingEvent('stateChanged');
    }
  }, {
    key: "removeChild",
    value: function removeChild(contentItem, keepChild) {
      var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(contentItem, this.contentItems);
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.removeChild.call(this, contentItem, keepChild);
      this.header.removeTab(contentItem);

      if (this.header.activeContentItem === contentItem) {
        if (this.contentItems.length > 0) {
          this.setActiveContentItem(this.contentItems[Math.max(index - 1, 0)]);
        } else {
          this._activeContentItem = null;
        }
      } else if (this.config.activeItemIndex >= this.contentItems.length) {
        if (this.contentItems.length > 0) {
          var activeIndex = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(this.getActiveContentItem(), this.contentItems);
          this.config.activeItemIndex = Math.max(activeIndex, 0);
        }
      }

      this._$validateClosability();

      if (this.parent instanceof _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__["default"]) this.parent._validateDocking();
      this.emitBubblingEvent('stateChanged');
    }
  }, {
    key: "undisplayChild",
    value: function undisplayChild(contentItem) {
      if (this.contentItems.length > 1) {
        var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(contentItem, this.contentItems);
        contentItem._$hide && contentItem._$hide();
        this.setActiveContentItem(this.contentItems[index === 0 ? index + 1 : index - 1]);
      } else {
        this.header.hideTab(contentItem);
        contentItem._$hide && contentItem._$hide();
        _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.undisplayChild.call(this, contentItem);
        if (this.parent instanceof _items_RowOrColumn__WEBPACK_IMPORTED_MODULE_1__["default"]) this.parent._validateDocking();
      }

      this.emitBubblingEvent('stateChanged');
    }
    /**
     * Validates that the stack is still closable or not. If a stack is able
     * to close, but has a non closable component added to it, the stack is no
     * longer closable until all components are closable.
     *
     * @returns {void}
     */

  }, {
    key: "_$validateClosability",
    value: function _$validateClosability() {
      var contentItem, isClosable, len, i;
      isClosable = this.header._isClosable();

      for (i = 0, len = this.contentItems.length; i < len; i++) {
        if (!isClosable) {
          break;
        }

        isClosable = this.contentItems[i].config.isClosable;
      }

      this.header._$setClosable(isClosable);
    }
  }, {
    key: "_$destroy",
    value: function _$destroy() {
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$destroy.call(this);

      this.header._$destroy();

      this.element.off('mouseenter mouseleave');
    }
    /**
     * Ok, this one is going to be the tricky one: The user has dropped {contentItem} onto this stack.
     *
     * It was dropped on either the stacks header or the top, right, bottom or left bit of the content area
     * (which one of those is stored in this._dropSegment). Now, if the user has dropped on the header the case
     * is relatively clear: We add the item to the existing stack... job done (might be good to have
     * tab reordering at some point, but lets not sweat it right now)
     *
     * If the item was dropped on the content part things are a bit more complicated. If it was dropped on either the
     * top or bottom region we need to create a new column and place the items accordingly.
     * Unless, of course if the stack is already within a column... in which case we want
     * to add the newly created item to the existing column...
     * either prepend or append it, depending on wether its top or bottom.
     *
     * Same thing for rows and left / right drop segments... so in total there are 9 things that can potentially happen
     * (left, top, right, bottom) * is child of the right parent (row, column) + header drop
     *
     * @param    {lm.item} contentItem
     *
     * @returns {void}
     */

  }, {
    key: "_$onDrop",
    value: function _$onDrop(contentItem) {
      /*
       * The item was dropped on the header area. Just add it as a child of this stack and
       * get the hell out of this logic
       */
      if (this._dropSegment === 'header') {
        this._resetHeaderDropZone();

        this.addChild(contentItem, this._dropIndex);
        return;
      }
      /*
       * The stack is empty. Let's just add the element.
       */


      if (this._dropSegment === 'body') {
        this.addChild(contentItem);
        return;
      }
      /*
       * The item was dropped on the top-, left-, bottom- or right- part of the content. Let's
       * aggregate some conditions to make the if statements later on more readable
       */


      var isVertical = this._dropSegment === 'top' || this._dropSegment === 'bottom',
          isHorizontal = this._dropSegment === 'left' || this._dropSegment === 'right',
          insertBefore = this._dropSegment === 'top' || this._dropSegment === 'left',
          hasCorrectParent = isVertical && this.parent.isColumn || isHorizontal && this.parent.isRow,
          type = isVertical ? 'column' : 'row',
          dimension = isVertical ? 'height' : 'width',
          index,
          stack,
          rowOrColumn;
      /*
       * The content item can be either a component or a stack. If it is a component, wrap it into a stack
       */

      if (contentItem.isComponent) {
        stack = this.layoutManager.createContentItem({
          type: 'stack',
          header: contentItem.config.header || {}
        }, this);

        stack._$init();

        stack.addChild(contentItem);
        contentItem = stack;
      }
      /*
       * If the contentItem that's being dropped is not dropped on a Stack (cases which just passed above and 
       * which would wrap the contentItem in a Stack) we need to check whether contentItem is a RowOrColumn.
       * If it is, we need to re-wrap it in a Stack like it was when it was dragged by its Tab (it was dragged!).
       */


      if (contentItem.config.type === 'row' || contentItem.config.type === 'column') {
        stack = this.layoutManager.createContentItem({
          type: 'stack'
        }, this);
        stack.addChild(contentItem);
        contentItem = stack;
      }
      /*
       * If the item is dropped on top or bottom of a column or left and right of a row, it's already
       * layd out in the correct way. Just add it as a child
       */


      if (hasCorrectParent) {
        index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_3__["indexOf"])(this, this.parent.contentItems);
        this.parent.addChild(contentItem, insertBefore ? index : index + 1, true);
        this.config[dimension] *= 0.5;
        contentItem.config[dimension] = this.config[dimension];
        this.parent.callDownwards('setSize');
        /*
         * This handles items that are dropped on top or bottom of a row or left / right of a column. We need
         * to create the appropriate contentItem for them to live in
         */
      } else {
        type = isVertical ? 'column' : 'row';
        rowOrColumn = this.layoutManager.createContentItem({
          type: type
        }, this);
        this.parent.replaceChild(this, rowOrColumn);
        rowOrColumn.addChild(contentItem, insertBefore ? 0 : undefined, true);
        rowOrColumn.addChild(this, insertBefore ? undefined : 0, true);
        this.config[dimension] = 50;
        contentItem.config[dimension] = 50;
        rowOrColumn.callDownwards('setSize');
      }

      this.parent._validateDocking();
    }
    /**
     * If the user hovers above the header part of the stack, indicate drop positions for tabs.
     * otherwise indicate which segment of the body the dragged item would be dropped on
     *
     * @param    {Int} x Absolute Screen X
     * @param    {Int} y Absolute Screen Y
     *
     * @returns {void}
     */

  }, {
    key: "_$highlightDropZone",
    value: function _$highlightDropZone(x, y) {
      var segment, area;

      for (segment in this._contentAreaDimensions) {
        area = this._contentAreaDimensions[segment].hoverArea;

        if (area.x1 < x && area.x2 > x && area.y1 < y && area.y2 > y) {
          if (segment === 'header') {
            this._dropSegment = 'header';

            this._highlightHeaderDropZone(this._sided ? y : x);
          } else {
            this._resetHeaderDropZone();

            this._highlightBodyDropZone(segment);
          }

          return;
        }
      }
    }
  }, {
    key: "_$getArea",
    value: function _$getArea() {
      if (this.element.css('display') === 'none') {
        return null;
      }

      var getArea = _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype._$getArea,
          headerArea = getArea.call(this, this.header.element),
          contentArea = getArea.call(this, this.childElementContainer),
          contentWidth = contentArea.x2 - contentArea.x1,
          contentHeight = contentArea.y2 - contentArea.y1;
      this._contentAreaDimensions = {
        header: {
          hoverArea: {
            x1: headerArea.x1,
            y1: headerArea.y1,
            x2: headerArea.x2,
            y2: headerArea.y2
          },
          highlightArea: {
            x1: headerArea.x1,
            y1: headerArea.y1,
            x2: headerArea.x2,
            y2: headerArea.y2
          }
        }
      };
      /**
       * If this Stack is a parent to rows, columns or other stacks only its
       * header is a valid dropzone.
       */

      if (this._activeContentItem && this._activeContentItem.isComponent === false) {
        return headerArea;
      }
      /**
       * Highlight the entire body if the stack is empty
       */


      if (this.contentItems.length === 0) {
        this._contentAreaDimensions.body = {
          hoverArea: {
            x1: contentArea.x1,
            y1: contentArea.y1,
            x2: contentArea.x2,
            y2: contentArea.y2
          },
          highlightArea: {
            x1: contentArea.x1,
            y1: contentArea.y1,
            x2: contentArea.x2,
            y2: contentArea.y2
          }
        };
        return getArea.call(this, this.element);
      }

      this._contentAreaDimensions.left = {
        hoverArea: {
          x1: contentArea.x1,
          y1: contentArea.y1,
          x2: contentArea.x1 + contentWidth * 0.25,
          y2: contentArea.y2
        },
        highlightArea: {
          x1: contentArea.x1,
          y1: contentArea.y1,
          x2: contentArea.x1 + contentWidth * 0.5,
          y2: contentArea.y2
        }
      };
      this._contentAreaDimensions.top = {
        hoverArea: {
          x1: contentArea.x1 + contentWidth * 0.25,
          y1: contentArea.y1,
          x2: contentArea.x1 + contentWidth * 0.75,
          y2: contentArea.y1 + contentHeight * 0.5
        },
        highlightArea: {
          x1: contentArea.x1,
          y1: contentArea.y1,
          x2: contentArea.x2,
          y2: contentArea.y1 + contentHeight * 0.5
        }
      };
      this._contentAreaDimensions.right = {
        hoverArea: {
          x1: contentArea.x1 + contentWidth * 0.75,
          y1: contentArea.y1,
          x2: contentArea.x2,
          y2: contentArea.y2
        },
        highlightArea: {
          x1: contentArea.x1 + contentWidth * 0.5,
          y1: contentArea.y1,
          x2: contentArea.x2,
          y2: contentArea.y2
        }
      };
      this._contentAreaDimensions.bottom = {
        hoverArea: {
          x1: contentArea.x1 + contentWidth * 0.25,
          y1: contentArea.y1 + contentHeight * 0.5,
          x2: contentArea.x1 + contentWidth * 0.75,
          y2: contentArea.y2
        },
        highlightArea: {
          x1: contentArea.x1,
          y1: contentArea.y1 + contentHeight * 0.5,
          x2: contentArea.x2,
          y2: contentArea.y2
        }
      };
      return getArea.call(this, this.element);
    }
  }, {
    key: "_highlightHeaderDropZone",
    value: function _highlightHeaderDropZone(x) {
      var i,
          tabElement,
          tabsLength = this.header.tabs.length,
          isAboveTab = false,
          tabTop,
          tabLeft,
          offset,
          placeHolderLeft,
          headerOffset,
          tabWidth,
          halfX; // Empty stack

      if (tabsLength === 0) {
        headerOffset = this.header.element.offset();
        this.layoutManager.dropTargetIndicator.highlightArea({
          x1: headerOffset.left,
          x2: headerOffset.left + 100,
          y1: headerOffset.top + this.header.element.height() - 20,
          y2: headerOffset.top + this.header.element.height()
        });
        return;
      }

      for (i = 0; i < tabsLength; i++) {
        tabElement = this.header.tabs[i].element;
        offset = tabElement.offset();

        if (this._sided) {
          tabLeft = offset.top;
          tabTop = offset.left;
          tabWidth = tabElement.height();
        } else {
          tabLeft = offset.left;
          tabTop = offset.top;
          tabWidth = tabElement.width();
        }

        if (x > tabLeft && x < tabLeft + tabWidth) {
          isAboveTab = true;
          break;
        }
      }

      if (isAboveTab === false && x < tabLeft) {
        return;
      }

      halfX = tabLeft + tabWidth / 2;

      if (x < halfX) {
        this._dropIndex = i;
        tabElement.before(this.layoutManager.tabDropPlaceholder);
      } else {
        this._dropIndex = Math.min(i + 1, tabsLength);
        tabElement.after(this.layoutManager.tabDropPlaceholder);
      }

      if (this._sided) {
        var placeHolderTop = this.layoutManager.tabDropPlaceholder.offset().top;
        this.layoutManager.dropTargetIndicator.highlightArea({
          x1: tabTop,
          x2: tabTop + tabElement.innerHeight(),
          y1: placeHolderTop,
          y2: placeHolderTop + this.layoutManager.tabDropPlaceholder.width()
        });
        return;
      }

      placeHolderLeft = this.layoutManager.tabDropPlaceholder.offset().left;
      this.layoutManager.dropTargetIndicator.highlightArea({
        x1: placeHolderLeft,
        x2: placeHolderLeft + this.layoutManager.tabDropPlaceholder.width(),
        y1: tabTop,
        y2: tabTop + tabElement.innerHeight()
      });
    }
  }, {
    key: "_resetHeaderDropZone",
    value: function _resetHeaderDropZone() {
      this.layoutManager.tabDropPlaceholder.remove();
    }
  }, {
    key: "toggleMaximise",
    value: function toggleMaximise(e) {
      if (!this.isMaximised) this.dock(false);
      _items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"].prototype.toggleMaximise.call(this, e);
    }
  }, {
    key: "_setupHeaderPosition",
    value: function _setupHeaderPosition() {
      var side = ['right', 'left', 'bottom'].indexOf(this._header.show) >= 0 && this._header.show;

      this.header.element.toggle(!!this._header.show);
      this._side = side;
      this._sided = ['right', 'left'].indexOf(this._side) >= 0;
      this.element.removeClass('lm_left lm_right lm_bottom');
      if (this._side) this.element.addClass('lm_' + this._side);

      if (this.element.find('.lm_header').length && this.childElementContainer) {
        var headerPosition = ['right', 'bottom'].indexOf(this._side) >= 0 ? 'before' : 'after';
        this.header.element[headerPosition](this.childElementContainer);
        this.callDownwards('setSize');
      }
    }
  }, {
    key: "_highlightBodyDropZone",
    value: function _highlightBodyDropZone(segment) {
      var highlightArea = this._contentAreaDimensions[segment].highlightArea;
      this.layoutManager.dropTargetIndicator.highlightArea(highlightArea);
      this._dropSegment = segment;
    }
  }]);

  return Stack;
}(_items_AbstractContentItem__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/utils/BubblingEvent.js":
/*!*******************************************!*\
  !*** ./src/js_es6/utils/BubblingEvent.js ***!
  \*******************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return BubblingEvent; });
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

var BubblingEvent = /*#__PURE__*/function () {
  function BubblingEvent(name, origin) {
    _classCallCheck(this, BubblingEvent);

    this.name = name;
    this.origin = origin;
    this.isPropagationStopped = false;
  }

  _createClass(BubblingEvent, [{
    key: "stopPropagation",
    value: function stopPropagation() {
      this.isPropagationStopped = true;
    }
  }]);

  return BubblingEvent;
}();



/***/ }),

/***/ "./src/js_es6/utils/ConfigMinifier.js":
/*!********************************************!*\
  !*** ./src/js_es6/utils/ConfigMinifier.js ***!
  \********************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return ConfigMinifier; });
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }


/**
 * Minifies and unminifies configs by replacing frequent keys
 * and values with one letter substitutes. Config options must
 * retain array position/index, add new options at the end.
 *
 * @constructor
 */

var ConfigMinifier = /*#__PURE__*/function () {
  function ConfigMinifier() {
    _classCallCheck(this, ConfigMinifier);

    this._keys = ['settings', 'hasHeaders', 'constrainDragToContainer', 'selectionEnabled', 'dimensions', 'borderWidth', 'minItemHeight', 'minItemWidth', 'headerHeight', 'dragProxyWidth', 'dragProxyHeight', 'labels', 'close', 'maximise', 'minimise', 'popout', 'content', 'componentName', 'componentState', 'id', 'width', 'type', 'height', 'isClosable', 'title', 'popoutWholeStack', 'openPopouts', 'parentId', 'activeItemIndex', 'reorderEnabled', 'borderGrabWidth' //Maximum 36 entries, do not cross this line!
    ];

    if (this._keys.length > 36) {
      throw new Error('Too many keys in config minifier map');
    }

    this._values = [true, false, 'row', 'column', 'stack', 'component', 'close', 'maximise', 'minimise', 'open in new window'];
  }
  /**
   * Takes a GoldenLayout configuration object and
   * replaces its keys and values recursively with
   * one letter counterparts
   *
   * @param   {Object} config A GoldenLayout config object
   *
   * @returns {Object} minified config
   */


  _createClass(ConfigMinifier, [{
    key: "minifyConfig",
    value: function minifyConfig(config) {
      var min = {};

      this._nextLevel(config, min, '_min');

      return min;
    }
    /**
     * Takes a configuration Object that was previously minified
     * using minifyConfig and returns its original version
     *
     * @param   {Object} minifiedConfig
     *
     * @returns {Object} the original configuration
     */

  }, {
    key: "unminifyConfig",
    value: function unminifyConfig(minifiedConfig) {
      var orig = {};

      this._nextLevel(minifiedConfig, orig, '_max');

      return orig;
    }
    /**
     * Recursive function, called for every level of the config structure
     *
     * @param   {Array|Object} orig
     * @param   {Array|Object} min
     * @param    {String} translationFn
     *
     * @returns {void}
     */

  }, {
    key: "_nextLevel",
    value: function _nextLevel(from, to, translationFn) {
      var key, minKey;

      for (key in from) {
        /**
         * For in returns array indices as keys, so let's cast them to numbers
         */
        if (from instanceof Array) key = parseInt(key, 10);
        /**
         * In case something has extended Object prototypes
         */

        if (!from.hasOwnProperty(key)) continue;
        /**
         * Translate the key to a one letter substitute
         */

        minKey = this[translationFn](key, this._keys);
        /**
         * For Arrays and Objects, create a new Array/Object
         * on the minified object and recurse into it
         */

        if (_typeof(from[key]) === 'object') {
          to[minKey] = from[key] instanceof Array ? [] : {};

          this._nextLevel(from[key], to[minKey], translationFn);
          /**
           * For primitive values (Strings, Numbers, Boolean etc.)
           * minify the value
           */

        } else {
          to[minKey] = this[translationFn](from[key], this._values);
        }
      }
    }
    /**
     * Minifies value based on a dictionary
     *
     * @param   {String|Boolean} value
     * @param   {Array<String|Boolean>} dictionary
     *
     * @returns {String} The minified version
     */

  }, {
    key: "_min",
    value: function _min(value, dictionary) {
      /**
       * If a value actually is a single character, prefix it
       * with ___ to avoid mistaking it for a minification code
       */
      if (typeof value === 'string' && value.length === 1) {
        return '___' + value;
      }

      var index = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_0__["indexOf"])(value, dictionary);
      /**
       * value not found in the dictionary, return it unmodified
       */

      if (index === -1) {
        return value;
        /**
         * value found in dictionary, return its base36 counterpart
         */
      } else {
        return index.toString(36);
      }
    }
  }, {
    key: "_max",
    value: function _max(value, dictionary) {
      /**
       * value is a single character. Assume that it's a translation
       * and return the original value from the dictionary
       */
      if (typeof value === 'string' && value.length === 1) {
        return dictionary[parseInt(value, 36)];
      }
      /**
       * value originally was a single character and was prefixed with ___
       * to avoid mistaking it for a translation. Remove the prefix
       * and return the original character
       */


      if (typeof value === 'string' && value.substr(0, 3) === '___') {
        return value[3];
      }
      /**
       * value was not minified
       */


      return value;
    }
  }]);

  return ConfigMinifier;
}();



/***/ }),

/***/ "./src/js_es6/utils/DragListener.js":
/*!******************************************!*\
  !*** ./src/js_es6/utils/DragListener.js ***!
  \******************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return DragListener; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_2__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }





var DragListener = /*#__PURE__*/function (_EventEmitter) {
  _inherits(DragListener, _EventEmitter);

  var _super = _createSuper(DragListener);

  function DragListener(eElement, nButtonCode) {
    var _this;

    _classCallCheck(this, DragListener);

    _this = _super.call(this);
    _this._timeout = null;
    _this._eElement = jquery__WEBPACK_IMPORTED_MODULE_2___default()(eElement);
    _this._oDocument = jquery__WEBPACK_IMPORTED_MODULE_2___default()(document);
    _this._eBody = jquery__WEBPACK_IMPORTED_MODULE_2___default()(document.body);
    _this._nButtonCode = nButtonCode || 0;
    /**
     * The delay after which to start the drag in milliseconds
     */

    _this._nDelay = 200;
    /**
     * The distance the mouse needs to be moved to qualify as a drag
     */

    _this._nDistance = 10; //TODO - works better with delay only

    _this._nX = 0;
    _this._nY = 0;
    _this._nOriginalX = 0;
    _this._nOriginalY = 0;
    _this._bDragging = false;
    _this._fMove = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["fnBind"])(_this.onMouseMove, _assertThisInitialized(_this));
    _this._fUp = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["fnBind"])(_this.onMouseUp, _assertThisInitialized(_this));
    _this._fDown = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["fnBind"])(_this.onMouseDown, _assertThisInitialized(_this));

    _this._eElement.on('mousedown touchstart', _this._fDown);

    return _this;
  }

  _createClass(DragListener, [{
    key: "destroy",
    value: function destroy() {
      this._eElement.unbind('mousedown touchstart', this._fDown);

      this._oDocument.unbind('mouseup touchend', this._fUp);

      this._eElement = null;
      this._oDocument = null;
      this._eBody = null;
    }
  }, {
    key: "onMouseDown",
    value: function onMouseDown(oEvent) {
      oEvent.preventDefault();

      if (oEvent.button == 0 || oEvent.type === "touchstart") {
        var coordinates = this._getCoordinates(oEvent);

        this._nOriginalX = coordinates.x;
        this._nOriginalY = coordinates.y;

        this._oDocument.on('mousemove touchmove', this._fMove);

        this._oDocument.one('mouseup touchend', this._fUp);

        this._timeout = setTimeout(Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["fnBind"])(this._startDrag, this), this._nDelay);
      }
    }
  }, {
    key: "onMouseMove",
    value: function onMouseMove(oEvent) {
      if (this._timeout != null) {
        oEvent.preventDefault();

        var coordinates = this._getCoordinates(oEvent);

        this._nX = coordinates.x - this._nOriginalX;
        this._nY = coordinates.y - this._nOriginalY;

        if (this._bDragging === false) {
          if (Math.abs(this._nX) > this._nDistance || Math.abs(this._nY) > this._nDistance) {
            clearTimeout(this._timeout);

            this._startDrag();
          }
        }

        if (this._bDragging) {
          this.emit('drag', this._nX, this._nY, oEvent);
        }
      }
    }
  }, {
    key: "onMouseUp",
    value: function onMouseUp(oEvent) {
      if (this._timeout != null) {
        clearTimeout(this._timeout);

        this._eBody.removeClass('lm_dragging');

        this._eElement.removeClass('lm_dragging');

        this._oDocument.find('iframe').css('pointer-events', '');

        this._oDocument.unbind('mousemove touchmove', this._fMove);

        this._oDocument.unbind('mouseup touchend', this._fUp);

        if (this._bDragging === true) {
          this._bDragging = false;
          this.emit('dragStop', oEvent, this._nOriginalX + this._nX);
        }
      }
    }
  }, {
    key: "_startDrag",
    value: function _startDrag() {
      this._bDragging = true;

      this._eBody.addClass('lm_dragging');

      this._eElement.addClass('lm_dragging');

      this._oDocument.find('iframe').css('pointer-events', 'none');

      this.emit('dragStart', this._nOriginalX, this._nOriginalY);
    }
  }, {
    key: "_getCoordinates",
    value: function _getCoordinates(event) {
      event = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["getTouchEvent"])(event);
      return {
        x: event.pageX,
        y: event.pageY
      };
    }
  }]);

  return DragListener;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/utils/EventEmitter.js":
/*!******************************************!*\
  !*** ./src/js_es6/utils/EventEmitter.js ***!
  \******************************************/
/*! exports provided: ALL_EVENT, default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "ALL_EVENT", function() { return ALL_EVENT; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return EventEmitter; });
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }


/**
 * The name of the event that's triggered for every other event
 *
 * usage
 *
 * myEmitter.on( EventEmitter.ALL_EVENT, function( eventName, argsArray ){
 *  //do stuff
 * });
 *
 * @type {String}
 */

var ALL_EVENT = '__all';
/**
 * A generic and very fast EventEmitter
 * implementation. On top of emitting the
 * actual event it emits an
 *
 * EventEmitter.ALL_EVENT
 *
 * event for every event triggered. This allows
 * to hook into it and proxy events forwards
 *
 * @constructor
 */

var EventEmitter = function EventEmitter() {
  _classCallCheck(this, EventEmitter);

  this._mSubscriptions = {};
  this._mSubscriptions[ALL_EVENT] = [];
  /**
   * Listen for events
   *
   * @param   {String} sEvent    The name of the event to listen to
   * @param   {Function} fCallback The callback to execute when the event occurs
   * @param   {[Object]} oContext The value of the this pointer within the callback function
   *
   * @returns {void}
   */

  this.on = function (sEvent, fCallback, oContext) {
    if (!Object(_utils_utils__WEBPACK_IMPORTED_MODULE_0__["isFunction"])(fCallback)) {
      throw new Error('Tried to listen to event ' + sEvent + ' with non-function callback ' + fCallback);
    }

    if (!this._mSubscriptions[sEvent]) {
      this._mSubscriptions[sEvent] = [];
    }

    this._mSubscriptions[sEvent].push({
      fn: fCallback,
      ctx: oContext
    });
  };
  /**
   * Emit an event and notify listeners
   *
   * @param   {String} sEvent The name of the event
   * @param    {Mixed}  various additional arguments that will be passed to the listener
   *
   * @returns {void}
   */


  this.emit = function (sEvent) {
    var i, ctx, args;
    args = Array.prototype.slice.call(arguments, 1);
    var subs = this._mSubscriptions[sEvent];

    if (subs) {
      subs = subs.slice();

      for (i = 0; i < subs.length; i++) {
        ctx = subs[i].ctx || {};
        subs[i].fn.apply(ctx, args);
      }
    }

    args.unshift(sEvent);

    var allEventSubs = this._mSubscriptions[ALL_EVENT].slice();

    for (i = 0; i < allEventSubs.length; i++) {
      ctx = allEventSubs[i].ctx || {};
      allEventSubs[i].fn.apply(ctx, args);
    }
  };
  /**
   * Removes a listener for an event, or all listeners if no callback and context is provided.
   *
   * @param   {String} sEvent    The name of the event
   * @param   {Function} fCallback The previously registered callback method (optional)
   * @param   {Object} oContext  The previously registered context (optional)
   *
   * @returns {void}
   */


  this.unbind = function (sEvent, fCallback, oContext) {
    if (!this._mSubscriptions[sEvent]) {
      throw new Error('No subscribtions to unsubscribe for event ' + sEvent);
    }

    var i,
        bUnbound = false;

    for (i = 0; i < this._mSubscriptions[sEvent].length; i++) {
      if ((!fCallback || this._mSubscriptions[sEvent][i].fn === fCallback) && (!oContext || oContext === this._mSubscriptions[sEvent][i].ctx)) {
        this._mSubscriptions[sEvent].splice(i, 1);

        bUnbound = true;
      }
    }

    if (bUnbound === false) {
      throw new Error('Nothing to unbind for ' + sEvent);
    }
  };
  /**
   * Alias for unbind
   */


  this.off = this.unbind;
  /**
   * Alias for emit
   */

  this.trigger = this.emit;
};



/***/ }),

/***/ "./src/js_es6/utils/EventHub.js":
/*!**************************************!*\
  !*** ./src/js_es6/utils/EventHub.js ***!
  \**************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return EventHub; });
/* harmony import */ var _utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! ../utils/EventEmitter */ "./src/js_es6/utils/EventEmitter.js");
/* harmony import */ var _utils_utils__WEBPACK_IMPORTED_MODULE_1__ = __webpack_require__(/*! ../utils/utils */ "./src/js_es6/utils/utils.js");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_2___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_2__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }

function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }

function _inherits(subClass, superClass) { if (typeof superClass !== "function" && superClass !== null) { throw new TypeError("Super expression must either be null or a function"); } subClass.prototype = Object.create(superClass && superClass.prototype, { constructor: { value: subClass, writable: true, configurable: true } }); if (superClass) _setPrototypeOf(subClass, superClass); }

function _setPrototypeOf(o, p) { _setPrototypeOf = Object.setPrototypeOf || function _setPrototypeOf(o, p) { o.__proto__ = p; return o; }; return _setPrototypeOf(o, p); }

function _createSuper(Derived) { return function () { var Super = _getPrototypeOf(Derived), result; if (_isNativeReflectConstruct()) { var NewTarget = _getPrototypeOf(this).constructor; result = Reflect.construct(Super, arguments, NewTarget); } else { result = Super.apply(this, arguments); } return _possibleConstructorReturn(this, result); }; }

function _possibleConstructorReturn(self, call) { if (call && (_typeof(call) === "object" || typeof call === "function")) { return call; } return _assertThisInitialized(self); }

function _assertThisInitialized(self) { if (self === void 0) { throw new ReferenceError("this hasn't been initialised - super() hasn't been called"); } return self; }

function _isNativeReflectConstruct() { if (typeof Reflect === "undefined" || !Reflect.construct) return false; if (Reflect.construct.sham) return false; if (typeof Proxy === "function") return true; try { Date.prototype.toString.call(Reflect.construct(Date, [], function () {})); return true; } catch (e) { return false; } }

function _getPrototypeOf(o) { _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf : function _getPrototypeOf(o) { return o.__proto__ || Object.getPrototypeOf(o); }; return _getPrototypeOf(o); }





/**
 * An EventEmitter singleton that propagates events
 * across multiple windows. This is a little bit trickier since
 * windows are allowed to open childWindows in their own right
 *
 * This means that we deal with a tree of windows. Hence the rules for event propagation are:
 *
 * - Propagate events from this layout to both parents and children
 * - Propagate events from parent to this and children
 * - Propagate events from children to the other children (but not the emitting one) and the parent
 *
 * @constructor
 *
 * @param {lm.LayoutManager} layoutManager
 */

var EventHub = /*#__PURE__*/function (_EventEmitter) {
  _inherits(EventHub, _EventEmitter);

  var _super = _createSuper(EventHub);

  function EventHub(layoutManager) {
    var _this;

    _classCallCheck(this, EventHub);

    _this = _super.call(this);
    _this._layoutManager = layoutManager;
    _this._dontPropagateToParent = null;
    _this._childEventSource = null;

    _this.on(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["ALL_EVENT"], Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["fnBind"])(_this._onEventFromThis, _assertThisInitialized(_this)));

    _this._boundOnEventFromChild = Object(_utils_utils__WEBPACK_IMPORTED_MODULE_1__["fnBind"])(_this._onEventFromChild, _assertThisInitialized(_this));
    jquery__WEBPACK_IMPORTED_MODULE_2___default()(window).on('gl_child_event', _this._boundOnEventFromChild);
    return _this;
  }
  /**
   * Called on every event emitted on this eventHub, regardles of origin.
   *
   * @private
   *
   * @param {Mixed}
   *
   * @returns {void}
   */


  _createClass(EventHub, [{
    key: "_onEventFromThis",
    value: function _onEventFromThis() {
      var args = Array.prototype.slice.call(arguments);

      if (this._layoutManager.isSubWindow && args[0] !== this._dontPropagateToParent) {
        this._propagateToParent(args);
      }

      this._propagateToChildren(args); //Reset


      this._dontPropagateToParent = null;
      this._childEventSource = null;
    }
    /**
     * Called by the parent layout.
     *
     * @param   {Array} args Event name + arguments
     *
     * @returns {void}
     */

  }, {
    key: "_$onEventFromParent",
    value: function _$onEventFromParent(args) {
      this._dontPropagateToParent = args[0];
      this.emit.apply(this, args);
    }
    /**
     * Callback for child events raised on the window
     *
     * @param   {DOMEvent} event
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_onEventFromChild",
    value: function _onEventFromChild(event) {
      this._childEventSource = event.originalEvent.__gl;
      this.emit.apply(this, event.originalEvent.__glArgs);
    }
    /**
     * Propagates the event to the parent by emitting
     * it on the parent's DOM window
     *
     * @param   {Array} args Event name + arguments
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_propagateToParent",
    value: function _propagateToParent(args) {
      var event,
          eventName = 'gl_child_event';

      if (document.createEvent) {
        event = window.opener.document.createEvent('HTMLEvents');
        event.initEvent(eventName, true, true);
      } else {
        event = window.opener.document.createEventObject();
        event.eventType = eventName;
      }

      event.eventName = eventName;
      event.__glArgs = args;
      event.__gl = this._layoutManager;

      if (document.createEvent) {
        window.opener.dispatchEvent(event);
      } else {
        window.opener.fireEvent('on' + event.eventType, event);
      }
    }
    /**
     * Propagate events to children
     *
     * @param   {Array} args Event name + arguments
     * @private
     *
     * @returns {void}
     */

  }, {
    key: "_propagateToChildren",
    value: function _propagateToChildren(args) {
      var childGl, i;

      for (i = 0; i < this._layoutManager.openPopouts.length; i++) {
        childGl = this._layoutManager.openPopouts[i].getGlInstance();

        if (childGl && childGl !== this._childEventSource) {
          childGl.eventHub._$onEventFromParent(args);
        }
      }
    }
    /**
     * Destroys the EventHub
     *
     * @public
     * @returns {void}
     */

  }, {
    key: "destroy",
    value: function destroy() {
      jquery__WEBPACK_IMPORTED_MODULE_2___default()(window).off('gl_child_event', this._boundOnEventFromChild);
    }
  }]);

  return EventHub;
}(_utils_EventEmitter__WEBPACK_IMPORTED_MODULE_0__["default"]);



/***/ }),

/***/ "./src/js_es6/utils/ReactComponentHandler.js":
/*!***************************************************!*\
  !*** ./src/js_es6/utils/ReactComponentHandler.js ***!
  \***************************************************/
/*! exports provided: default */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "default", function() { return ReactComponentHandler; });
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_0__);
function _classCallCheck(instance, Constructor) { if (!(instance instanceof Constructor)) { throw new TypeError("Cannot call a class as a function"); } }

function _defineProperties(target, props) { for (var i = 0; i < props.length; i++) { var descriptor = props[i]; descriptor.enumerable = descriptor.enumerable || false; descriptor.configurable = true; if ("value" in descriptor) descriptor.writable = true; Object.defineProperty(target, descriptor.key, descriptor); } }

function _createClass(Constructor, protoProps, staticProps) { if (protoProps) _defineProperties(Constructor.prototype, protoProps); if (staticProps) _defineProperties(Constructor, staticProps); return Constructor; }


/**
 * A specialised GoldenLayout component that binds GoldenLayout container
 * lifecycle events to react components
 *
 * @constructor
 *
 * @param {ItemContainer} container
 * @param {Object} state state is not required for react components
 */

var ReactComponentHandler = /*#__PURE__*/function () {
  function ReactComponentHandler(container, state) {
    _classCallCheck(this, ReactComponentHandler);

    this._reactComponent = null;
    this._originalComponentWillUpdate = null;
    this._container = container;
    this._initialState = state;
    this._reactClass = this._getReactClass();

    this._container.on('open', this._render, this);

    this._container.on('destroy', this._destroy, this);
  }
  /**
   * Creates the react class and component and hydrates it with
   * the initial state - if one is present
   *
   * By default, react's getInitialState will be used
   *
   * @private
   * @returns {void}
   */


  _createClass(ReactComponentHandler, [{
    key: "_render",
    value: function _render() {
      ReactDOM.render(this._getReactComponent(), this._container.getElement()[0]);
    }
    /**
     * Fired by react when the component is created.  Also fired upon destruction (where component is null).
     * <p>
     * Note: This callback is used instead of the return from `ReactDOM.render` because
     *	   of https://github.com/facebook/react/issues/10309.
     * </p>
     *
     * @private
     * @arg {React.Ref} component The component instance created by the `ReactDOM.render` call in the `_render` method.
     * @returns {void}
     */

  }, {
    key: "_gotReactComponent",
    value: function _gotReactComponent(component) {
      if (component !== null) {
        this._reactComponent = component;

        this._originalComponentWillUpdate = this._reactComponent.componentWillUpdate || function () {};

        this._reactComponent.componentWillUpdate = this._onUpdate.bind(this);

        if (this._container.getState()) {
          this._reactComponent.setState(this._container.getState());
        }
      }
    }
    /**
     * Removes the component from the DOM and thus invokes React's unmount lifecycle
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_destroy",
    value: function _destroy() {
      ReactDOM.unmountComponentAtNode(this._container.getElement()[0]);

      this._container.off('open', this._render, this);

      this._container.off('destroy', this._destroy, this);
    }
    /**
     * Hooks into React's state management and applies the componentstate
     * to GoldenLayout
     *
     * @private
     * @returns {void}
     */

  }, {
    key: "_onUpdate",
    value: function _onUpdate(nextProps, nextState) {
      this._container.setState(nextState);

      this._originalComponentWillUpdate.call(this._reactComponent, nextProps, nextState);
    }
    /**
     * Retrieves the react class from GoldenLayout's registry
     *
     * @private
     * @returns {React.Class}
     */

  }, {
    key: "_getReactClass",
    value: function _getReactClass() {
      var componentName = this._container._config.component;
      var reactClass;

      if (!componentName) {
        throw new Error('No react component name. type: react-component needs a field `component`');
      }

      reactClass = this._container.layoutManager.getComponent(this._container._config);

      if (!reactClass) {
        throw new Error('React component "' + componentName + '" not found. ' + 'Please register all components with GoldenLayout using `registerComponent(name, component)`');
      }

      return reactClass;
    }
    /**
     * Copies and extends the properties array and returns the React element
     *
     * @private
     * @returns {React.Element}
     */

  }, {
    key: "_getReactComponent",
    value: function _getReactComponent() {
      var defaultProps = {
        glEventHub: this._container.layoutManager.eventHub,
        glContainer: this._container,
        ref: this._gotReactComponent.bind(this)
      };
      var props = jquery__WEBPACK_IMPORTED_MODULE_0___default.a.extend(defaultProps, this._container._config.props);
      return React.createElement(this._reactClass, props);
    }
  }]);

  return ReactComponentHandler;
}();



/***/ }),

/***/ "./src/js_es6/utils/utils.js":
/*!***********************************!*\
  !*** ./src/js_es6/utils/utils.js ***!
  \***********************************/
/*! exports provided: F, getTouchEvent, extend, createObject, objectKeys, getHashValue, getQueryStringParam, copy, animFrame, indexOf, isFunction, fnBind, removeFromArray, now, getUniqueId, filterXss, stripTags */
/***/ (function(module, __webpack_exports__, __webpack_require__) {

"use strict";
__webpack_require__.r(__webpack_exports__);
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "F", function() { return F; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "getTouchEvent", function() { return getTouchEvent; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "extend", function() { return extend; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "createObject", function() { return createObject; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "objectKeys", function() { return objectKeys; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "getHashValue", function() { return getHashValue; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "getQueryStringParam", function() { return getQueryStringParam; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "copy", function() { return copy; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "animFrame", function() { return animFrame; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "indexOf", function() { return indexOf; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "isFunction", function() { return isFunction; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "fnBind", function() { return fnBind; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "removeFromArray", function() { return removeFromArray; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "now", function() { return now; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "getUniqueId", function() { return getUniqueId; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "filterXss", function() { return filterXss; });
/* harmony export (binding) */ __webpack_require__.d(__webpack_exports__, "stripTags", function() { return stripTags; });
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0__ = __webpack_require__(/*! jquery */ "jquery");
/* harmony import */ var jquery__WEBPACK_IMPORTED_MODULE_0___default = /*#__PURE__*/__webpack_require__.n(jquery__WEBPACK_IMPORTED_MODULE_0__);
function _typeof(obj) { "@babel/helpers - typeof"; if (typeof Symbol === "function" && typeof Symbol.iterator === "symbol") { _typeof = function _typeof(obj) { return typeof obj; }; } else { _typeof = function _typeof(obj) { return obj && typeof Symbol === "function" && obj.constructor === Symbol && obj !== Symbol.prototype ? "symbol" : typeof obj; }; } return _typeof(obj); }


function F() {}
function getTouchEvent(event) {
  if (jquery__WEBPACK_IMPORTED_MODULE_0___default.a.zepto) {
    return event.touches ? event.targetTouches[0] : event;
  } else {
    return event.originalEvent && event.originalEvent.touches ? event.originalEvent.touches[0] : event;
  }
}
function extend(subClass, superClass) {
  subClass.prototype = createObject(superClass.prototype);
  subClass.prototype.contructor = subClass;
}
function createObject(prototype) {
  if (typeof Object.create === 'function') {
    return Object.create(prototype);
  } else {
    F.prototype = prototype;
    return new F();
  }
}
function objectKeys(object) {
  var keys, key;

  if (typeof Object.keys === 'function') {
    return Object.keys(object);
  } else {
    keys = [];

    for (key in object) {
      keys.push(key);
    }

    return keys;
  }
}
function getHashValue(key) {
  var matches = location.hash.match(new RegExp(key + '=([^&]*)'));
  return matches ? matches[1] : null;
}
function getQueryStringParam(param) {
  if (window.location.hash) {
    return getHashValue(param);
  } else if (!window.location.search) {
    return null;
  }

  var keyValuePairs = window.location.search.substr(1).split('&'),
      params = {},
      pair,
      i;

  for (i = 0; i < keyValuePairs.length; i++) {
    pair = keyValuePairs[i].split('=');
    params[pair[0]] = pair[1];
  }

  return params[param] || null;
}
function copy(target, source) {
  for (var key in source) {
    target[key] = source[key];
  }

  return target;
}
/**
 * This is based on Paul Irish's shim, but looks quite odd in comparison. Why?
 * Because
 * a) it shouldn't affect the global requestAnimationFrame function
 * b) it shouldn't pass on the time that has passed
 *
 * @param   {Function} fn
 *
 * @returns {void}
 */

function animFrame(fn) {
  return (window.requestAnimationFrame || window.webkitRequestAnimationFrame || window.mozRequestAnimationFrame || function (callback) {
    window.setTimeout(callback, 1000 / 60);
  })(function () {
    fn();
  });
}
function indexOf(needle, haystack) {
  if (!(haystack instanceof Array)) {
    throw new Error('Haystack is not an Array');
  }

  if (haystack.indexOf) {
    return haystack.indexOf(needle);
  } else {
    for (var i = 0; i < haystack.length; i++) {
      if (haystack[i] === needle) {
        return i;
      }
    }

    return -1;
  }
}
var isFunction =  true && (typeof Int8Array === "undefined" ? "undefined" : _typeof(Int8Array)) != 'object' ? function isFunction(obj) {
  return typeof obj == 'function' || false;
} : function isFunction(obj) {
  return toString.call(obj) === '[object Function]';
};
function fnBind(fn, context, boundArgs) {
  if (Function.prototype.bind !== undefined) {
    return Function.prototype.bind.apply(fn, [context].concat(boundArgs || []));
  }

  var bound = function bound() {
    // Join the already applied arguments to the now called ones (after converting to an array again).
    var args = (boundArgs || []).concat(Array.prototype.slice.call(arguments, 0)); // If not being called as a constructor

    if (!(this instanceof bound)) {
      // return the result of the function called bound to target and partially applied.
      return fn.apply(context, args);
    } // If being called as a constructor, apply the function bound to self.


    fn.apply(this, args);
  }; // Attach the prototype of the function to our newly created function.


  bound.prototype = fn.prototype;
  return bound;
}
function removeFromArray(item, array) {
  var index = indexOf(item, array);

  if (index === -1) {
    throw new Error('Can\'t remove item from array. Item is not in the array');
  }

  array.splice(index, 1);
}
function now() {
  if (typeof Date.now === 'function') {
    return Date.now();
  } else {
    return new Date().getTime();
  }
}
function getUniqueId() {
  return (Math.random() * 1000000000000000).toString(36).replace('.', '');
}
/**
 * A basic XSS filter. It is ultimately up to the
 * implementing developer to make sure their particular
 * applications and usecases are save from cross site scripting attacks
 *
 * @param   {String} input
 * @param    {Boolean} keepTags
 *
 * @returns {String} filtered input
 */

function filterXss(input, keepTags) {
  var output = input.replace(/javascript/gi, 'j&#97;vascript').replace(/expression/gi, 'expr&#101;ssion').replace(/onload/gi, 'onlo&#97;d').replace(/script/gi, '&#115;cript').replace(/onerror/gi, 'on&#101;rror');

  if (keepTags === true) {
    return output;
  } else {
    return output.replace(/>/g, '&gt;').replace(/</g, '&lt;');
  }
}
/**
 * Removes html tags from a string
 *
 * @param   {String} input
 *
 * @returns {String} input without tags
 */

function stripTags(input) {
  return jquery__WEBPACK_IMPORTED_MODULE_0___default.a.trim(input.replace(/(<([^>]+)>)/ig, ''));
}

/***/ }),

/***/ "jquery":
/*!*************************************************************************************!*\
  !*** external {"commonjs":"jquery","commonjs2":"jquery","amd":"jquery","root":"$"} ***!
  \*************************************************************************************/
/*! no static exports found */
/***/ (function(module, exports) {

module.exports = __WEBPACK_EXTERNAL_MODULE_jquery__;

/***/ })

/******/ });
});
//# sourceMappingURL=data:application/json;charset=utf-8;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvd2VicGFjay91bml2ZXJzYWxNb2R1bGVEZWZpbml0aW9uIiwid2VicGFjazovL0dvbGRlbkxheW91dC93ZWJwYWNrL2Jvb3RzdHJhcCIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvaW5kZXguanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi9MYXlvdXRNYW5hZ2VyLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvY29uZmlnL0l0ZW1EZWZhdWx0Q29uZmlnLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvY29uZmlnL2RlZmF1bHRDb25maWcuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi9jb250YWluZXIvSXRlbUNvbnRhaW5lci5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L2NvbnRyb2xzL0Jyb3dzZXJQb3BvdXQuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi9jb250cm9scy9EcmFnUHJveHkuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi9jb250cm9scy9EcmFnU291cmNlLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvY29udHJvbHMvRHJvcFRhcmdldEluZGljYXRvci5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L2NvbnRyb2xzL0hlYWRlci5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L2NvbnRyb2xzL0hlYWRlckJ1dHRvbi5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L2NvbnRyb2xzL1NwbGl0dGVyLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvY29udHJvbHMvVGFiLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvY29udHJvbHMvVHJhbnNpdGlvbkluZGljYXRvci5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L2Vycm9ycy9Db25maWd1cmF0aW9uRXJyb3IuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi9pdGVtcy9BYnN0cmFjdENvbnRlbnRJdGVtLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvaXRlbXMvQ29tcG9uZW50LmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvaXRlbXMvUm9vdC5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L2l0ZW1zL1Jvd09yQ29sdW1uLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvaXRlbXMvU3RhY2suanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi91dGlscy9CdWJibGluZ0V2ZW50LmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC8uL3NyYy9qc19lczYvdXRpbHMvQ29uZmlnTWluaWZpZXIuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi91dGlscy9EcmFnTGlzdGVuZXIuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi91dGlscy9FdmVudEVtaXR0ZXIuanMiLCJ3ZWJwYWNrOi8vR29sZGVuTGF5b3V0Ly4vc3JjL2pzX2VzNi91dGlscy9FdmVudEh1Yi5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L3V0aWxzL1JlYWN0Q29tcG9uZW50SGFuZGxlci5qcyIsIndlYnBhY2s6Ly9Hb2xkZW5MYXlvdXQvLi9zcmMvanNfZXM2L3V0aWxzL3V0aWxzLmpzIiwid2VicGFjazovL0dvbGRlbkxheW91dC9leHRlcm5hbCB7XCJjb21tb25qc1wiOlwianF1ZXJ5XCIsXCJjb21tb25qczJcIjpcImpxdWVyeVwiLFwiYW1kXCI6XCJqcXVlcnlcIixcInJvb3RcIjpcIiRcIn0iXSwibmFtZXMiOlsiUkVBQ1RfQ09NUE9ORU5UX0lEIiwiTGF5b3V0TWFuYWdlciIsImNvbmZpZyIsImNvbnRhaW5lciIsImlzSW5pdGlhbGlzZWQiLCJfaXNGdWxsUGFnZSIsIl9yZXNpemVUaW1lb3V0SWQiLCJfY29tcG9uZW50cyIsIl9pdGVtQXJlYXMiLCJfcmVzaXplRnVuY3Rpb24iLCJmbkJpbmQiLCJfb25SZXNpemUiLCJfdW5sb2FkRnVuY3Rpb24iLCJfb25VbmxvYWQiLCJfbWF4aW1pc2VkSXRlbSIsIl9tYXhpbWlzZVBsYWNlaG9sZGVyIiwiJCIsIl9jcmVhdGlvblRpbWVvdXRQYXNzZWQiLCJfc3ViV2luZG93c0NyZWF0ZWQiLCJfZHJhZ1NvdXJjZXMiLCJfdXBkYXRpbmdDb2x1bW5zUmVzcG9uc2l2ZSIsIl9maXJzdExvYWQiLCJ3aWR0aCIsImhlaWdodCIsInJvb3QiLCJvcGVuUG9wb3V0cyIsInNlbGVjdGVkSXRlbSIsImlzU3ViV2luZG93IiwiZXZlbnRIdWIiLCJFdmVudEh1YiIsIl9jcmVhdGVDb25maWciLCJkcm9wVGFyZ2V0SW5kaWNhdG9yIiwidHJhbnNpdGlvbkluZGljYXRvciIsInRhYkRyb3BQbGFjZWhvbGRlciIsImNzcyIsIl90eXBlVG9JdGVtIiwiUm93T3JDb2x1bW4iLCJTdGFjayIsIkNvbXBvbmVudCIsIkNvbmZpZ01pbmlmaWVyIiwibWluaWZ5Q29uZmlnIiwidW5taW5pZnlDb25maWciLCJuYW1lIiwiY29uc3RydWN0b3IiLCJFcnJvciIsInVuZGVmaW5lZCIsImNhbGxiYWNrIiwiX2NvbXBvbmVudEZ1bmN0aW9uIiwiY29uc29sZSIsIndhcm4iLCJuZXh0IiwiaSIsIkFic3RyYWN0Q29udGVudEl0ZW0iLCJzZXR0aW5ncyIsImNvcHkiLCJkaW1lbnNpb25zIiwibGFiZWxzIiwiY29udGVudCIsImNvbmZpZ05vZGUiLCJpdGVtIiwia2V5IiwiY29udGVudEl0ZW1zIiwibGVuZ3RoIiwiXyRyZWNvbmNpbGVQb3BvdXRXaW5kb3dzIiwicHVzaCIsInRvQ29uZmlnIiwibWF4aW1pc2VkSXRlbUlkIiwiZ2V0Q29tcG9uZW50TmFtZUZyb21Db25maWciLCJjb21wb25lbnRUb1VzZSIsIkNvbmZpZ3VyYXRpb25FcnJvciIsIl9jcmVhdGVTdWJXaW5kb3dzIiwiZG9jdW1lbnQiLCJyZWFkeVN0YXRlIiwiYm9keSIsInJlYWR5IiwiaW5pdCIsInNldFRpbWVvdXQiLCJfYWRqdXN0VG9XaW5kb3dNb2RlIiwiX3NldENvbnRhaW5lciIsIkRyb3BUYXJnZXRJbmRpY2F0b3IiLCJUcmFuc2l0aW9uSW5kaWNhdG9yIiwidXBkYXRlU2l6ZSIsIl9jcmVhdGUiLCJfYmluZEV2ZW50cyIsIl9hZGp1c3RDb2x1bW5zUmVzcG9uc2l2ZSIsImVtaXQiLCJhcmd1bWVudHMiLCJjYWxsRG93bndhcmRzIiwiZWxlbWVudCIsIndpbmRvdyIsIm9mZiIsInJlbW92ZSIsImRlc3Ryb3kiLCJmb3JFYWNoIiwiZHJhZ1NvdXJjZSIsIl9kcmFnTGlzdGVuZXIiLCJfZWxlbWVudCIsIl9pdGVtQ29uZmlnIiwidHlwZSIsImNvbXBvbmVudE5hbWUiLCJpc1JlYWN0Q29uZmlnIiwiY29tcG9uZW50IiwicGFyZW50IiwidHlwZUVycm9yTXNnIiwiY29udGVudEl0ZW0iLCJvYmplY3RLZXlzIiwiam9pbiIsIlJvb3QiLCJjb25maWdPckNvbnRlbnRJdGVtIiwicGFyZW50SWQiLCJpbmRleEluUGFyZW50IiwiaXNJdGVtIiwic2VsZiIsIndpbmRvd0xlZnQiLCJ3aW5kb3dUb3AiLCJvZmZzZXQiLCJjaGlsZCIsImJyb3dzZXJQb3BvdXQiLCJnZXRVbmlxdWVJZCIsImlzUm9vdCIsImFkZElkIiwiaXNOYU4iLCJpbmRleE9mIiwiQXJyYXkiLCJzY3JlZW5YIiwic2NyZWVuTGVmdCIsInNjcmVlblkiLCJzY3JlZW5Ub3AiLCJsZWZ0IiwidG9wIiwiQnJvd3NlclBvcG91dCIsIm9uIiwiaXRlbUNvbmZpZyIsImNvbnN0cmFpbkRyYWdUb0NvbnRhaW5lciIsIkRyYWdTb3VyY2UiLCJsbSIsInV0aWxzIiwicmVtb3ZlRnJvbUFycmF5IiwiXyRzaWxlbnQiLCJzZWxlY3Rpb25FbmFibGVkIiwiZGVzZWxlY3QiLCJzZWxlY3QiLCJfJG1pbmltaXNlSXRlbSIsIl8kY2xlYW51cEJlZm9yZU1heGltaXNlZEl0ZW1EZXN0cm95ZWQiLCJhZGRDbGFzcyIsImFmdGVyIiwicHJlcGVuZCIsInJlbW92ZUNsYXNzIiwicmVtb3ZlSWQiLCJldmVudCIsIm9yaWdpbiIsImNsb3NlIiwieCIsInkiLCJhcmVhIiwic21hbGxlc3RTdXJmYWNlIiwiSW5maW5pdHkiLCJtYXRoaW5nQXJlYSIsIngxIiwieDIiLCJ5MSIsInkyIiwic3VyZmFjZSIsImFyZWFTaXplIiwic2lkZXMiLCJzaWRlIiwiXyRnZXRBcmVhIiwiYWxsQ29udGVudEl0ZW1zIiwiX2dldEFsbENvbnRlbnRJdGVtcyIsIl8kY3JlYXRlUm9vdEl0ZW1BcmVhcyIsImlzU3RhY2siLCJjb25jYXQiLCJoZWFkZXIiLCJfY29udGVudEFyZWFEaW1lbnNpb25zIiwiaGlnaGxpZ2h0QXJlYSIsImNvbnRlbnRJdGVtT3JDb25maWciLCJpc0Z1bmN0aW9uIiwiaXNQbGFpbk9iamVjdCIsIm5ld0NvbnRlbnRJdGVtIiwiY3JlYXRlQ29udGVudEl0ZW0iLCJnZXRXaW5kb3ciLCJjbG9zZWQiLCJhZGRDaGlsZHJlbiIsInJlc2l6ZSIsImNsZWFyVGltZW91dCIsIndpbmRvd0NvbmZpZ0tleSIsImdldFF1ZXJ5U3RyaW5nUGFyYW0iLCJsb2NhbFN0b3JhZ2UiLCJnZXRJdGVtIiwiSlNPTiIsInBhcnNlIiwicmVtb3ZlSXRlbSIsImV4dGVuZCIsImRlZmF1bHRDb25maWciLCJuZXh0Tm9kZSIsIm5vZGUiLCJoYXNIZWFkZXJzIiwiaGVhZGVySGVpZ2h0IiwicG9wSW5CdXR0b24iLCJwb3BpbiIsImNsaWNrIiwidGl0bGUiLCJzdHJpcFRhZ3MiLCJhcHBlbmQiLCJodG1sIiwib2Zmc2V0SGVpZ2h0IiwiX19nbEluc3RhbmNlIiwicG9wb3V0IiwiY3JlYXRlUG9wb3V0IiwibWFyZ2luIiwicGFkZGluZyIsIm92ZXJmbG93IiwiZXJyb3JNc2ciLCJnZXRJdGVtc0J5SWQiLCJ0b2dnbGVNYXhpbWlzZSIsImNsb3NlUG9wb3V0c09uVW5sb2FkIiwiX3VzZVJlc3BvbnNpdmVMYXlvdXQiLCJtaW5JdGVtV2lkdGgiLCJpc1JvdyIsImNvbHVtbkNvdW50IiwidG90YWxNaW5XaWR0aCIsImZpbmFsQ29sdW1uQ291bnQiLCJNYXRoIiwibWF4IiwiZmxvb3IiLCJzdGFja0NvbHVtbkNvdW50Iiwicm9vdENvbnRlbnRJdGVtIiwiZmlyc3RTdGFja0NvbnRhaW5lciIsIl9maW5kQWxsU3RhY2tDb250YWluZXJzIiwiY29sdW1uIiwiX2FkZENoaWxkQ29udGVudEl0ZW1zVG9Db250YWluZXIiLCJyZXNwb25zaXZlTW9kZSIsImFkZENoaWxkIiwicmVtb3ZlQ2hpbGQiLCJzdGFja0NvbnRhaW5lcnMiLCJfZmluZEFsbFN0YWNrQ29udGFpbmVyc1JlY3Vyc2l2ZSIsImlzQ29tcG9uZW50IiwiRXZlbnRFbWl0dGVyIiwiaXRlbURlZmF1bHRDb25maWciLCJpc0Nsb3NhYmxlIiwicmVvcmRlckVuYWJsZWQiLCJwb3BvdXRXaG9sZVN0YWNrIiwiYmxvY2tlZFBvcG91dHNUaHJvd0Vycm9yIiwic2hvd1BvcG91dEljb24iLCJzaG93TWF4aW1pc2VJY29uIiwic2hvd0Nsb3NlSWNvbiIsInRhYk92ZXJsYXBBbGxvd2FuY2UiLCJyZW9yZGVyT25UYWJNZW51Q2xpY2siLCJ0YWJDb250cm9sT2Zmc2V0IiwiYm9yZGVyV2lkdGgiLCJib3JkZXJHcmFiV2lkdGgiLCJtaW5JdGVtSGVpZ2h0IiwiZHJhZ1Byb3h5V2lkdGgiLCJkcmFnUHJveHlIZWlnaHQiLCJtYXhpbWlzZSIsIm1pbmltaXNlIiwidGFiRHJvcGRvd24iLCJJdGVtQ29udGFpbmVyIiwibGF5b3V0TWFuYWdlciIsImlzSGlkZGVuIiwiX2NvbmZpZyIsIl9jb250ZW50RWxlbWVudCIsImZpbmQiLCJoaWRlIiwic2hvdyIsInJvd09yQ29sdW1uIiwicm93T3JDb2x1bW5DaGlsZCIsInRvdGFsUGl4ZWwiLCJwZXJjZW50YWdlIiwiZGlyZWN0aW9uIiwibmV3U2l6ZSIsImRlbHRhIiwiaXNDb2x1bW4iLCJjb21wb25lbnRTdGF0ZSIsInN0YXRlIiwic2V0U3RhdGUiLCJnZXRTdGF0ZSIsImVtaXRCdWJibGluZ0V2ZW50Iiwic2V0VGl0bGUiLCJ6ZXB0byIsIm91dGVyV2lkdGgiLCJvdXRlckhlaWdodCIsIl9kaW1lbnNpb25zIiwiX3BhcmVudElkIiwiX2luZGV4SW5QYXJlbnQiLCJfbGF5b3V0TWFuYWdlciIsIl9wb3BvdXRXaW5kb3ciLCJfaWQiLCJfY3JlYXRlV2luZG93IiwiZ2V0R2xJbnN0YW5jZSIsIl8kY2xvc2VXaW5kb3ciLCJlIiwiY2hpbGRDb25maWciLCJwYXJlbnRJdGVtIiwiaW5kZXgiLCJjaGVja1JlYWR5SW50ZXJ2YWwiLCJ1cmwiLCJfY3JlYXRlVXJsIiwicmFuZG9tIiwidG9TdHJpbmciLCJvcHRpb25zIiwiX3NlcmlhbGl6ZVdpbmRvd09wdGlvbnMiLCJpbm5lcldpZHRoIiwiaW5uZXJIZWlnaHQiLCJtZW51YmFyIiwidG9vbGJhciIsImxvY2F0aW9uIiwicGVyc29uYWxiYXIiLCJyZXNpemFibGUiLCJzY3JvbGxiYXJzIiwic3RhdHVzIiwib3BlbiIsImVycm9yIiwiX3Bvc2l0aW9uV2luZG93IiwiX29uQ2xvc2UiLCJzZXRJbnRlcnZhbCIsIl9vbkluaXRpYWxpc2VkIiwiY2xlYXJJbnRlcnZhbCIsIndpbmRvd09wdGlvbnMiLCJ3aW5kb3dPcHRpb25zU3RyaW5nIiwic3RvcmFnZUtleSIsInVybFBhcnRzIiwic2V0SXRlbSIsInN0cmluZ2lmeSIsImhyZWYiLCJzcGxpdCIsIm1vdmVUbyIsImZvY3VzIiwicG9wSW4iLCJfdGVtcGxhdGUiLCJEcmFnUHJveHkiLCJkcmFnTGlzdGVuZXIiLCJvcmlnaW5hbFBhcmVudCIsIl9jb250ZW50SXRlbSIsIl9vcmlnaW5hbFBhcmVudCIsIl9hcmVhIiwiX2xhc3RWYWxpZEFyZWEiLCJfb25EcmFnIiwiX29uRHJvcCIsIl9zaWRlIiwiX3NpZGVkIiwiYXR0ciIsImNoaWxkRWxlbWVudENvbnRhaW5lciIsIl91bmRpc3BsYXlUcmVlIiwiXyRjYWxjdWxhdGVJdGVtQXJlYXMiLCJfc2V0RGltZW5zaW9ucyIsIl9taW5YIiwiX21pblkiLCJfbWF4WCIsIl9tYXhZIiwiX3dpZHRoIiwiX2hlaWdodCIsIl9zZXREcm9wUG9zaXRpb24iLCJvZmZzZXRYIiwib2Zmc2V0WSIsImdldFRvdWNoRXZlbnQiLCJwYWdlWCIsInBhZ2VZIiwiaXNXaXRoaW5Db250YWluZXIiLCJfJGhpZ2hsaWdodERyb3Bab25lIiwiX3VwZGF0ZVRyZWUiLCJfJG9uRHJvcCIsIl8kZGVzdHJveSIsInVuZGlzcGxheUNoaWxkIiwiXyRzZXRQYXJlbnQiLCJfY3JlYXRlRHJhZ0xpc3RlbmVyIiwiX3JlbW92ZURyYWdMaXN0ZW5lciIsIkRyYWdMaXN0ZW5lciIsIl9vbkRyYWdTdGFydCIsIl8kbm9ybWFsaXplQ29udGVudEl0ZW0iLCJkcmFnUHJveHkiLCJ0cmFuc2l0aW9uRWxlbWVudHMiLCJIZWFkZXIiLCJfb25IZWFkZXJDbGljayIsInRhYnNDb250YWluZXIiLCJ0YWJEcm9wZG93bkNvbnRhaW5lciIsImNvbnRyb2xzQ29udGFpbmVyIiwiX3VwZGF0ZVRhYlNpemVzIiwidGFicyIsInRhYnNNYXJrZWRGb3JSZW1vdmFsIiwiYWN0aXZlQ29udGVudEl0ZW0iLCJjbG9zZUJ1dHRvbiIsImRvY2tCdXR0b24iLCJ0YWJEcm9wZG93bkJ1dHRvbiIsImhpZGVBZGRpdGlvbmFsVGFic0Ryb3Bkb3duIiwiX2hpZGVBZGRpdGlvbmFsVGFic0Ryb3Bkb3duIiwibW91c2V1cCIsIl9sYXN0VmlzaWJsZVRhYkluZGV4IiwiX3RhYkNvbnRyb2xPZmZzZXQiLCJfY3JlYXRlQ29udHJvbHMiLCJ0YWIiLCJUYWIiLCJiZWZvcmUiLCJzcGxpY2UiLCJqIiwiaXNBY3RpdmUiLCJhY3RpdmVUYWIiLCJzZXRBY3RpdmUiLCJhY3RpdmVJdGVtSW5kZXgiLCJwb3NpdGlvbiIsInByZXZpb3VzIiwiX2hlYWRlciIsIl9kb2NrZXIiLCJkb2NrZWQiLCJfc2V0dXBIZWFkZXJQb3NpdGlvbiIsIl9jYW5EZXN0cm95IiwiX2lzQ2xvc2FibGUiLCJpc0RvY2thYmxlIiwiZG9jayIsInRvZ2dsZSIsImNsb3NlU3RhY2siLCJsYWJlbCIsIm1heGltaXNlTGFiZWwiLCJtaW5pbWlzZUxhYmVsIiwibWF4aW1pc2VCdXR0b24iLCJ0YWJEcm9wZG93bkxhYmVsIiwic2hvd1RhYkRyb3Bkb3duIiwiX3Nob3dBZGRpdGlvbmFsVGFic0Ryb3Bkb3duIiwiSGVhZGVyQnV0dG9uIiwiYnV0dG9uIiwiX2dldEhlYWRlclNldHRpbmciLCJfb25Qb3BvdXRDbGljayIsInRhcmdldCIsInNob3dUYWJNZW51Iiwic2l6ZSIsInZhbCIsImF2YWlsYWJsZVdpZHRoIiwiY3VtdWxhdGl2ZVRhYldpZHRoIiwidmlzaWJsZVRhYldpZHRoIiwidGFiRWxlbWVudCIsIm1hcmdpbkxlZnQiLCJvdmVybGFwIiwidGFiV2lkdGgiLCJ0YWJPdmVybGFwQWxsb3dhbmNlRXhjZWVkZWQiLCJhY3RpdmVJbmRleCIsInBhcnNlSW50IiwiY3NzQ2xhc3MiLCJhY3Rpb24iLCJfYWN0aW9uIiwiU3BsaXR0ZXIiLCJpc1ZlcnRpY2FsIiwiZ3JhYlNpemUiLCJfaXNWZXJ0aWNhbCIsIl9zaXplIiwiX2dyYWJTaXplIiwiX2NyZWF0ZUVsZW1lbnQiLCJjb250ZXh0IiwiZHJhZ0hhbmRsZSIsImhhbmRsZUV4Y2Vzc1NpemUiLCJoYW5kbGVFeGNlc3NQb3MiLCJ0aXRsZUVsZW1lbnQiLCJjbG9zZUVsZW1lbnQiLCJfb25UYWJDbGlja0ZuIiwiX29uVGFiQ2xpY2siLCJfb25DbG9zZUNsaWNrRm4iLCJfb25DbG9zZUNsaWNrIiwiX29uQ2xvc2VNb3VzZWRvd24iLCJpc01heGltaXNlZCIsInNldEFjdGl2ZUNvbnRlbnRJdGVtIiwic3RvcFByb3BhZ2F0aW9uIiwiX3RvRWxlbWVudCIsIl9mcm9tRGltZW5zaW9ucyIsIl90b3RhbEFuaW1hdGlvbkR1cmF0aW9uIiwiX2FuaW1hdGlvblN0YXJ0VGltZSIsImZyb21FbGVtZW50IiwidG9FbGVtZW50IiwidG9EaW1lbnNpb25zIiwiX21lYXN1cmUiLCJhbmltYXRpb25Qcm9ncmVzcyIsIm5vdyIsImN1cnJlbnRGcmFtZVN0eWxlcyIsImNzc1Byb3BlcnR5Iiwib3BhY2l0eSIsImFuaW1GcmFtZSIsIl9uZXh0QW5pbWF0aW9uRnJhbWUiLCJtZXNzYWdlIiwiX2V4dGVuZEl0ZW1Ob2RlIiwiX3BlbmRpbmdFdmVudFByb3BhZ2F0aW9ucyIsIl90aHJvdHRsZWRFdmVudHMiLCJBTExfRVZFTlQiLCJfcHJvcGFnYXRlRXZlbnQiLCJfY3JlYXRlQ29udGVudEl0ZW1zIiwiZnVuY3Rpb25OYW1lIiwiZnVuY3Rpb25Bcmd1bWVudHMiLCJib3R0b21VcCIsInNraXBTZWxmIiwiYXBwbHkiLCJrZWVwQ2hpbGQiLCJfJGluaXQiLCJvbGRDaGlsZCIsIm5ld0NoaWxkIiwiXyRkZXN0cm95T2xkQ2hpbGQiLCJwYXJlbnROb2RlIiwicmVwbGFjZUNoaWxkIiwicHJldmVudERlZmF1bHQiLCJfJG1heGltaXNlSXRlbSIsInNlbGVjdEl0ZW0iLCJpZCIsImhhc0lkIiwiZmlsdGVyIiwicmVzdWx0IiwiZ2V0SXRlbXNCeUZpbHRlciIsIl8kZ2V0SXRlbXNCeVByb3BlcnR5IiwiY29tcG9uZW50cyIsImluc3RhbmNlcyIsImluc3RhbmNlIiwidmFsdWUiLCJfY2FsbE9uQWN0aXZlQ29tcG9uZW50cyIsIm1ldGhvZE5hbWUiLCJzdGFja3MiLCJnZXRJdGVtc0J5VHlwZSIsImdldEFjdGl2ZUNvbnRlbnRJdGVtIiwic2V0U2l6ZSIsIkJ1YmJsaW5nRXZlbnQiLCJvQ29udGVudEl0ZW0iLCJpc1Byb3BhZ2F0aW9uU3RvcHBlZCIsInByb3RvdHlwZSIsInNsaWNlIiwiY2FsbCIsIl9zY2hlZHVsZUV2ZW50UHJvcGFnYXRpb25Ub0xheW91dE1hbmFnZXIiLCJfcHJvcGFnYXRlRXZlbnRUb0xheW91dE1hbmFnZXIiLCJDb21wb25lbnRDb25zdHJ1Y3RvciIsIlJlYWN0Q29tcG9uZW50SGFuZGxlciIsImdldENvbXBvbmVudCIsImNvbXBvbmVudENvbmZpZyIsIl8kc2V0U2l6ZSIsIl8kaGlkZSIsIl8kc2hvdyIsInNob3duIiwiXyRzaG93biIsImNvbnRhaW5lckVsZW1lbnQiLCJfY29udGFpbmVyRWxlbWVudCIsInN0YWNrIiwiZGltZW5zaW9uIiwiaW5zZXJ0QmVmb3JlIiwic2liYmxpbmciLCJfc3BsaXR0ZXJTaXplIiwiX3NwbGl0dGVyR3JhYlNpemUiLCJfaXNDb2x1bW4iLCJfZGltZW5zaW9uIiwiX3NwbGl0dGVyIiwiX3NwbGl0dGVyUG9zaXRpb24iLCJfc3BsaXR0ZXJNaW5Qb3NpdGlvbiIsIl9zcGxpdHRlck1heFBvc2l0aW9uIiwiXyRzdXNwZW5kUmVzaXplIiwibmV3SXRlbVNpemUiLCJpdGVtU2l6ZSIsInNwbGl0dGVyRWxlbWVudCIsIl9jcmVhdGVTcGxpdHRlciIsIl9pc0RvY2tlZCIsIl92YWxpZGF0ZURvY2tpbmciLCJ1bmRpc3BsYXllZEl0ZW1TaXplIiwic3BsaXR0ZXJJbmRleCIsImNoaWxkSXRlbSIsInJlbW92ZWRJdGVtU2l6ZSIsIl9jYWxjdWxhdGVSZWxhdGl2ZVNpemVzIiwiX3NldEFic29sdXRlU2l6ZXMiLCJtb2RlIiwiY29sbGFwc2VkIiwiaGVhZGVyU2l6ZSIsImlzRG9ja2VkIiwiYXV0b3NpZGUiLCJmaXJzdCIsImxhc3QiLCJyb3ciLCJyZXF1aXJlZCIsInJlYWxTaXplIiwidG9nZ2xlQ2xhc3MiLCJzaXplRGF0YSIsIl9jYWxjdWxhdGVBYnNvbHV0ZVNpemVzIiwiYWRkaXRpb25hbFBpeGVsIiwiaXRlbVNpemVzIiwidG90YWxXaWR0aCIsInRvdGFsSGVpZ2h0IiwidG90YWxTcGxpdHRlclNpemUiLCJ0b3RhbEFzc2lnbmVkIiwidG90YWwiLCJpdGVtc1dpdGhvdXRTZXREaW1lbnNpb24iLCJyb3VuZCIsIl9yZXNwZWN0TWluSXRlbVdpZHRoIiwiZW50cmllc092ZXJNaW4iLCJ0b3RhbE92ZXJNaW4iLCJ0b3RhbFVuZGVyTWluIiwicmVtYWluaW5nV2lkdGgiLCJyZWR1Y2VQZXJjZW50IiwicmVkdWNlZFdpZHRoIiwiYWxsRW50cmllcyIsImVudHJ5Iiwic3BsaXR0ZXIiLCJfb25TcGxpdHRlckRyYWciLCJfb25TcGxpdHRlckRyYWdTdG9wIiwiX29uU3BsaXR0ZXJEcmFnU3RhcnQiLCJjb3VudCIsInRoYXQiLCJjYW4iLCJfc2V0RG9ja2FibGUiLCJfJHNldENsb3NhYmxlIiwiYXJyIiwibWluV2lkdGgiLCJtaW5IZWlnaHQiLCJob3Jpem9udGFsIiwidmVydGljYWwiLCJpdGVtcyIsIl9nZXRJdGVtc0ZvclNwbGl0dGVyIiwibWluU2l6ZSIsImJlZm9yZU1pbkRpbSIsIl9nZXRNaW5pbXVtRGltZW5zaW9ucyIsImJlZm9yZU1pblNpemUiLCJhZnRlck1pbkRpbSIsImFmdGVyTWluU2l6ZSIsInNpemVCZWZvcmUiLCJzaXplQWZ0ZXIiLCJzcGxpdHRlclBvc2l0aW9uSW5SYW5nZSIsInRvdGFsUmVsYXRpdmVTaXplIiwiX2FjdGl2ZUNvbnRlbnRJdGVtIiwiY2ZnIiwiX2Ryb3Bab25lcyIsIl9kcm9wU2VnbWVudCIsIl9kcm9wSW5kZXgiLCJfJHZhbGlkYXRlQ2xvc2FiaWxpdHkiLCJpbml0aWFsSXRlbSIsImNyZWF0ZVRhYiIsInJlbW92ZVRhYiIsImhpZGVUYWIiLCJsZW4iLCJfcmVzZXRIZWFkZXJEcm9wWm9uZSIsImlzSG9yaXpvbnRhbCIsImhhc0NvcnJlY3RQYXJlbnQiLCJzZWdtZW50IiwiaG92ZXJBcmVhIiwiX2hpZ2hsaWdodEhlYWRlckRyb3Bab25lIiwiX2hpZ2hsaWdodEJvZHlEcm9wWm9uZSIsImdldEFyZWEiLCJoZWFkZXJBcmVhIiwiY29udGVudEFyZWEiLCJjb250ZW50V2lkdGgiLCJjb250ZW50SGVpZ2h0IiwicmlnaHQiLCJib3R0b20iLCJ0YWJzTGVuZ3RoIiwiaXNBYm92ZVRhYiIsInRhYlRvcCIsInRhYkxlZnQiLCJwbGFjZUhvbGRlckxlZnQiLCJoZWFkZXJPZmZzZXQiLCJoYWxmWCIsIm1pbiIsInBsYWNlSG9sZGVyVG9wIiwiaGVhZGVyUG9zaXRpb24iLCJfa2V5cyIsIl92YWx1ZXMiLCJfbmV4dExldmVsIiwibWluaWZpZWRDb25maWciLCJvcmlnIiwiZnJvbSIsInRvIiwidHJhbnNsYXRpb25GbiIsIm1pbktleSIsImhhc093blByb3BlcnR5IiwiZGljdGlvbmFyeSIsInN1YnN0ciIsImVFbGVtZW50IiwibkJ1dHRvbkNvZGUiLCJfdGltZW91dCIsIl9lRWxlbWVudCIsIl9vRG9jdW1lbnQiLCJfZUJvZHkiLCJfbkJ1dHRvbkNvZGUiLCJfbkRlbGF5IiwiX25EaXN0YW5jZSIsIl9uWCIsIl9uWSIsIl9uT3JpZ2luYWxYIiwiX25PcmlnaW5hbFkiLCJfYkRyYWdnaW5nIiwiX2ZNb3ZlIiwib25Nb3VzZU1vdmUiLCJfZlVwIiwib25Nb3VzZVVwIiwiX2ZEb3duIiwib25Nb3VzZURvd24iLCJ1bmJpbmQiLCJvRXZlbnQiLCJjb29yZGluYXRlcyIsIl9nZXRDb29yZGluYXRlcyIsIm9uZSIsIl9zdGFydERyYWciLCJhYnMiLCJfbVN1YnNjcmlwdGlvbnMiLCJzRXZlbnQiLCJmQ2FsbGJhY2siLCJvQ29udGV4dCIsImZuIiwiY3R4IiwiYXJncyIsInN1YnMiLCJ1bnNoaWZ0IiwiYWxsRXZlbnRTdWJzIiwiYlVuYm91bmQiLCJ0cmlnZ2VyIiwiX2RvbnRQcm9wYWdhdGVUb1BhcmVudCIsIl9jaGlsZEV2ZW50U291cmNlIiwiX29uRXZlbnRGcm9tVGhpcyIsIl9ib3VuZE9uRXZlbnRGcm9tQ2hpbGQiLCJfb25FdmVudEZyb21DaGlsZCIsIl9wcm9wYWdhdGVUb1BhcmVudCIsIl9wcm9wYWdhdGVUb0NoaWxkcmVuIiwib3JpZ2luYWxFdmVudCIsIl9fZ2wiLCJfX2dsQXJncyIsImV2ZW50TmFtZSIsImNyZWF0ZUV2ZW50Iiwib3BlbmVyIiwiaW5pdEV2ZW50IiwiY3JlYXRlRXZlbnRPYmplY3QiLCJldmVudFR5cGUiLCJkaXNwYXRjaEV2ZW50IiwiZmlyZUV2ZW50IiwiY2hpbGRHbCIsIl8kb25FdmVudEZyb21QYXJlbnQiLCJfcmVhY3RDb21wb25lbnQiLCJfb3JpZ2luYWxDb21wb25lbnRXaWxsVXBkYXRlIiwiX2NvbnRhaW5lciIsIl9pbml0aWFsU3RhdGUiLCJfcmVhY3RDbGFzcyIsIl9nZXRSZWFjdENsYXNzIiwiX3JlbmRlciIsIl9kZXN0cm95IiwiUmVhY3RET00iLCJyZW5kZXIiLCJfZ2V0UmVhY3RDb21wb25lbnQiLCJnZXRFbGVtZW50IiwiY29tcG9uZW50V2lsbFVwZGF0ZSIsIl9vblVwZGF0ZSIsImJpbmQiLCJ1bm1vdW50Q29tcG9uZW50QXROb2RlIiwibmV4dFByb3BzIiwibmV4dFN0YXRlIiwicmVhY3RDbGFzcyIsImRlZmF1bHRQcm9wcyIsImdsRXZlbnRIdWIiLCJnbENvbnRhaW5lciIsInJlZiIsIl9nb3RSZWFjdENvbXBvbmVudCIsInByb3BzIiwiUmVhY3QiLCJjcmVhdGVFbGVtZW50IiwiRiIsInRvdWNoZXMiLCJ0YXJnZXRUb3VjaGVzIiwic3ViQ2xhc3MiLCJzdXBlckNsYXNzIiwiY3JlYXRlT2JqZWN0IiwiY29udHJ1Y3RvciIsIk9iamVjdCIsImNyZWF0ZSIsIm9iamVjdCIsImtleXMiLCJnZXRIYXNoVmFsdWUiLCJtYXRjaGVzIiwiaGFzaCIsIm1hdGNoIiwiUmVnRXhwIiwicGFyYW0iLCJzZWFyY2giLCJrZXlWYWx1ZVBhaXJzIiwicGFyYW1zIiwicGFpciIsInNvdXJjZSIsInJlcXVlc3RBbmltYXRpb25GcmFtZSIsIndlYmtpdFJlcXVlc3RBbmltYXRpb25GcmFtZSIsIm1velJlcXVlc3RBbmltYXRpb25GcmFtZSIsIm5lZWRsZSIsImhheXN0YWNrIiwiSW50OEFycmF5Iiwib2JqIiwiYm91bmRBcmdzIiwiRnVuY3Rpb24iLCJib3VuZCIsImFycmF5IiwiRGF0ZSIsImdldFRpbWUiLCJy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Q0FBQyxDQUFDbXdCLElBQUYsQ0FBT0gsS0FBSyxDQUFDRixPQUFOLENBQWMsZUFBZCxFQUErQixFQUEvQixDQUFQLENBQVA7QUFDSCxDOzs7Ozs7Ozs7OztBQzNNRCxvRCIsImZpbGUiOiJnb2xkZW4tbGF5b3V0LmpzIiwic291cmNlc0NvbnRlbnQiOlsiKGZ1bmN0aW9uIHdlYnBhY2tVbml2ZXJzYWxNb2R1bGVEZWZpbml0aW9uKHJvb3QsIGZhY3RvcnkpIHtcblx0aWYodHlwZW9mIGV4cG9ydHMgPT09ICdvYmplY3QnICYmIHR5cGVvZiBtb2R1bGUgPT09ICdvYmplY3QnKVxuXHRcdG1vZHVsZS5leHBvcnRzID0gZmFjdG9yeShyZXF1aXJlKFwianF1ZXJ5XCIpKTtcblx0ZWxzZSBpZih0eXBlb2YgZGVmaW5lID09PSAnZnVuY3Rpb24nICYmIGRlZmluZS5hbWQpXG5cdFx0ZGVmaW5lKFtcImpxdWVyeVwiXSwgZmFjdG9yeSk7XG5cdGVsc2UgaWYodHlwZW9mIGV4cG9ydHMgPT09ICdvYmplY3QnKVxuXHRcdGV4cG9ydHNbXCJHb2xkZW5MYXlvdXRcIl0gPSBmYWN0b3J5KHJlcXVpcmUoXCJqcXVlcnlcIikpO1xuXHRlbHNlXG5cdFx0cm9vdFtcIkdvbGRlbkxheW91dFwiXSA9IGZhY3Rvcnkocm9vdFtcIiRcIl0pO1xufSkod2luZG93LCBmdW5jdGlvbihfX1dFQlBBQ0tfRVhURVJOQUxfTU9EVUxFX2pxdWVyeV9fKSB7XG5yZXR1cm4gIiwiIFx0Ly8gVGhlIG1vZHVsZSBjYWNoZVxuIFx0dmFyIGluc3RhbGxlZE1vZHVsZXMgPSB7fTtcblxuIFx0Ly8gVGhlIHJlcXVpcmUgZnVuY3Rpb25cbiBcdGZ1bmN0aW9uIF9fd2VicGFja19yZXF1aXJlX18obW9kdWxlSWQpIHtcblxuIFx0XHQvLyBDaGVjayBpZiBtb2R1bGUgaXMgaW4gY2FjaGVcbiBcdFx0aWYoaW5zdGFsbGVkTW9kdWxlc1ttb2R1bGVJZF0pIHtcbiBcdFx0XHRyZXR1cm4gaW5zdGFsbGVkTW9kdWxlc1ttb2R1bGVJZF0uZXhwb3J0cztcbiBcdFx0fVxuIFx0XHQvLyBDcmVhdGUgYSBuZXcgbW9kdWxlIChhbmQgcHV0IGl0IGludG8gdGhlIGNhY2hlKVxuIFx0XHR2YXIgbW9kdWxlID0gaW5zdGFsbGVkTW9kdWxlc1ttb2R1bGVJZF0gPSB7XG4gXHRcdFx0aTogbW9kdWxlSWQsXG4gXHRcdFx0bDogZmFsc2UsXG4gXHRcdFx0ZXhwb3J0czoge31cbiBcdFx0fTtcblxuIFx0XHQvLyBFeGVjdXRlIHRoZSBtb2R1bGUgZnVuY3Rpb25cbiBcdFx0bW9kdWxlc1ttb2R1bGVJZF0uY2FsbChtb2R1bGUuZXhwb3J0cywgbW9kdWxlLCBtb2R1bGUuZXhwb3J0cywgX193ZWJwYWNrX3JlcXVpcmVfXyk7XG5cbiBcdFx0Ly8gRmxhZyB0aGUgbW9kdWxlIGFzIGxvYWRlZFxuIFx0XHRtb2R1bGUubCA9IHRydWU7XG5cbiBcdFx0Ly8gUmV0dXJuIHRoZSBleHBvcnRzIG9mIHRoZSBtb2R1bGVcbiBcdFx0cmV0dXJuIG1vZHVsZS5leHBvcnRzO1xuIFx0fVxuXG5cbiBcdC8vIGV4cG9zZSB0aGUgbW9kdWxlcyBvYmplY3QgKF9fd2VicGFja19tb2R1bGVzX18pXG4gXHRfX3dlYnBhY2tfcmVxdWlyZV9fLm0gPSBtb2R1bGVzO1xuXG4gXHQvLyBleHBvc2UgdGhlIG1vZHVsZSBjYWNoZVxuIFx0X193ZWJwYWNrX3JlcXVpcmVfXy5jID0gaW5zdGFsbGVkTW9kdWxlcztcblxuIFx0Ly8gZGVmaW5lIGdldHRlciBmdW5jdGlvbiBmb3IgaGFybW9ueSBleHBvcnRzXG4gXHRfX3dlYnBhY2tfcmVxdWlyZV9fLmQgPSBmdW5jdGlvbihleHBvcnRzLCBuYW1lLCBnZXR0ZXIpIHtcbiBcdFx0aWYoIV9fd2VicGFja19yZXF1aXJlX18ubyhleHBvcnRzLCBuYW1lKSkge1xuIFx0XHRcdE9iamVjdC5kZWZpbmVQcm9wZXJ0eShleHBvcnRzLCBuYW1lLCB7IGVudW1lcmFibGU6IHRydWUsIGdldDogZ2V0dGVyIH0pO1xuIFx0XHR9XG4gXHR9O1xuXG4gXHQvLyBkZWZpbmUgX19lc01vZHVsZSBvbiBleHBvcnRzXG4gXHRfX3dlYnBhY2tfcmVxdWlyZV9fLnIgPSBmdW5jdGlvbihleHBvcnRzKSB7XG4gXHRcdGlmKHR5cGVvZiBTeW1ib2wgIT09ICd1bmRlZmluZWQnICYmIFN5bWJvbC50b1N0cmluZ1RhZykge1xuIFx0XHRcdE9iamVjdC5kZWZpbmVQcm9wZXJ0eShleHBvcnRzLCBTeW1ib2wudG9TdHJpbmdUYWcsIHsgdmFsdWU6ICdNb2R1bGUnIH0pO1xuIFx0XHR9XG4gXHRcdE9iamVjdC5kZWZpbmVQcm9wZXJ0eShleHBvcnRzLCAnX19lc01vZHVsZScsIHsgdmFsdWU6IHRydWUgfSk7XG4gXHR9O1xuXG4gXHQvLyBjcmVhdGUgYSBmYWtlIG5hbWVzcGFjZSBvYmplY3RcbiBcdC8vIG1vZGUgJiAxOiB2YWx1ZSBpcyBhIG1vZHVsZSBpZCwgcmVxdWlyZSBpdFxuIFx0Ly8gbW9kZSAmIDI6IG1lcmdlIGFsbCBwcm9wZXJ0aWVzIG9mIHZhbHVlIGludG8gdGhlIG5zXG4gXHQvLyBtb2RlICYgNDogcmV0dXJuIHZhbHVlIHdoZW4gYWxyZWFkeSBucyBvYmplY3RcbiBcdC8vIG1vZGUgJiA4fDE6IGJlaGF2ZSBsaWtlIHJlcXVpcmVcbiBcdF9fd2VicGFja19yZXF1aXJlX18udCA9IGZ1bmN0aW9uKHZhbHVlLCBtb2RlKSB7XG4gXHRcdGlmKG1vZGUgJiAxKSB2YWx1ZSA9IF9fd2VicGFja19yZXF1aXJlX18odmFsdWUpO1xuIFx0XHRpZihtb2RlICYgOCkgcmV0dXJuIHZhbHVlO1xuIFx0XHRpZigobW9kZSAmIDQpICYmIHR5cGVvZiB2YWx1ZSA9PT0gJ29iamVjdCcgJiYgdmFsdWUgJiYgdmFsdWUuX19lc01vZHVsZSkgcmV0dXJuIHZhbHVlO1xuIFx0XHR2YXIgbnMgPSBPYmplY3QuY3JlYXRlKG51bGwpO1xuIFx0XHRfX3dlYnBhY2tfcmVxdWlyZV9fLnIobnMpO1xuIFx0XHRPYmplY3QuZGVmaW5lUHJvcGVydHkobnMsICdkZWZhdWx0JywgeyBlbnVtZXJhYmxlOiB0cnVlLCB2YWx1ZTogdmFsdWUgfSk7XG4gXHRcdGlmKG1vZGUgJiAyICYmIHR5cGVvZiB2YWx1ZSAhPSAnc3RyaW5nJykgZm9yKHZhciBrZXkgaW4gdmFsdWUpIF9fd2VicGFja19yZXF1aXJlX18uZChucywga2V5LCBmdW5jdGlvbihrZXkpIHsgcmV0dXJuIHZhbHVlW2tleV07IH0uYmluZChudWxsLCBrZXkpKTtcbiBcdFx0cmV0dXJuIG5zO1xuIFx0fTtcblxuIFx0Ly8gZ2V0RGVmYXVsdEV4cG9ydCBmdW5jdGlvbiBmb3IgY29tcGF0aWJpbGl0eSB3aXRoIG5vbi1oYXJtb255IG1vZHVsZXNcbiBcdF9fd2VicGFja19yZXF1aXJlX18ubiA9IGZ1bmN0aW9uKG1vZHVsZSkge1xuIFx0XHR2YXIgZ2V0dGVyID0gbW9kdWxlICYmIG1vZHVsZS5fX2VzTW9kdWxlID9cbiBcdFx0XHRmdW5jdGlvbiBnZXREZWZhdWx0KCkgeyByZXR1cm4gbW9kdWxlWydkZWZhdWx0J107IH0gOlxuIFx0XHRcdGZ1bmN0aW9uIGdldE1vZHVsZUV4cG9ydHMoKSB7IHJldHVybiBtb2R1bGU7IH07XG4gXHRcdF9fd2VicGFja19yZXF1aXJlX18uZChnZXR0ZXIsICdhJywgZ2V0dGVyKTtcbiBcdFx0cmV0dXJuIGdldHRlcjtcbiBcdH07XG5cbiBcdC8vIE9iamVjdC5wcm90b3R5cGUuaGFzT3duUHJvcGVydHkuY2FsbFxuIFx0X193ZWJwYWNrX3JlcXVpcmVfXy5vID0gZnVuY3Rpb24ob2JqZWN0LCBwcm9wZXJ0eSkgeyByZXR1cm4gT2JqZWN0LnByb3RvdHlwZS5oYXNPd25Qcm9wZXJ0eS5jYWxsKG9iamVjdCwgcHJvcGVydHkpOyB9O1xuXG4gXHQvLyBfX3dlYnBhY2tfcHVibGljX3BhdGhfX1xuIFx0X193ZWJwYWNrX3JlcXVpcmVfXy5wID0gXCJcIjtcblxuXG4gXHQvLyBMb2FkIGVudHJ5IG1vZHVsZSBhbmQgcmV0dXJuIGV4cG9ydHNcbiBcdHJldHVybiBfX3dlYnBhY2tfcmVxdWlyZV9fKF9fd2VicGFja19yZXF1aXJlX18ucyA9IFwiLi9zcmMvaW5kZXguanNcIik7XG4iLCIvLyBoZWxwZXIgZmlsZSBmb3Igd2VicGFjayBidWlsZCBzeXN0ZW1cbi8vIHdoYXRldmVyIGlzIGltcG9ydGVkL2V4cG9ydGVkIGhlcmUgd2lsbCBiZSBpbmNsdWRlZCBpbiB0aGUgYnVpbGRcbi8vaW1wb3J0ICdsZXNzL3Rlc3QubGVzcydcbi8vaW1wb3J0ICcuL2xlc3MvZ29sZGVubGF5b3V0LWJhc2UubGVzcydcbi8vaW1wb3J0ICcuL2xlc3MvZ29sZGVubGF5b3V0LWRhcmstdGhlbWUubGVzcydcbi8vXG4vLyBMYXlvdXRcbmV4cG9ydCB7IGRlZmF1bHQgfSBmcm9tICcuL2pzX2VzNi9MYXlvdXRNYW5hZ2VyJ1xuLy9cbi8vIGNvbnRhaW5lclxuZXhwb3J0IHsgZGVmYXVsdCBhcyBJdGVtQ29udGFpbmVyIH0gZnJvbSAnLi9qc19lczYvY29udGFpbmVyL0l0ZW1Db250YWluZXInXG4vL1xuLy8gY29udHJvbHNcbmV4cG9ydCB7IGRlZmF1bHQgYXMgQnJvd3NlclBvcG91dCB9IGZyb20gJy4vanNfZXM2L2NvbnRyb2xzL0Jyb3dzZXJQb3BvdXQnXG5leHBvcnQgeyBkZWZhdWx0IGFzIEhlYWRlciB9IGZyb20gJy4vanNfZXM2L2NvbnRyb2xzL0hlYWRlcidcbmV4cG9ydCB7IGRlZmF1bHQgYXMgSGVhZGVyQnV0dG9uIH0gZnJvbSAnLi9qc19lczYvY29udHJvbHMvSGVhZGVyQnV0dG9uJ1xuZXhwb3J0IHsgZGVmYXVsdCBhcyBUYWIgfSBmcm9tICcuL2pzX2VzNi9jb250cm9scy9UYWInXG4vL1xuLy8gaXRlbXNcbmV4cG9ydCB7IGRlZmF1bHQgYXMgQ29tcG9uZW50IH0gZnJvbSAnLi9qc19lczYvaXRlbXMvQ29tcG9uZW50J1xuZXhwb3J0IHsgZGVmYXVsdCBhcyBSb290IH0gZnJvbSAnLi9qc19lczYvaXRlbXMvUm9vdCdcbmV4cG9ydCB7IGRlZmF1bHQgYXMgUm93T3JDb2x1bW4gfSBmcm9tICcuL2pzX2VzNi9pdGVtcy9Sb3dPckNvbHVtbidcbmV4cG9ydCB7IGRlZmF1bHQgYXMgU3RhY2sgfSBmcm9tICcuL2pzX2VzNi9pdGVtcy9TdGFjaydcbi8vXG4vLyB1dGlsc1xuZXhwb3J0IHsgZGVmYXVsdCBhcyBCdWJibGluZ0V2ZW50IH0gZnJvbSAnLi9qc19lczYvdXRpbHMvQnViYmxpbmdFdmVudCdcbmV4cG9ydCB7IGRlZmF1bHQgYXMgQ29uZmlnTWluaWZpZXIgfSBmcm9tICcuL2pzX2VzNi91dGlscy9Db25maWdNaW5pZmllcidcbmV4cG9ydCB7IGRlZmF1bHQgYXMgRHJhZ0xpc3RlbmVyIH0gZnJvbSAnLi9qc19lczYvdXRpbHMvRHJhZ0xpc3RlbmVyJ1xuZXhwb3J0IHsgZGVmYXVsdCBhcyBFdmVudEVtaXR0ZXIgfSBmcm9tICcuL2pzX2VzNi91dGlscy9FdmVudEVtaXR0ZXInXG5leHBvcnQgeyBkZWZhdWx0IGFzIEV2ZW50SHViIH0gZnJvbSAnLi9qc19lczYvdXRpbHMvRXZlbnRIdWInXG5leHBvcnQgeyBkZWZhdWx0IGFzIFJlYWN0Q29tcG9uZW50SGFuZGxlciB9IGZyb20gJy4vanNfZXM2L3V0aWxzL1JlYWN0Q29tcG9uZW50SGFuZGxlcidcbiIsImltcG9ydCBFdmVudEVtaXR0ZXIgZnJvbSAnLi91dGlscy9FdmVudEVtaXR0ZXInXG5pbXBvcnQgQ29uZmlnTWluaWZpZXIgZnJvbSAnLi91dGlscy9Db25maWdNaW5pZmllcidcbmltcG9ydCBFdmVudEh1YiBmcm9tICcuL3V0aWxzL0V2ZW50SHViJ1xuXG5pbXBvcnQgUm9vdCBmcm9tICcuL2l0ZW1zL1Jvb3QnXG5pbXBvcnQgUm93T3JDb2x1bW4gZnJvbSAnLi9pdGVtcy9Sb3dPckNvbHVtbidcbmltcG9ydCBTdGFjayBmcm9tICcuL2l0ZW1zL1N0YWNrJ1xuaW1wb3J0IENvbXBvbmVudCBmcm9tICcuL2l0ZW1zL0NvbXBvbmVudCdcbmltcG9ydCBBYnN0cmFjdENvbnRlbnRJdGVtIGZyb20gJy4vaXRlbXMvQWJzdHJhY3RDb250ZW50SXRlbSdcblxuaW1wb3J0IEJyb3dzZXJQb3BvdXQgZnJvbSAnLi9jb250cm9scy9Ccm93c2VyUG9wb3V0J1xuaW1wb3J0IERyYWdTb3VyY2UgZnJvbSAnLi9jb250cm9scy9EcmFnU291cmNlJ1xuaW1wb3J0IERyb3BUYXJnZXRJbmRpY2F0b3IgZnJvbSAnLi9jb250cm9scy9Ecm9wVGFyZ2V0SW5kaWNhdG9yJ1xuaW1wb3J0IFRyYW5zaXRpb25JbmRpY2F0b3IgZnJvbSAnLi9jb250cm9scy9UcmFuc2l0aW9uSW5kaWNhdG9yJ1xuXG5pbXBvcnQgQ29uZmlndXJhdGlvbkVycm9yIGZyb20gJy4vZXJyb3JzL0NvbmZpZ3VyYXRpb25FcnJvcidcbmltcG9ydCBkZWZhdWx0Q29uZmlnIGZyb20gJy4vY29uZmlnL2RlZmF1bHRDb25maWcnXG5cbmltcG9ydCB7XG4gICAgZm5CaW5kLFxuICAgIG9iamVjdEtleXMsXG4gICAgY29weSxcbiAgICBnZXRVbmlxdWVJZCxcbiAgICBpbmRleE9mLFxuICAgIGlzRnVuY3Rpb24sXG4gICAgc3RyaXBUYWdzLFxuICAgIGdldFF1ZXJ5U3RyaW5nUGFyYW1cbn0gZnJvbSAnLi91dGlscy91dGlscydcblxuaW1wb3J0ICQgZnJvbSAnanF1ZXJ5J1xuXG5leHBvcnQgY29uc3QgUkVBQ1RfQ09NUE9ORU5UX0lEID0gJ2xtLXJlYWN0LWNvbXBvbmVudCdcblxuLyoqXG4gKiBUaGUgbWFpbiBjbGFzcyB0aGF0IHdpbGwgYmUgZXhwb3NlZCBhcyBHb2xkZW5MYXlvdXQuXG4gKlxuICogQHB1YmxpY1xuICogQGNvbnN0cnVjdG9yXG4gKiBAcGFyYW0ge0dvbGRlbkxheW91dCBjb25maWd9IGNvbmZpZ1xuICogQHBhcmFtIHtbRE9NIGVsZW1lbnQgY29udGFpbmVyXX0gY29udGFpbmVyIENhbiBiZSBhIGpRdWVyeSBzZWxlY3RvciBzdHJpbmcgb3IgYSBEb20gZWxlbWVudC4gRGVmYXVsdHMgdG8gYm9keVxuICpcbiAqIEByZXR1cm5zIHtWT0lEfVxuICovXG5cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgTGF5b3V0TWFuYWdlciBleHRlbmRzIEV2ZW50RW1pdHRlciB7XG4gICAgY29uc3RydWN0b3IoY29uZmlnLCBjb250YWluZXIpIHsgICAgICAgIFxuICAgICAgICBzdXBlcigpO1xuXG4gICAgICAgIHRoaXMuaXNJbml0aWFsaXNlZCA9IGZhbHNlO1xuICAgICAgICB0aGlzLl9pc0Z1bGxQYWdlID0gZmFsc2U7XG4gICAgICAgIHRoaXMuX3Jlc2l6ZVRpbWVvdXRJZCA9IG51bGw7XG4gICAgICAgIHRoaXMuX2NvbXBvbmVudHMgPSB7fTtcbiAgICAgICAgdGhpcy5faXRlbUFyZWFzID0gW107XG4gICAgICAgIHRoaXMuX3Jlc2l6ZUZ1bmN0aW9uID0gZm5CaW5kKHRoaXMuX29uUmVzaXplLCB0aGlzKTtcbiAgICAgICAgdGhpcy5fdW5sb2FkRnVuY3Rpb24gPSBmbkJpbmQodGhpcy5fb25VbmxvYWQsIHRoaXMpO1xuICAgICAgICB0aGlzLl9tYXhpbWlzZWRJdGVtID0gbnVsbDtcbiAgICAgICAgdGhpcy5fbWF4aW1pc2VQbGFjZWhvbGRlciA9ICQoJzxkaXYgY2xhc3M9XCJsbV9tYXhpbWlzZV9wbGFjZVwiPjwvZGl2PicpO1xuICAgICAgICB0aGlzLl9jcmVhdGlvblRpbWVvdXRQYXNzZWQgPSBmYWxzZTtcbiAgICAgICAgdGhpcy5fc3ViV2luZG93c0NyZWF0ZWQgPSBmYWxzZTtcbiAgICAgICAgdGhpcy5fZHJhZ1NvdXJjZXMgPSBbXTtcbiAgICAgICAgdGhpcy5fdXBkYXRpbmdDb2x1bW5zUmVzcG9uc2l2ZSA9IGZhbHNlO1xuICAgICAgICB0aGlzLl9maXJzdExvYWQgPSB0cnVlO1xuXG4gICAgICAgIHRoaXMud2lkdGggPSBudWxsO1xuICAgICAgICB0aGlzLmhlaWdodCA9IG51bGw7XG4gICAgICAgIHRoaXMucm9vdCA9IG51bGw7XG4gICAgICAgIHRoaXMub3BlblBvcG91dHMgPSBbXTtcbiAgICAgICAgdGhpcy5zZWxlY3RlZEl0ZW0gPSBudWxsO1xuICAgICAgICB0aGlzLmlzU3ViV2luZG93ID0gZmFsc2U7XG4gICAgICAgIHRoaXMuZXZlbnRIdWIgPSBuZXcgRXZlbnRIdWIodGhpcyk7XG4gICAgICAgIHRoaXMuY29uZmlnID0gdGhpcy5fY3JlYXRlQ29uZmlnKGNvbmZpZyk7XG4gICAgICAgIHRoaXMuY29udGFpbmVyID0gY29udGFpbmVyO1xuICAgICAgICB0aGlzLmRyb3BUYXJnZXRJbmRpY2F0b3IgPSBudWxsO1xuICAgICAgICB0aGlzLnRyYW5zaXRpb25JbmRpY2F0b3IgPSBudWxsO1xuICAgICAgICB0aGlzLnRhYkRyb3BQbGFjZWhvbGRlciA9ICQoJzxkaXYgY2xhc3M9XCJsbV9kcm9wX3RhYl9wbGFjZWhvbGRlclwiPjwvZGl2PicpO1xuXG4gICAgICAgIGlmICh0aGlzLmlzU3ViV2luZG93ID09PSB0cnVlKSB7XG4gICAgICAgICAgICAkKCdib2R5JykuY3NzKCd2aXNpYmlsaXR5JywgJ2hpZGRlbicpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fdHlwZVRvSXRlbSA9IHtcbiAgICAgICAgICAgICdjb2x1bW4nOiBmbkJpbmQoUm93T3JDb2x1bW4sIHRoaXMsIFt0cnVlXSksXG4gICAgICAgICAgICAncm93JzogZm5CaW5kKFJvd09yQ29sdW1uLCB0aGlzLCBbZmFsc2VdKSxcbiAgICAgICAgICAgICdzdGFjayc6IFN0YWNrLFxuICAgICAgICAgICAgJ2NvbXBvbmVudCc6IENvbXBvbmVudFxuICAgICAgICB9O1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFRha2VzIGEgR29sZGVuTGF5b3V0IGNvbmZpZ3VyYXRpb24gb2JqZWN0IGFuZFxuICAgICAqIHJlcGxhY2VzIGl0cyBrZXlzIGFuZCB2YWx1ZXMgcmVjdXJzaXZlbHkgd2l0aFxuICAgICAqIG9uZSBsZXR0ZXIgY29kZXNcbiAgICAgKlxuICAgICAqIEBzdGF0aWNcbiAgICAgKiBAcHVibGljXG4gICAgICogQHBhcmFtICAge09iamVjdH0gY29uZmlnIEEgR29sZGVuTGF5b3V0IGNvbmZpZyBvYmplY3RcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtPYmplY3R9IG1pbmlmaWVkIGNvbmZpZ1xuICAgICAqL1xuICAgIG1pbmlmeUNvbmZpZyhjb25maWcpIHtcbiAgICAgICAgcmV0dXJuIChuZXcgQ29uZmlnTWluaWZpZXIoKSkubWluaWZ5Q29uZmlnKGNvbmZpZyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVGFrZXMgYSBjb25maWd1cmF0aW9uIE9iamVjdCB0aGF0IHdhcyBwcmV2aW91c2x5IG1pbmlmaWVkXG4gICAgICogdXNpbmcgbWluaWZ5Q29uZmlnIGFuZCByZXR1cm5zIGl0cyBvcmlnaW5hbCB2ZXJzaW9uXG4gICAgICpcbiAgICAgKiBAc3RhdGljXG4gICAgICogQHB1YmxpY1xuICAgICAqIEBwYXJhbSAgIHtPYmplY3R9IG1pbmlmaWVkQ29uZmlnXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7T2JqZWN0fSB0aGUgb3JpZ2luYWwgY29uZmlndXJhdGlvblxuICAgICAqL1xuICAgIHVubWluaWZ5Q29uZmlnKGNvbmZpZykge1xuICAgICAgICByZXR1cm4gKG5ldyBDb25maWdNaW5pZmllcigpKS51bm1pbmlmeUNvbmZpZyhjb25maWcpO1xuICAgIH1cblxuXG4gICAgLyoqXG4gICAgICogUmVnaXN0ZXIgYSBjb21wb25lbnQgd2l0aCB0aGUgbGF5b3V0IG1hbmFnZXIuIElmIGEgY29uZmlndXJhdGlvbiBub2RlXG4gICAgICogb2YgdHlwZSBjb21wb25lbnQgaXMgcmVhY2hlZCBpdCB3aWxsIGxvb2sgdXAgY29tcG9uZW50TmFtZSBhbmQgY3JlYXRlIHRoZVxuICAgICAqIGFzc29jaWF0ZWQgY29tcG9uZW50XG4gICAgICpcbiAgICAgKiAge1xuICAgICAqICAgIHR5cGU6IFwiY29tcG9uZW50XCIsXG4gICAgICogICAgY29tcG9uZW50TmFtZTogXCJFcXVpdHlOZXdzRmVlZFwiLFxuICAgICAqICAgIGNvbXBvbmVudFN0YXRlOiB7IFwiZmVlZFRvcGljXCI6IFwidXMtYmx1ZWNoaXBzXCIgfVxuICAgICAqICB9XG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHBhcmFtICAge1N0cmluZ30gbmFtZVxuICAgICAqIEBwYXJhbSAgIHtGdW5jdGlvbn0gY29uc3RydWN0b3JcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIHJlZ2lzdGVyQ29tcG9uZW50KG5hbWUsIGNvbnN0cnVjdG9yKSB7XG4gICAgICAgIGlmICh0eXBlb2YgY29uc3RydWN0b3IgIT09ICdmdW5jdGlvbicpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignUGxlYXNlIHJlZ2lzdGVyIGEgY29uc3RydWN0b3IgZnVuY3Rpb24nKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmICh0aGlzLl9jb21wb25lbnRzW25hbWVdICE9PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ29tcG9uZW50ICcgKyBuYW1lICsgJyBpcyBhbHJlYWR5IHJlZ2lzdGVyZWQnKTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuX2NvbXBvbmVudHNbbmFtZV0gPSBjb25zdHJ1Y3RvcjtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBSZWdpc3RlciBhIGNvbXBvbmVudCBmdW5jdGlvbiB3aXRoIHRoZSBsYXlvdXQgbWFuYWdlci4gVGhpcyBmdW5jdGlvbiBzaG91bGRcbiAgICAgKiByZXR1cm4gYSBjb25zdHJ1Y3RvciBmb3IgYSBjb21wb25lbnQgYmFzZWQgb24gYSBjb25maWcuICBJZiB1bmRlZmluZWQgaXMgcmV0dXJuZWQsIFxuICAgICAqIGFuZCBubyBjb21wb25lbnQgaGFzIGJlZW4gcmVnaXN0ZXJlZCB1bmRlciB0aGF0IG5hbWUgdXNpbmcgcmVnaXN0ZXJDb21wb25lbnQsIGFuIFxuICAgICAqIGVycm9yIHdpbGwgYmUgdGhyb3duLlxuICAgICAqXG4gICAgICogQHB1YmxpY1xuICAgICAqIEBwYXJhbSAgIHtGdW5jdGlvbn0gY2FsbGJhY2tcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIHJlZ2lzdGVyQ29tcG9uZW50RnVuY3Rpb24oY2FsbGJhY2spIHtcbiAgICAgICAgaWYgKHR5cGVvZiBjYWxsYmFjayAhPT0gJ2Z1bmN0aW9uJykge1xuICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdQbGVhc2UgcmVnaXN0ZXIgYSBjYWxsYmFjayBmdW5jdGlvbicpO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKHRoaXMuX2NvbXBvbmVudEZ1bmN0aW9uICE9PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgIGNvbnNvbGUud2FybignTXVsdGlwbGUgY29tcG9uZW50IGZ1bmN0aW9ucyBhcmUgYmVpbmcgcmVnaXN0ZXJlZC4gIE9ubHkgdGhlIGZpbmFsIHJlZ2lzdGVyZWQgZnVuY3Rpb24gd2lsbCBiZSB1c2VkLicpXG4gICAgICAgIH1cblxuICAgICAgICB0aGlzLl9jb21wb25lbnRGdW5jdGlvbiA9IGNhbGxiYWNrO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENyZWF0ZXMgYSBsYXlvdXQgY29uZmlndXJhdGlvbiBvYmplY3QgYmFzZWQgb24gdGhlIHRoZSBjdXJyZW50IHN0YXRlXG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHJldHVybnMge09iamVjdH0gR29sZGVuTGF5b3V0IGNvbmZpZ3VyYXRpb25cbiAgICAgKi9cbiAgICB0b0NvbmZpZyhyb290KSB7XG4gICAgICAgIHZhciBjb25maWcsIG5leHQsIGk7XG5cbiAgICAgICAgaWYgKHRoaXMuaXNJbml0aWFsaXNlZCA9PT0gZmFsc2UpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ2FuXFwndCBjcmVhdGUgY29uZmlnLCBsYXlvdXQgbm90IHlldCBpbml0aWFsaXNlZCcpO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKHJvb3QgJiYgIShyb290IGluc3RhbmNlb2YgQWJzdHJhY3RDb250ZW50SXRlbSkpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignUm9vdCBtdXN0IGJlIGEgQ29udGVudEl0ZW0nKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qXG4gICAgICAgICAqIHNldHRpbmdzICYgbGFiZWxzXG4gICAgICAgICAqL1xuICAgICAgICBjb25maWcgPSB7XG4gICAgICAgICAgICBzZXR0aW5nczogY29weSh7fSwgdGhpcy5jb25maWcuc2V0dGluZ3MpLFxuICAgICAgICAgICAgZGltZW5zaW9uczogY29weSh7fSwgdGhpcy5jb25maWcuZGltZW5zaW9ucyksXG4gICAgICAgICAgICBsYWJlbHM6IGNvcHkoe30sIHRoaXMuY29uZmlnLmxhYmVscylcbiAgICAgICAgfTtcblxuICAgICAgICAvKlxuICAgICAgICAgKiBDb250ZW50XG4gICAgICAgICAqL1xuICAgICAgICBjb25maWcuY29udGVudCA9IFtdO1xuICAgICAgICBuZXh0ID0gZnVuY3Rpb24oY29uZmlnTm9kZSwgaXRlbSkge1xuICAgICAgICAgICAgdmFyIGtleSwgaTtcblxuICAgICAgICAgICAgZm9yIChrZXkgaW4gaXRlbS5jb25maWcpIHtcbiAgICAgICAgICAgICAgICBpZiAoa2V5ICE9PSAnY29udGVudCcpIHtcbiAgICAgICAgICAgICAgICAgICAgY29uZmlnTm9kZVtrZXldID0gaXRlbS5jb25maWdba2V5XTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGlmIChpdGVtLmNvbnRlbnRJdGVtcy5sZW5ndGgpIHtcbiAgICAgICAgICAgICAgICBjb25maWdOb2RlLmNvbnRlbnQgPSBbXTtcblxuICAgICAgICAgICAgICAgIGZvciAoaSA9IDA7IGkgPCBpdGVtLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgICAgICAgICBjb25maWdOb2RlLmNvbnRlbnRbaV0gPSB7fTtcbiAgICAgICAgICAgICAgICAgICAgbmV4dChjb25maWdOb2RlLmNvbnRlbnRbaV0sIGl0ZW0uY29udGVudEl0ZW1zW2ldKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG4gICAgICAgIH07XG5cbiAgICAgICAgaWYgKHJvb3QpIHtcbiAgICAgICAgICAgIG5leHQoY29uZmlnLCB7XG4gICAgICAgICAgICAgICAgY29udGVudEl0ZW1zOiBbcm9vdF1cbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgbmV4dChjb25maWcsIHRoaXMucm9vdCk7XG4gICAgICAgIH1cblxuICAgICAgICAvKlxuICAgICAgICAgKiBSZXRyaWV2ZSBjb25maWcgZm9yIHN1YndpbmRvd3NcbiAgICAgICAgICovXG4gICAgICAgIHRoaXMuXyRyZWNvbmNpbGVQb3BvdXRXaW5kb3dzKCk7XG4gICAgICAgIGNvbmZpZy5vcGVuUG9wb3V0cyA9IFtdO1xuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5vcGVuUG9wb3V0cy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgY29uZmlnLm9wZW5Qb3BvdXRzLnB1c2godGhpcy5vcGVuUG9wb3V0c1tpXS50b0NvbmZpZygpKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qXG4gICAgICAgICAqIEFkZCBtYXhpbWlzZWQgaXRlbVxuICAgICAgICAgKi9cbiAgICAgICAgY29uZmlnLm1heGltaXNlZEl0ZW1JZCA9IHRoaXMuX21heGltaXNlZEl0ZW0gPyAnX19nbE1heGltaXNlZCcgOiBudWxsO1xuICAgICAgICByZXR1cm4gY29uZmlnO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJldHVybnMgYSBwcmV2aW91c2x5IHJlZ2lzdGVyZWQgY29tcG9uZW50LiAgQXR0ZW1wdHMgdG8gdXRpbGl6ZSByZWdpc3RlcmVkIFxuICAgICAqIGNvbXBvbmVudCBieSBuYW1lIGZpcnN0LCB0aGVuIGZhbGxzIGJhY2sgdG8gdGhlIGNvbXBvbmVudCBmdW5jdGlvbi4gIElmIGVpdGhlclxuICAgICAqIGxhY2sgYSByZXNwb25zZSBmb3Igd2hhdCB0aGUgY29tcG9uZW50IHNob3VsZCBiZSwgaXQgdGhyb3dzIGFuIGVycm9yLlxuICAgICAqXG4gICAgICogQHB1YmxpY1xuICAgICAqIEBwYXJhbSB7T2JqZWN0fSBjb25maWcgLSBUaGUgaXRlbSBjb25maWdcbiAgICAgKiBcbiAgICAgKiBAcmV0dXJucyB7RnVuY3Rpb259XG4gICAgICovXG4gICAgZ2V0Q29tcG9uZW50KGNvbmZpZykge1xuICAgICAgICBjb25zdCBuYW1lID0gdGhpcy5nZXRDb21wb25lbnROYW1lRnJvbUNvbmZpZyhjb25maWcpXG4gICAgICAgIGxldCBjb21wb25lbnRUb1VzZSA9IHRoaXMuX2NvbXBvbmVudHNbbmFtZV1cbiAgICAgICAgaWYgKHRoaXMuX2NvbXBvbmVudEZ1bmN0aW9uICE9PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgIGNvbXBvbmVudFRvVXNlID0gY29tcG9uZW50VG9Vc2UgfHwgdGhpcy5fY29tcG9uZW50RnVuY3Rpb24oe2NvbmZpZ30pXG4gICAgICAgIH1cbiAgICAgICAgaWYgKGNvbXBvbmVudFRvVXNlID09PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBDb25maWd1cmF0aW9uRXJyb3IoJ1Vua25vd24gY29tcG9uZW50IFwiJyArIG5hbWUgKyAnXCInKTtcbiAgICAgICAgfVxuXG4gICAgICAgIHJldHVybiBjb21wb25lbnRUb1VzZTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDcmVhdGVzIHRoZSBhY3R1YWwgbGF5b3V0LiBNdXN0IGJlIGNhbGxlZCBhZnRlciBhbGwgaW5pdGlhbCBjb21wb25lbnRzXG4gICAgICogYXJlIHJlZ2lzdGVyZWQuIFJlY3Vyc2VzIHRocm91Z2ggdGhlIGNvbmZpZ3VyYXRpb24gYW5kIHNldHMgdXBcbiAgICAgKiB0aGUgaXRlbSB0cmVlLlxuICAgICAqXG4gICAgICogSWYgY2FsbGVkIGJlZm9yZSB0aGUgZG9jdW1lbnQgaXMgcmVhZHkgaXQgYWRkcyBpdHNlbGYgYXMgYSBsaXN0ZW5lclxuICAgICAqIHRvIHRoZSBkb2N1bWVudC5yZWFkeSBldmVudFxuICAgICAqXG4gICAgICogQHB1YmxpY1xuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgaW5pdCgpIHtcblxuICAgICAgICAvKipcbiAgICAgICAgICogQ3JlYXRlIHRoZSBwb3BvdXQgd2luZG93cyBzdHJhaWdodCBhd2F5LiBJZiBwb3BvdXRzIGFyZSBibG9ja2VkXG4gICAgICAgICAqIGFuIGVycm9yIGlzIHRocm93biBvbiB0aGUgc2FtZSAndGhyZWFkJyByYXRoZXIgdGhhbiBhIHRpbWVvdXQgYW5kIGNhblxuICAgICAgICAgKiBiZSBjYXVnaHQuIFRoaXMgYWxzbyBwcmV2ZW50cyBhbnkgZnVydGhlciBpbml0aWxpc2F0aW9uIGZyb20gdGFraW5nIHBsYWNlLlxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuX3N1YldpbmRvd3NDcmVhdGVkID09PSBmYWxzZSkge1xuICAgICAgICAgICAgdGhpcy5fY3JlYXRlU3ViV2luZG93cygpO1xuICAgICAgICAgICAgdGhpcy5fc3ViV2luZG93c0NyZWF0ZWQgPSB0cnVlO1xuICAgICAgICB9XG5cblxuICAgICAgICAvKipcbiAgICAgICAgICogSWYgdGhlIGRvY3VtZW50IGlzbid0IHJlYWR5IHlldCwgd2FpdCBmb3IgaXQuXG4gICAgICAgICAqL1xuICAgICAgICBpZiAoZG9jdW1lbnQucmVhZHlTdGF0ZSA9PT0gJ2xvYWRpbmcnIHx8IGRvY3VtZW50LmJvZHkgPT09IG51bGwpIHtcbiAgICAgICAgICAgICQoZG9jdW1lbnQpLnJlYWR5KGZuQmluZCh0aGlzLmluaXQsIHRoaXMpKTtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBJZiB0aGlzIGlzIGEgc3Vid2luZG93LCB3YWl0IGEgZmV3IG1pbGxpc2Vjb25kcyBmb3IgdGhlIG9yaWdpbmFsXG4gICAgICAgICAqIHBhZ2UncyBqcyBjYWxscyB0byBiZSBleGVjdXRlZCwgdGhlbiByZXBsYWNlIHRoZSBib2RpZXMgY29udGVudFxuICAgICAgICAgKiB3aXRoIEdvbGRlbkxheW91dFxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuaXNTdWJXaW5kb3cgPT09IHRydWUgJiYgdGhpcy5fY3JlYXRpb25UaW1lb3V0UGFzc2VkID09PSBmYWxzZSkge1xuICAgICAgICAgICAgc2V0VGltZW91dChmbkJpbmQodGhpcy5pbml0LCB0aGlzKSwgNyk7XG4gICAgICAgICAgICB0aGlzLl9jcmVhdGlvblRpbWVvdXRQYXNzZWQgPSB0cnVlO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKHRoaXMuaXNTdWJXaW5kb3cgPT09IHRydWUpIHtcbiAgICAgICAgICAgIHRoaXMuX2FkanVzdFRvV2luZG93TW9kZSgpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fc2V0Q29udGFpbmVyKCk7XG4gICAgICAgIHRoaXMuZHJvcFRhcmdldEluZGljYXRvciA9IG5ldyBEcm9wVGFyZ2V0SW5kaWNhdG9yKHRoaXMuY29udGFpbmVyKTtcbiAgICAgICAgdGhpcy50cmFuc2l0aW9uSW5kaWNhdG9yID0gbmV3IFRyYW5zaXRpb25JbmRpY2F0b3IoKTtcbiAgICAgICAgdGhpcy51cGRhdGVTaXplKCk7XG4gICAgICAgIHRoaXMuX2NyZWF0ZSh0aGlzLmNvbmZpZyk7XG4gICAgICAgIHRoaXMuX2JpbmRFdmVudHMoKTtcbiAgICAgICAgdGhpcy5pc0luaXRpYWxpc2VkID0gdHJ1ZTtcbiAgICAgICAgdGhpcy5fYWRqdXN0Q29sdW1uc1Jlc3BvbnNpdmUoKTtcbiAgICAgICAgdGhpcy5lbWl0KCdpbml0aWFsaXNlZCcpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFVwZGF0ZXMgdGhlIGxheW91dCBtYW5hZ2VycyBzaXplXG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHBhcmFtICAge1tpbnRdfSB3aWR0aCAgaGVpZ2h0IGluIHBpeGVsc1xuICAgICAqIEBwYXJhbSAgIHtbaW50XX0gaGVpZ2h0IHdpZHRoIGluIHBpeGVsc1xuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgdXBkYXRlU2l6ZSh3aWR0aCwgaGVpZ2h0KSB7XG4gICAgICAgIGlmIChhcmd1bWVudHMubGVuZ3RoID09PSAyKSB7XG4gICAgICAgICAgICB0aGlzLndpZHRoID0gd2lkdGg7XG4gICAgICAgICAgICB0aGlzLmhlaWdodCA9IGhlaWdodDtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRoaXMud2lkdGggPSB0aGlzLmNvbnRhaW5lci53aWR0aCgpO1xuICAgICAgICAgICAgdGhpcy5oZWlnaHQgPSB0aGlzLmNvbnRhaW5lci5oZWlnaHQoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmICh0aGlzLmlzSW5pdGlhbGlzZWQgPT09IHRydWUpIHtcbiAgICAgICAgICAgIHRoaXMucm9vdC5jYWxsRG93bndhcmRzKCdzZXRTaXplJywgW3RoaXMud2lkdGgsIHRoaXMuaGVpZ2h0XSk7XG5cbiAgICAgICAgICAgIGlmICh0aGlzLl9tYXhpbWlzZWRJdGVtKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5fbWF4aW1pc2VkSXRlbS5lbGVtZW50LndpZHRoKHRoaXMuY29udGFpbmVyLndpZHRoKCkpO1xuICAgICAgICAgICAgICAgIHRoaXMuX21heGltaXNlZEl0ZW0uZWxlbWVudC5oZWlnaHQodGhpcy5jb250YWluZXIuaGVpZ2h0KCkpO1xuICAgICAgICAgICAgICAgIHRoaXMuX21heGltaXNlZEl0ZW0uY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICB0aGlzLl9hZGp1c3RDb2x1bW5zUmVzcG9uc2l2ZSgpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRGVzdHJveXMgdGhlIExheW91dE1hbmFnZXIgaW5zdGFuY2UgaXRzZWxmIGFzIHdlbGwgYXMgZXZlcnkgQ29udGVudEl0ZW1cbiAgICAgKiB3aXRoaW4gaXQuIEFmdGVyIHRoaXMgaXMgY2FsbGVkIG5vdGhpbmcgc2hvdWxkIGJlIGxlZnQgb2YgdGhlIExheW91dE1hbmFnZXIuXG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgZGVzdHJveSgpIHtcbiAgICAgICAgaWYgKHRoaXMuaXNJbml0aWFsaXNlZCA9PT0gZmFsc2UpIHtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuICAgICAgICB0aGlzLl9vblVubG9hZCgpO1xuICAgICAgICAkKHdpbmRvdykub2ZmKCdyZXNpemUnLCB0aGlzLl9yZXNpemVGdW5jdGlvbik7XG4gICAgICAgICQod2luZG93KS5vZmYoJ3VubG9hZCBiZWZvcmV1bmxvYWQnLCB0aGlzLl91bmxvYWRGdW5jdGlvbik7XG4gICAgICAgIHRoaXMucm9vdC5jYWxsRG93bndhcmRzKCdfJGRlc3Ryb3knLCBbXSwgdHJ1ZSk7XG4gICAgICAgIHRoaXMucm9vdC5jb250ZW50SXRlbXMgPSBbXTtcbiAgICAgICAgdGhpcy50YWJEcm9wUGxhY2Vob2xkZXIucmVtb3ZlKCk7XG4gICAgICAgIHRoaXMuZHJvcFRhcmdldEluZGljYXRvci5kZXN0cm95KCk7XG4gICAgICAgIHRoaXMudHJhbnNpdGlvbkluZGljYXRvci5kZXN0cm95KCk7XG4gICAgICAgIHRoaXMuZXZlbnRIdWIuZGVzdHJveSgpO1xuXG4gICAgICAgIHRoaXMuX2RyYWdTb3VyY2VzLmZvckVhY2goZnVuY3Rpb24oZHJhZ1NvdXJjZSkge1xuICAgICAgICAgICAgZHJhZ1NvdXJjZS5fZHJhZ0xpc3RlbmVyLmRlc3Ryb3koKTtcbiAgICAgICAgICAgIGRyYWdTb3VyY2UuX2VsZW1lbnQgPSBudWxsO1xuICAgICAgICAgICAgZHJhZ1NvdXJjZS5faXRlbUNvbmZpZyA9IG51bGw7XG4gICAgICAgICAgICBkcmFnU291cmNlLl9kcmFnTGlzdGVuZXIgPSBudWxsO1xuICAgICAgICB9KTtcbiAgICAgICAgdGhpcy5fZHJhZ1NvdXJjZXMgPSBbXTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBSZXR1cm5zIHdoZXRoZXIgb3Igbm90IHRoZSBjb25maWcgY29ycmVzcG9uZHMgdG8gYSByZWFjdCBjb21wb25lbnQgb3IgYSBub3JtYWwgY29tcG9uZW50LlxuICAgICAqIFxuICAgICAqIEF0IHNvbWUgcG9pbnQgdGhlIHR5cGUgaXMgbXV0YXRlZCwgYnV0IHRoZSBjb21wb25lbnROYW1lIHNob3VsZCB0aGVuIGNvcnJlc3BvbmQgdG8gdGhlXG4gICAgICogUkVBQ1RfQ09NUE9ORU5UX0lELlxuICAgICAqIFxuICAgICAqIEBwYXJhbSB7T2JqZWN0fSBjb25maWcgSXRlbUNvbmZpZ1xuICAgICAqIFxuICAgICAqIEByZXR1cm5zIHtCb29sZWFufVxuICAgICAqL1xuXG4gICAgaXNSZWFjdENvbmZpZyhjb25maWcpIHtcbiAgICAgICAgcmV0dXJuIGNvbmZpZy50eXBlID09PSAncmVhY3QtY29tcG9uZW50JyB8fCBjb25maWcuY29tcG9uZW50TmFtZSA9PT0gUkVBQ1RfQ09NUE9ORU5UX0lEXG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogUmV0dXJucyB0aGUgbmFtZSBvZiB0aGUgY29tcG9uZW50IGZvciB0aGUgY29uZmlnLCB0YWtpbmcgaW50byBhY2NvdW50IHdoZXRoZXIgaXQncyBhIHJlYWN0IGNvbXBvbmVudCBvciBub3QuXG4gICAgICogXG4gICAgICogQHBhcmFtIHtPYmplY3R9IGNvbmZpZyBJdGVtQ29uZmlnXG4gICAgICogXG4gICAgICogQHJldHVybnMge1N0cmluZ31cbiAgICAgKi9cblxuICAgIGdldENvbXBvbmVudE5hbWVGcm9tQ29uZmlnKGNvbmZpZykge1xuICAgICAgICBpZiAodGhpcy5pc1JlYWN0Q29uZmlnKGNvbmZpZykpIHtcbiAgICAgICAgICAgIHJldHVybiBjb25maWcuY29tcG9uZW50XG4gICAgICAgIH1cbiAgICAgICAgcmV0dXJuIGNvbmZpZy5jb21wb25lbnROYW1lXG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogUmVjdXJzaXZlbHkgY3JlYXRlcyBuZXcgaXRlbSB0cmVlIHN0cnVjdHVyZXMgYmFzZWQgb24gYSBwcm92aWRlZFxuICAgICAqIEl0ZW1Db25maWd1cmF0aW9uIG9iamVjdFxuICAgICAqXG4gICAgICogQHB1YmxpY1xuICAgICAqIEBwYXJhbSAgIHtPYmplY3R9IGNvbmZpZyBJdGVtQ29uZmlnXG4gICAgICogQHBhcmFtICAge1tDb250ZW50SXRlbV19IHBhcmVudCBUaGUgaXRlbSB0aGUgbmV3bHkgY3JlYXRlZCBpdGVtIHNob3VsZCBiZSBhIGNoaWxkIG9mXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7Q29udGVudEl0ZW19XG4gICAgICovXG4gICAgY3JlYXRlQ29udGVudEl0ZW0oY29uZmlnLCBwYXJlbnQpIHtcbiAgICAgICAgdmFyIHR5cGVFcnJvck1zZywgY29udGVudEl0ZW07XG5cbiAgICAgICAgaWYgKHR5cGVvZiBjb25maWcudHlwZSAhPT0gJ3N0cmluZycpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBDb25maWd1cmF0aW9uRXJyb3IoJ01pc3NpbmcgcGFyYW1ldGVyIFxcJ3R5cGVcXCcnLCBjb25maWcpO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKHRoaXMuaXNSZWFjdENvbmZpZyhjb25maWcpKSB7XG4gICAgICAgICAgICBjb25maWcudHlwZSA9ICdjb21wb25lbnQnO1xuICAgICAgICAgICAgY29uZmlnLmNvbXBvbmVudE5hbWUgPSBSRUFDVF9DT01QT05FTlRfSUQ7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoIXRoaXMuX3R5cGVUb0l0ZW1bY29uZmlnLnR5cGVdKSB7XG4gICAgICAgICAgICB0eXBlRXJyb3JNc2cgPSAnVW5rbm93biB0eXBlIFxcJycgKyBjb25maWcudHlwZSArICdcXCcuICcgK1xuICAgICAgICAgICAgICAgICdWYWxpZCB0eXBlcyBhcmUgJyArIG9iamVjdEtleXModGhpcy5fdHlwZVRvSXRlbSkuam9pbignLCcpO1xuXG4gICAgICAgICAgICB0aHJvdyBuZXcgQ29uZmlndXJhdGlvbkVycm9yKHR5cGVFcnJvck1zZyk7XG4gICAgICAgIH1cblxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBXZSBhZGQgYW4gYWRkaXRpb25hbCBzdGFjayBhcm91bmQgZXZlcnkgY29tcG9uZW50IHRoYXQncyBub3Qgd2l0aGluIGEgc3RhY2sgYW55d2F5cy5cbiAgICAgICAgICovXG4gICAgICAgIGlmIChcbiAgICAgICAgICAgIC8vIElmIHRoaXMgaXMgYSBjb21wb25lbnRcbiAgICAgICAgICAgIGNvbmZpZy50eXBlID09PSAnY29tcG9uZW50JyAmJlxuXG4gICAgICAgICAgICAvLyBhbmQgaXQncyBub3QgYWxyZWFkeSB3aXRoaW4gYSBzdGFja1xuICAgICAgICAgICAgIShwYXJlbnQgaW5zdGFuY2VvZiBTdGFjaykgJiZcblxuICAgICAgICAgICAgLy8gYW5kIHdlIGhhdmUgYSBwYXJlbnRcbiAgICAgICAgICAgICEhcGFyZW50ICYmXG5cbiAgICAgICAgICAgIC8vIGFuZCBpdCdzIG5vdCB0aGUgdG9wbW9zdCBpdGVtIGluIGEgbmV3IHdpbmRvd1xuICAgICAgICAgICAgISh0aGlzLmlzU3ViV2luZG93ID09PSB0cnVlICYmIHBhcmVudCBpbnN0YW5jZW9mIFJvb3QpXG4gICAgICAgICkge1xuICAgICAgICAgICAgY29uZmlnID0ge1xuICAgICAgICAgICAgICAgIHR5cGU6ICdzdGFjaycsXG4gICAgICAgICAgICAgICAgd2lkdGg6IGNvbmZpZy53aWR0aCxcbiAgICAgICAgICAgICAgICBoZWlnaHQ6IGNvbmZpZy5oZWlnaHQsXG4gICAgICAgICAgICAgICAgY29udGVudDogW2NvbmZpZ11cbiAgICAgICAgICAgIH07XG4gICAgICAgIH1cblxuICAgICAgICBjb250ZW50SXRlbSA9IG5ldyB0aGlzLl90eXBlVG9JdGVtW2NvbmZpZy50eXBlXSh0aGlzLCBjb25maWcsIHBhcmVudCk7XG4gICAgICAgIHJldHVybiBjb250ZW50SXRlbTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDcmVhdGVzIGEgcG9wb3V0IHdpbmRvdyB3aXRoIHRoZSBzcGVjaWZpZWQgY29udGVudCBhbmQgZGltZW5zaW9uc1xuICAgICAqXG4gICAgICogQHBhcmFtICAge09iamVjdHxsbS5pdGVtc0Fic3RyYWN0Q29udGVudEl0ZW19IGNvbmZpZ09yQ29udGVudEl0ZW1cbiAgICAgKiBAcGFyYW0gICB7W09iamVjdF19IGRpbWVuc2lvbnMgQSBtYXAgd2l0aCB3aWR0aCwgaGVpZ2h0LCBsZWZ0IGFuZCB0b3BcbiAgICAgKiBAcGFyYW0gICAge1tTdHJpbmddfSBwYXJlbnRJZCB0aGUgaWQgb2YgdGhlIGVsZW1lbnQgdGhpcyBpdGVtIHdpbGwgYmUgYXBwZW5kZWQgdG9cbiAgICAgKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgd2hlbiBwb3BJbiBpcyBjYWxsZWRcbiAgICAgKiBAcGFyYW0gICAge1tOdW1iZXJdfSBpbmRleEluUGFyZW50IFRoZSBwb3NpdGlvbiBvZiB0aGlzIGl0ZW0gd2l0aGluIGl0cyBwYXJlbnQgZWxlbWVudFxuICAgICBcbiAgICAgKiBAcmV0dXJucyB7QnJvd3NlclBvcG91dH1cbiAgICAgKi9cbiAgICBjcmVhdGVQb3BvdXQoY29uZmlnT3JDb250ZW50SXRlbSwgZGltZW5zaW9ucywgcGFyZW50SWQsIGluZGV4SW5QYXJlbnQpIHtcbiAgICAgICAgdmFyIGNvbmZpZyA9IGNvbmZpZ09yQ29udGVudEl0ZW0sXG4gICAgICAgICAgICBpc0l0ZW0gPSBjb25maWdPckNvbnRlbnRJdGVtIGluc3RhbmNlb2YgQWJzdHJhY3RDb250ZW50SXRlbSxcbiAgICAgICAgICAgIHNlbGYgPSB0aGlzLFxuICAgICAgICAgICAgd2luZG93TGVmdCxcbiAgICAgICAgICAgIHdpbmRvd1RvcCxcbiAgICAgICAgICAgIG9mZnNldCxcbiAgICAgICAgICAgIHBhcmVudCxcbiAgICAgICAgICAgIGNoaWxkLFxuICAgICAgICAgICAgYnJvd3NlclBvcG91dDtcblxuICAgICAgICBwYXJlbnRJZCA9IHBhcmVudElkIHx8IG51bGw7XG5cbiAgICAgICAgaWYgKGlzSXRlbSkge1xuICAgICAgICAgICAgY29uZmlnID0gdGhpcy50b0NvbmZpZyhjb25maWdPckNvbnRlbnRJdGVtKS5jb250ZW50O1xuICAgICAgICAgICAgcGFyZW50SWQgPSBnZXRVbmlxdWVJZCgpO1xuXG4gICAgICAgICAgICAvKipcbiAgICAgICAgICAgICAqIElmIHRoZSBpdGVtIGlzIHRoZSBvbmx5IGNvbXBvbmVudCB3aXRoaW4gYSBzdGFjayBvciBmb3Igc29tZVxuICAgICAgICAgICAgICogb3RoZXIgcmVhc29uIHRoZSBvbmx5IGNoaWxkIG9mIGl0cyBwYXJlbnQgdGhlIHBhcmVudCB3aWxsIGJlIGRlc3Ryb3llZFxuICAgICAgICAgICAgICogd2hlbiB0aGUgY2hpbGQgaXMgcmVtb3ZlZC5cbiAgICAgICAgICAgICAqXG4gICAgICAgICAgICAgKiBJbiBvcmRlciB0byBzdXBwb3J0IHRoaXMgd2UgbW92ZSB1cCB0aGUgdHJlZSB1bnRpbCB3ZSBmaW5kIHNvbWV0aGluZ1xuICAgICAgICAgICAgICogdGhhdCB3aWxsIHJlbWFpbiBhZnRlciB0aGUgaXRlbSBpcyBiZWluZyBwb3BwZWQgb3V0XG4gICAgICAgICAgICAgKi9cbiAgICAgICAgICAgIHBhcmVudCA9IGNvbmZpZ09yQ29udGVudEl0ZW0ucGFyZW50O1xuICAgICAgICAgICAgY2hpbGQgPSBjb25maWdPckNvbnRlbnRJdGVtO1xuICAgICAgICAgICAgd2hpbGUgKHBhcmVudC5jb250ZW50SXRlbXMubGVuZ3RoID09PSAxICYmICFwYXJlbnQuaXNSb290KSB7XG4gICAgICAgICAgICAgICAgcGFyZW50ID0gcGFyZW50LnBhcmVudDtcbiAgICAgICAgICAgICAgICBjaGlsZCA9IGNoaWxkLnBhcmVudDtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgcGFyZW50LmFkZElkKHBhcmVudElkKTtcbiAgICAgICAgICAgIGlmIChpc05hTihpbmRleEluUGFyZW50KSkge1xuICAgICAgICAgICAgICAgIGluZGV4SW5QYXJlbnQgPSBpbmRleE9mKGNoaWxkLCBwYXJlbnQuY29udGVudEl0ZW1zKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGlmICghKGNvbmZpZyBpbnN0YW5jZW9mIEFycmF5KSkge1xuICAgICAgICAgICAgICAgIGNvbmZpZyA9IFtjb25maWddO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cblxuICAgICAgICBpZiAoIWRpbWVuc2lvbnMgJiYgaXNJdGVtKSB7XG4gICAgICAgICAgICB3aW5kb3dMZWZ0ID0gd2luZG93LnNjcmVlblggfHwgd2luZG93LnNjcmVlbkxlZnQ7XG4gICAgICAgICAgICB3aW5kb3dUb3AgPSB3aW5kb3cuc2NyZWVuWSB8fCB3aW5kb3cuc2NyZWVuVG9wO1xuICAgICAgICAgICAgb2Zmc2V0ID0gY29uZmlnT3JDb250ZW50SXRlbS5lbGVtZW50Lm9mZnNldCgpO1xuXG4gICAgICAgICAgICBkaW1lbnNpb25zID0ge1xuICAgICAgICAgICAgICAgIGxlZnQ6IHdpbmRvd0xlZnQgKyBvZmZzZXQubGVmdCxcbiAgICAgICAgICAgICAgICB0b3A6IHdpbmRvd1RvcCArIG9mZnNldC50b3AsXG4gICAgICAgICAgICAgICAgd2lkdGg6IGNvbmZpZ09yQ29udGVudEl0ZW0uZWxlbWVudC53aWR0aCgpLFxuICAgICAgICAgICAgICAgIGhlaWdodDogY29uZmlnT3JDb250ZW50SXRlbS5lbGVtZW50LmhlaWdodCgpXG4gICAgICAgICAgICB9O1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKCFkaW1lbnNpb25zICYmICFpc0l0ZW0pIHtcbiAgICAgICAgICAgIGRpbWVuc2lvbnMgPSB7XG4gICAgICAgICAgICAgICAgbGVmdDogd2luZG93LnNjcmVlblggfHwgd2luZG93LnNjcmVlbkxlZnQgKyAyMCxcbiAgICAgICAgICAgICAgICB0b3A6IHdpbmRvdy5zY3JlZW5ZIHx8IHdpbmRvdy5zY3JlZW5Ub3AgKyAyMCxcbiAgICAgICAgICAgICAgICB3aWR0aDogNTAwLFxuICAgICAgICAgICAgICAgIGhlaWdodDogMzA5XG4gICAgICAgICAgICB9O1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKGlzSXRlbSkge1xuICAgICAgICAgICAgY29uZmlnT3JDb250ZW50SXRlbS5yZW1vdmUoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGJyb3dzZXJQb3BvdXQgPSBuZXcgQnJvd3NlclBvcG91dChjb25maWcsIGRpbWVuc2lvbnMsIHBhcmVudElkLCBpbmRleEluUGFyZW50LCB0aGlzKTtcblxuICAgICAgICBicm93c2VyUG9wb3V0Lm9uKCdpbml0aWFsaXNlZCcsIGZ1bmN0aW9uKCkge1xuICAgICAgICAgICAgc2VsZi5lbWl0KCd3aW5kb3dPcGVuZWQnLCBicm93c2VyUG9wb3V0KTtcbiAgICAgICAgfSk7XG5cbiAgICAgICAgYnJvd3NlclBvcG91dC5vbignY2xvc2VkJywgZnVuY3Rpb24oKSB7XG4gICAgICAgICAgICBzZWxmLl8kcmVjb25jaWxlUG9wb3V0V2luZG93cygpO1xuICAgICAgICB9KTtcblxuICAgICAgICB0aGlzLm9wZW5Qb3BvdXRzLnB1c2goYnJvd3NlclBvcG91dCk7XG5cbiAgICAgICAgcmV0dXJuIGJyb3dzZXJQb3BvdXQ7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQXR0YWNoZXMgRHJhZ0xpc3RlbmVyIHRvIGFueSBnaXZlbiBET00gZWxlbWVudFxuICAgICAqIGFuZCB0dXJucyBpdCBpbnRvIGEgd2F5IG9mIGNyZWF0aW5nIG5ldyBDb250ZW50SXRlbXNcbiAgICAgKiBieSAnZHJhZ2dpbmcnIHRoZSBET00gZWxlbWVudCBpbnRvIHRoZSBsYXlvdXRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtqUXVlcnkgRE9NIGVsZW1lbnR9IGVsZW1lbnRcbiAgICAgKiBAcGFyYW0gICB7T2JqZWN0fEZ1bmN0aW9ufSBpdGVtQ29uZmlnIGZvciB0aGUgbmV3IGl0ZW0gdG8gYmUgY3JlYXRlZCwgb3IgYSBmdW5jdGlvbiB3aGljaCB3aWxsIHByb3ZpZGUgaXRcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtEcmFnU291cmNlfSAgYW4gb3BhcXVlIG9iamVjdCB0aGF0IGlkZW50aWZpZXMgdGhlIERPTSBlbGVtZW50XG5cdCAqICAgICAgICAgIGFuZCB0aGUgYXR0YWNoZWQgaXRlbUNvbmZpZy4gVGhpcyBjYW4gYmUgdXNlZCBpblxuXHQgKiAgICAgICAgICByZW1vdmVEcmFnU291cmNlKCkgbGF0ZXIgdG8gZ2V0IHJpZCBvZiB0aGUgZHJhZyBsaXN0ZW5lcnMuXG4gICAgICovXG4gICAgY3JlYXRlRHJhZ1NvdXJjZShlbGVtZW50LCBpdGVtQ29uZmlnKSB7XG4gICAgICAgIHRoaXMuY29uZmlnLnNldHRpbmdzLmNvbnN0cmFpbkRyYWdUb0NvbnRhaW5lciA9IGZhbHNlO1xuICAgICAgICB2YXIgZHJhZ1NvdXJjZSA9IG5ldyBEcmFnU291cmNlKCQoZWxlbWVudCksIGl0ZW1Db25maWcsIHRoaXMpO1xuICAgICAgICB0aGlzLl9kcmFnU291cmNlcy5wdXNoKGRyYWdTb3VyY2UpO1xuXG4gICAgICAgIHJldHVybiBkcmFnU291cmNlO1xuICAgIH1cblxuICAgIC8qKlxuXHQgKiBSZW1vdmVzIGEgRHJhZ0xpc3RlbmVyIGFkZGVkIGJ5IGNyZWF0ZURyYWdTb3VyY2UoKSBzbyB0aGUgY29ycmVzcG9uZGluZ1xuXHQgKiBET00gZWxlbWVudCBpcyBub3QgYSBkcmFnIHNvdXJjZSBhbnkgbW9yZS5cblx0ICpcblx0ICogQHBhcmFtICAge2pRdWVyeSBET00gZWxlbWVudH0gZWxlbWVudFxuXHQgKlxuXHQgKiBAcmV0dXJucyB7dm9pZH1cblx0ICovXG5cdHJlbW92ZURyYWdTb3VyY2UoZHJhZ1NvdXJjZSkge1xuXHRcdGRyYWdTb3VyY2UuZGVzdHJveSgpO1xuXHRcdGxtLnV0aWxzLnJlbW92ZUZyb21BcnJheSggZHJhZ1NvdXJjZSwgdGhpcy5fZHJhZ1NvdXJjZXMgKTtcblx0fVxuXG4gICAgLyoqXG4gICAgICogUHJvZ3JhbW1hdGljYWxseSBzZWxlY3RzIGFuIGl0ZW0uIFRoaXMgZGVzZWxlY3RzXG4gICAgICogdGhlIGN1cnJlbnRseSBzZWxlY3RlZCBpdGVtLCBzZWxlY3RzIHRoZSBzcGVjaWZpZWQgaXRlbVxuICAgICAqIGFuZCBlbWl0cyBhIHNlbGVjdGlvbkNoYW5nZWQgZXZlbnRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBpdGVtI1xuICAgICAqIEBwYXJhbSAgIHtbQm9vbGVhbl19IF8kc2lsZW50IFdoZWF0aGVyIHRvIG5vdGlmeSB0aGUgaXRlbSBvZiBpdHMgc2VsZWN0aW9uXG4gICAgICogQGV2ZW50ICAgIHNlbGVjdGlvbkNoYW5nZWRcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtWT0lEfVxuICAgICAqL1xuICAgIHNlbGVjdEl0ZW0oaXRlbSwgXyRzaWxlbnQpIHtcblxuICAgICAgICBpZiAodGhpcy5jb25maWcuc2V0dGluZ3Muc2VsZWN0aW9uRW5hYmxlZCAhPT0gdHJ1ZSkge1xuICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdQbGVhc2Ugc2V0IHNlbGVjdGlvbkVuYWJsZWQgdG8gdHJ1ZSB0byB1c2UgdGhpcyBmZWF0dXJlJyk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoaXRlbSA9PT0gdGhpcy5zZWxlY3RlZEl0ZW0pIHtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmICh0aGlzLnNlbGVjdGVkSXRlbSAhPT0gbnVsbCkge1xuICAgICAgICAgICAgdGhpcy5zZWxlY3RlZEl0ZW0uZGVzZWxlY3QoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmIChpdGVtICYmIF8kc2lsZW50ICE9PSB0cnVlKSB7XG4gICAgICAgICAgICBpdGVtLnNlbGVjdCgpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5zZWxlY3RlZEl0ZW0gPSBpdGVtO1xuXG4gICAgICAgIHRoaXMuZW1pdCgnc2VsZWN0aW9uQ2hhbmdlZCcsIGl0ZW0pO1xuICAgIH1cblxuICAgIC8qKioqKioqKioqKioqKioqKioqKioqKioqXG4gICAgICogUEFDS0FHRSBQUklWQVRFXG4gICAgICoqKioqKioqKioqKioqKioqKioqKioqKiovXG4gICAgXyRtYXhpbWlzZUl0ZW0oY29udGVudEl0ZW0pIHtcbiAgICAgICAgaWYgKHRoaXMuX21heGltaXNlZEl0ZW0gIT09IG51bGwpIHtcbiAgICAgICAgICAgIHRoaXMuXyRtaW5pbWlzZUl0ZW0odGhpcy5fbWF4aW1pc2VkSXRlbSk7XG4gICAgICAgIH1cbiAgICAgICAgdGhpcy5fbWF4aW1pc2VkSXRlbSA9IGNvbnRlbnRJdGVtO1xuICAgICAgICBjb250ZW50SXRlbS5vbiggJ2JlZm9yZUl0ZW1EZXN0cm95ZWQnLCB0aGlzLl8kY2xlYW51cEJlZm9yZU1heGltaXNlZEl0ZW1EZXN0cm95ZWQsIHRoaXMgKTtcbiAgICAgICAgdGhpcy5fbWF4aW1pc2VkSXRlbS5hZGRJZCgnX19nbE1heGltaXNlZCcpO1xuICAgICAgICBjb250ZW50SXRlbS5lbGVtZW50LmFkZENsYXNzKCdsbV9tYXhpbWlzZWQnKTtcbiAgICAgICAgY29udGVudEl0ZW0uZWxlbWVudC5hZnRlcih0aGlzLl9tYXhpbWlzZVBsYWNlaG9sZGVyKTtcbiAgICAgICAgdGhpcy5yb290LmVsZW1lbnQucHJlcGVuZChjb250ZW50SXRlbS5lbGVtZW50KTtcbiAgICAgICAgY29udGVudEl0ZW0uZWxlbWVudC53aWR0aCh0aGlzLmNvbnRhaW5lci53aWR0aCgpKTtcbiAgICAgICAgY29udGVudEl0ZW0uZWxlbWVudC5oZWlnaHQodGhpcy5jb250YWluZXIuaGVpZ2h0KCkpO1xuICAgICAgICBjb250ZW50SXRlbS5jYWxsRG93bndhcmRzKCdzZXRTaXplJyk7XG4gICAgICAgIHRoaXMuX21heGltaXNlZEl0ZW0uZW1pdCgnbWF4aW1pc2VkJyk7XG4gICAgICAgIHRoaXMuZW1pdCgnc3RhdGVDaGFuZ2VkJyk7XG4gICAgfVxuXG4gICAgXyRtaW5pbWlzZUl0ZW0oY29udGVudEl0ZW0pIHtcbiAgICAgICAgY29udGVudEl0ZW0uZWxlbWVudC5yZW1vdmVDbGFzcygnbG1fbWF4aW1pc2VkJyk7XG4gICAgICAgIGNvbnRlbnRJdGVtLnJlbW92ZUlkKCdfX2dsTWF4aW1pc2VkJyk7XG4gICAgICAgIHRoaXMuX21heGltaXNlUGxhY2Vob2xkZXIuYWZ0ZXIoY29udGVudEl0ZW0uZWxlbWVudCk7XG4gICAgICAgIHRoaXMuX21heGltaXNlUGxhY2Vob2xkZXIucmVtb3ZlKCk7XG4gICAgICAgIGNvbnRlbnRJdGVtLnBhcmVudC5jYWxsRG93bndhcmRzKCdzZXRTaXplJyk7XG4gICAgICAgIHRoaXMuX21heGltaXNlZEl0ZW0gPSBudWxsO1xuICAgICAgICBjb250ZW50SXRlbS5vZmYoICdiZWZvcmVJdGVtRGVzdHJveWVkJywgdGhpcy5fJGNsZWFudXBCZWZvcmVNYXhpbWlzZWRJdGVtRGVzdHJveWVkLCB0aGlzICk7XG4gICAgICAgIGNvbnRlbnRJdGVtLmVtaXQoJ21pbmltaXNlZCcpO1xuICAgICAgICB0aGlzLmVtaXQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgIH1cblxuICAgIF8kY2xlYW51cEJlZm9yZU1heGltaXNlZEl0ZW1EZXN0cm95ZWQoKSB7XG5cdFx0aWYgKHRoaXMuX21heGltaXNlZEl0ZW0gPT09IGV2ZW50Lm9yaWdpbikge1xuXHRcdFx0dGhpcy5fbWF4aW1pc2VkSXRlbS5vZmYoICdiZWZvcmVJdGVtRGVzdHJveWVkJywgdGhpcy5fJGNsZWFudXBCZWZvcmVNYXhpbWlzZWRJdGVtRGVzdHJveWVkLCB0aGlzICk7XG5cdFx0XHR0aGlzLl9tYXhpbWlzZWRJdGVtID0gbnVsbDtcblx0XHR9XG4gICAgfVxuICAgIFxuICAgIC8qKlxuICAgICAqIFRoaXMgbWV0aG9kIGlzIHVzZWQgdG8gZ2V0IGFyb3VuZCBzYW5kYm94ZWQgaWZyYW1lIHJlc3RyaWN0aW9ucy5cbiAgICAgKiBJZiAnYWxsb3ctdG9wLW5hdmlnYXRpb24nIGlzIG5vdCBzcGVjaWZpZWQgaW4gdGhlIGlmcmFtZSdzICdzYW5kYm94JyBhdHRyaWJ1dGVcbiAgICAgKiAoYXMgaXMgdGhlIGNhc2Ugd2l0aCBjb2RlcGVucykgdGhlIHBhcmVudCB3aW5kb3cgaXMgZm9yYmlkZGVuIGZyb20gY2FsbGluZyBjZXJ0YWluXG4gICAgICogbWV0aG9kcyBvbiB0aGUgY2hpbGQsIHN1Y2ggYXMgd2luZG93LmNsb3NlKCkgb3Igc2V0dGluZyBkb2N1bWVudC5sb2NhdGlvbi5ocmVmLlxuICAgICAqXG4gICAgICogVGhpcyBwcmV2ZW50ZWQgR29sZGVuTGF5b3V0IHBvcG91dHMgZnJvbSBwb3BwaW5nIGluIGluIGNvZGVwZW5zLiBUaGUgZml4IGlzIHRvIGNhbGxcbiAgICAgKiBfJGNsb3NlV2luZG93IG9uIHRoZSBjaGlsZCB3aW5kb3cncyBnbCBpbnN0YW5jZSB3aGljaCAoYWZ0ZXIgYSB0aW1lb3V0IHRvIGRpc2Nvbm5lY3RcbiAgICAgKiB0aGUgaW52b2tpbmcgbWV0aG9kIGZyb20gdGhlIGNsb3NlIGNhbGwpIGNsb3NlcyBpdHNlbGYuXG4gICAgICpcbiAgICAgKiBAcGFja2FnZVByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF8kY2xvc2VXaW5kb3coKSB7XG4gICAgICAgIHdpbmRvdy5zZXRUaW1lb3V0KGZ1bmN0aW9uKCkge1xuICAgICAgICAgICAgd2luZG93LmNsb3NlKCk7XG4gICAgICAgIH0sIDEpO1xuICAgIH1cblxuICAgIF8kZ2V0QXJlYSh4LCB5KSB7XG4gICAgICAgIHZhciBpLCBhcmVhLCBzbWFsbGVzdFN1cmZhY2UgPSBJbmZpbml0eSxcbiAgICAgICAgICAgIG1hdGhpbmdBcmVhID0gbnVsbDtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5faXRlbUFyZWFzLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBhcmVhID0gdGhpcy5faXRlbUFyZWFzW2ldO1xuXG4gICAgICAgICAgICBpZiAoXG4gICAgICAgICAgICAgICAgeCA+IGFyZWEueDEgJiZcbiAgICAgICAgICAgICAgICB4IDwgYXJlYS54MiAmJlxuICAgICAgICAgICAgICAgIHkgPiBhcmVhLnkxICYmXG4gICAgICAgICAgICAgICAgeSA8IGFyZWEueTIgJiZcbiAgICAgICAgICAgICAgICBzbWFsbGVzdFN1cmZhY2UgPiBhcmVhLnN1cmZhY2VcbiAgICAgICAgICAgICkge1xuICAgICAgICAgICAgICAgIHNtYWxsZXN0U3VyZmFjZSA9IGFyZWEuc3VyZmFjZTtcbiAgICAgICAgICAgICAgICBtYXRoaW5nQXJlYSA9IGFyZWE7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICByZXR1cm4gbWF0aGluZ0FyZWE7XG4gICAgfVxuXG4gICAgXyRjcmVhdGVSb290SXRlbUFyZWFzKCkge1xuICAgICAgICB2YXIgYXJlYVNpemUgPSA1MDtcbiAgICAgICAgdmFyIHNpZGVzID0ge1xuICAgICAgICAgICAgeTI6ICd5MScsXG4gICAgICAgICAgICB4MjogJ3gxJyxcbiAgICAgICAgICAgIHkxOiAneTInLFxuICAgICAgICAgICAgeDE6ICd4MidcbiAgICAgICAgfTtcbiAgICAgICAgZm9yICh2YXIgc2lkZSBpbiBzaWRlcykge1xuICAgICAgICAgICAgdmFyIGFyZWEgPSB0aGlzLnJvb3QuXyRnZXRBcmVhKCk7XG4gICAgICAgICAgICBhcmVhLnNpZGUgPSBzaWRlO1xuICAgICAgICAgICAgaWYgKHNpZGVzW3NpZGVdWzFdID09PSAnMicgKVxuICAgICAgICAgICAgICAgIGFyZWFbc2lkZV0gPSBhcmVhW3NpZGVzW3NpZGVdXSAtIGFyZWFTaXplO1xuICAgICAgICAgICAgZWxzZVxuICAgICAgICAgICAgICAgIGFyZWFbc2lkZV0gPSBhcmVhW3NpZGVzW3NpZGVdXSArIGFyZWFTaXplO1xuICAgICAgICAgICAgYXJlYS5zdXJmYWNlID0gKGFyZWEueDIgLSBhcmVhLngxKSAqIChhcmVhLnkyIC0gYXJlYS55MSk7XG4gICAgICAgICAgICB0aGlzLl9pdGVtQXJlYXMucHVzaChhcmVhKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIF8kY2FsY3VsYXRlSXRlbUFyZWFzKCkge1xuICAgICAgICB2YXIgaSwgYXJlYSwgYWxsQ29udGVudEl0ZW1zID0gdGhpcy5fZ2V0QWxsQ29udGVudEl0ZW1zKCk7XG4gICAgICAgIHRoaXMuX2l0ZW1BcmVhcyA9IFtdO1xuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBJZiB0aGUgbGFzdCBpdGVtIGlzIGRyYWdnZWQgb3V0LCBoaWdobGlnaHQgdGhlIGVudGlyZSBjb250YWluZXIgc2l6ZSB0b1xuICAgICAgICAgKiBhbGxvdyB0byByZS1kcm9wIGl0LiBhbGxDb250ZW50SXRlbXNbIDAgXSA9PT0gdGhpcy5yb290IGF0IHRoaXMgcG9pbnRcbiAgICAgICAgICpcbiAgICAgICAgICogRG9uJ3QgaW5jbHVkZSByb290IGludG8gdGhlIHBvc3NpYmxlIGRyb3AgYXJlYXMgdGhvdWdoIG90aGVyd2lzZSBzaW5jZSBpdFxuICAgICAgICAgKiB3aWxsIHVzZWQgZm9yIGV2ZXJ5IGdhcCBpbiB0aGUgbGF5b3V0LCBlLmcuIHNwbGl0dGVyc1xuICAgICAgICAgKi9cbiAgICAgICAgaWYgKGFsbENvbnRlbnRJdGVtcy5sZW5ndGggPT09IDEpIHtcbiAgICAgICAgICAgIHRoaXMuX2l0ZW1BcmVhcy5wdXNoKHRoaXMucm9vdC5fJGdldEFyZWEoKSk7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cbiAgICAgICAgdGhpcy5fJGNyZWF0ZVJvb3RJdGVtQXJlYXMoKTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgYWxsQ29udGVudEl0ZW1zLmxlbmd0aDsgaSsrKSB7XG5cbiAgICAgICAgICAgIGlmICghKGFsbENvbnRlbnRJdGVtc1tpXS5pc1N0YWNrKSkge1xuICAgICAgICAgICAgICAgIGNvbnRpbnVlO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICBhcmVhID0gYWxsQ29udGVudEl0ZW1zW2ldLl8kZ2V0QXJlYSgpO1xuXG4gICAgICAgICAgICBpZiAoYXJlYSA9PT0gbnVsbCkge1xuICAgICAgICAgICAgICAgIGNvbnRpbnVlO1xuICAgICAgICAgICAgfSBlbHNlIGlmIChhcmVhIGluc3RhbmNlb2YgQXJyYXkpIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9pdGVtQXJlYXMgPSB0aGlzLl9pdGVtQXJlYXMuY29uY2F0KGFyZWEpO1xuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9pdGVtQXJlYXMucHVzaChhcmVhKTtcbiAgICAgICAgICAgICAgICB2YXIgaGVhZGVyID0ge307XG4gICAgICAgICAgICAgICAgY29weShoZWFkZXIsIGFyZWEpO1xuICAgICAgICAgICAgICAgIGNvcHkoaGVhZGVyLCBhcmVhLmNvbnRlbnRJdGVtLl9jb250ZW50QXJlYURpbWVuc2lvbnMuaGVhZGVyLmhpZ2hsaWdodEFyZWEpO1xuICAgICAgICAgICAgICAgIGhlYWRlci5zdXJmYWNlID0gKGhlYWRlci54MiAtIGhlYWRlci54MSkgKiAoaGVhZGVyLnkyIC0gaGVhZGVyLnkxKTtcbiAgICAgICAgICAgICAgICB0aGlzLl9pdGVtQXJlYXMucHVzaChoZWFkZXIpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVGFrZXMgYSBjb250ZW50SXRlbSBvciBhIGNvbmZpZ3VyYXRpb24gYW5kIG9wdGlvbmFsbHkgYSBwYXJlbnRcbiAgICAgKiBpdGVtIGFuZCByZXR1cm5zIGFuIGluaXRpYWxpc2VkIGluc3RhbmNlIG9mIHRoZSBjb250ZW50SXRlbS5cbiAgICAgKiBJZiB0aGUgY29udGVudEl0ZW0gaXMgYSBmdW5jdGlvbiwgaXQgaXMgZmlyc3QgY2FsbGVkXG4gICAgICpcbiAgICAgKiBAcGFja2FnZVByaXZhdGVcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBYnRyYWN0Q29udGVudEl0ZW18T2JqZWN0fEZ1bmN0aW9ufSBjb250ZW50SXRlbU9yQ29uZmlnXG4gICAgICogQHBhcmFtICAge0FidHJhY3RDb250ZW50SXRlbX0gcGFyZW50IE9ubHkgbmVjZXNzYXJ5IHdoZW4gcGFzc2luZyBpbiBjb25maWdcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtBYnRyYWN0Q29udGVudEl0ZW19XG4gICAgICovXG4gICAgXyRub3JtYWxpemVDb250ZW50SXRlbShjb250ZW50SXRlbU9yQ29uZmlnLCBwYXJlbnQpIHtcbiAgICAgICAgaWYgKCFjb250ZW50SXRlbU9yQ29uZmlnKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ05vIGNvbnRlbnQgaXRlbSBkZWZpbmVkJyk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoaXNGdW5jdGlvbihjb250ZW50SXRlbU9yQ29uZmlnKSkge1xuICAgICAgICAgICAgY29udGVudEl0ZW1PckNvbmZpZyA9IGNvbnRlbnRJdGVtT3JDb25maWcoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmIChjb250ZW50SXRlbU9yQ29uZmlnIGluc3RhbmNlb2YgQWJzdHJhY3RDb250ZW50SXRlbSkge1xuICAgICAgICAgICAgcmV0dXJuIGNvbnRlbnRJdGVtT3JDb25maWc7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoJC5pc1BsYWluT2JqZWN0KGNvbnRlbnRJdGVtT3JDb25maWcpICYmIGNvbnRlbnRJdGVtT3JDb25maWcudHlwZSkge1xuICAgICAgICAgICAgdmFyIG5ld0NvbnRlbnRJdGVtID0gdGhpcy5jcmVhdGVDb250ZW50SXRlbShjb250ZW50SXRlbU9yQ29uZmlnLCBwYXJlbnQpO1xuICAgICAgICAgICAgbmV3Q29udGVudEl0ZW0uY2FsbERvd253YXJkcygnXyRpbml0Jyk7XG4gICAgICAgICAgICByZXR1cm4gbmV3Q29udGVudEl0ZW07XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0ludmFsaWQgY29udGVudEl0ZW0nKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEl0ZXJhdGVzIHRocm91Z2ggdGhlIGFycmF5IG9mIG9wZW4gcG9wb3V0IHdpbmRvd3MgYW5kIHJlbW92ZXMgdGhlIG9uZXNcbiAgICAgKiB0aGF0IGFyZSBlZmZlY3RpdmVseSBjbG9zZWQuIFRoaXMgaXMgbmVjZXNzYXJ5IGR1ZSB0byB0aGUgbGFjayBvZiByZWxpYWJseVxuICAgICAqIGxpc3RlbmluZyBmb3Igd2luZG93LmNsb3NlIC8gdW5sb2FkIGV2ZW50cyBpbiBhIGNyb3NzIGJyb3dzZXIgY29tcGF0aWJsZSBmYXNoaW9uLlxuICAgICAqXG4gICAgICogQHBhY2thZ2VQcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfJHJlY29uY2lsZVBvcG91dFdpbmRvd3MoKSB7XG4gICAgICAgIHZhciBvcGVuUG9wb3V0cyA9IFtdLFxuICAgICAgICAgICAgaTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5vcGVuUG9wb3V0cy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMub3BlblBvcG91dHNbaV0uZ2V0V2luZG93KCkuY2xvc2VkID09PSBmYWxzZSkge1xuICAgICAgICAgICAgICAgIG9wZW5Qb3BvdXRzLnB1c2godGhpcy5vcGVuUG9wb3V0c1tpXSk7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIHRoaXMuZW1pdCgnd2luZG93Q2xvc2VkJywgdGhpcy5vcGVuUG9wb3V0c1tpXSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICBpZiAodGhpcy5vcGVuUG9wb3V0cy5sZW5ndGggIT09IG9wZW5Qb3BvdXRzLmxlbmd0aCkge1xuICAgICAgICAgICAgdGhpcy5vcGVuUG9wb3V0cyA9IG9wZW5Qb3BvdXRzO1xuICAgICAgICAgICAgdGhpcy5lbWl0KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICAgICAgfVxuXG4gICAgfVxuXG4gICAgLyoqKioqKioqKioqKioqKioqKioqKioqKioqKlxuICAgICAqIFBSSVZBVEVcbiAgICAgKioqKioqKioqKioqKioqKioqKioqKioqKioqL1xuICAgIC8qKlxuICAgICAqIFJldHVybnMgYSBmbGF0dGVuZWQgYXJyYXkgb2YgYWxsIGNvbnRlbnQgaXRlbXMsXG4gICAgICogcmVnYXJkbGVzIG9mIGxldmVsIG9yIHR5cGVcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfZ2V0QWxsQ29udGVudEl0ZW1zKCkge1xuICAgICAgICB2YXIgYWxsQ29udGVudEl0ZW1zID0gW107XG5cbiAgICAgICAgdmFyIGFkZENoaWxkcmVuID0gZnVuY3Rpb24oY29udGVudEl0ZW0pIHtcbiAgICAgICAgICAgIGFsbENvbnRlbnRJdGVtcy5wdXNoKGNvbnRlbnRJdGVtKTtcblxuICAgICAgICAgICAgaWYgKGNvbnRlbnRJdGVtLmNvbnRlbnRJdGVtcyBpbnN0YW5jZW9mIEFycmF5KSB7XG4gICAgICAgICAgICAgICAgZm9yICh2YXIgaSA9IDA7IGkgPCBjb250ZW50SXRlbS5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgICAgICAgICAgYWRkQ2hpbGRyZW4oY29udGVudEl0ZW0uY29udGVudEl0ZW1zW2ldKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG4gICAgICAgIH07XG5cbiAgICAgICAgYWRkQ2hpbGRyZW4odGhpcy5yb290KTtcblxuICAgICAgICByZXR1cm4gYWxsQ29udGVudEl0ZW1zO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEJpbmRzIHRvIERPTS9CT00gZXZlbnRzIG9uIGluaXRcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfYmluZEV2ZW50cygpIHtcbiAgICAgICAgaWYgKHRoaXMuX2lzRnVsbFBhZ2UpIHtcbiAgICAgICAgICAgICQod2luZG93KS5yZXNpemUodGhpcy5fcmVzaXplRnVuY3Rpb24pO1xuICAgICAgICB9XG4gICAgICAgICQod2luZG93KS5vbigndW5sb2FkIGJlZm9yZXVubG9hZCcsIHRoaXMuX3VubG9hZEZ1bmN0aW9uKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBEZWJvdW5jZXMgcmVzaXplIGV2ZW50c1xuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vblJlc2l6ZSgpIHtcbiAgICAgICAgY2xlYXJUaW1lb3V0KHRoaXMuX3Jlc2l6ZVRpbWVvdXRJZCk7XG4gICAgICAgIHRoaXMuX3Jlc2l6ZVRpbWVvdXRJZCA9IHNldFRpbWVvdXQoZm5CaW5kKHRoaXMudXBkYXRlU2l6ZSwgdGhpcyksIDEwMCk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRXh0ZW5kcyB0aGUgZGVmYXVsdCBjb25maWcgd2l0aCB0aGUgdXNlciBzcGVjaWZpYyBzZXR0aW5ncyBhbmQgYXBwbGllc1xuICAgICAqIGRlcml2YXRpb25zLiBQbGVhc2Ugbm90ZSB0aGF0IHRoZXJlJ3MgYSBzZXBhcmF0ZSBtZXRob2QgKEFic3RyYWN0Q29udGVudEl0ZW0uX2V4dGVuZEl0ZW1Ob2RlKVxuICAgICAqIHRoYXQgZGVhbHMgd2l0aCB0aGUgZXh0ZW5zaW9uIG9mIGl0ZW0gY29uZmlnc1xuICAgICAqXG4gICAgICogQHBhcmFtICAge09iamVjdH0gY29uZmlnXG4gICAgICogQHN0YXRpY1xuICAgICAqIEByZXR1cm5zIHtPYmplY3R9IGNvbmZpZ1xuICAgICAqL1xuICAgIF9jcmVhdGVDb25maWcoY29uZmlnKSB7XG4gICAgICAgIHZhciB3aW5kb3dDb25maWdLZXkgPSBnZXRRdWVyeVN0cmluZ1BhcmFtKCdnbC13aW5kb3cnKTtcblxuICAgICAgICBpZiAod2luZG93Q29uZmlnS2V5KSB7XG4gICAgICAgICAgICB0aGlzLmlzU3ViV2luZG93ID0gdHJ1ZTtcbiAgICAgICAgICAgIGNvbmZpZyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKHdpbmRvd0NvbmZpZ0tleSk7XG4gICAgICAgICAgICBjb25maWcgPSBKU09OLnBhcnNlKGNvbmZpZyk7XG4gICAgICAgICAgICBjb25maWcgPSAobmV3IENvbmZpZ01pbmlmaWVyKCkpLnVubWluaWZ5Q29uZmlnKGNvbmZpZyk7XG4gICAgICAgICAgICBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbSh3aW5kb3dDb25maWdLZXkpO1xuICAgICAgICB9XG5cbiAgICAgICAgY29uZmlnID0gJC5leHRlbmQodHJ1ZSwge30sIGRlZmF1bHRDb25maWcsIGNvbmZpZyk7XG5cbiAgICAgICAgdmFyIG5leHROb2RlID0gKG5vZGUpID0+IHtcbiAgICAgICAgICAgIGZvciAodmFyIGtleSBpbiBub2RlKSB7XG4gICAgICAgICAgICAgICAgaWYgKGtleSAhPT0gJ3Byb3BzJyAmJiB0eXBlb2Ygbm9kZVtrZXldID09PSAnb2JqZWN0Jykge1xuICAgICAgICAgICAgICAgICAgICBuZXh0Tm9kZShub2RlW2tleV0pO1xuICAgICAgICAgICAgICAgIH0gZWxzZSBpZiAoa2V5ID09PSAndHlwZScgJiYgdGhpcy5pc1JlYWN0Q29uZmlnKG5vZGUpKSB7XG4gICAgICAgICAgICAgICAgICAgIG5vZGUudHlwZSA9ICdjb21wb25lbnQnO1xuICAgICAgICAgICAgICAgICAgICBub2RlLmNvbXBvbmVudE5hbWUgPSBSRUFDVF9DT01QT05FTlRfSUQ7XG4gICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgbmV4dE5vZGUoY29uZmlnKTtcblxuICAgICAgICBpZiAoY29uZmlnLnNldHRpbmdzLmhhc0hlYWRlcnMgPT09IGZhbHNlKSB7XG4gICAgICAgICAgICBjb25maWcuZGltZW5zaW9ucy5oZWFkZXJIZWlnaHQgPSAwO1xuICAgICAgICB9XG5cbiAgICAgICAgcmV0dXJuIGNvbmZpZztcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBUaGlzIGlzIGV4ZWN1dGVkIHdoZW4gR29sZGVuTGF5b3V0IGRldGVjdHMgdGhhdCBpdCBpcyBydW5cbiAgICAgKiB3aXRoaW4gYSBwcmV2aW91c2x5IG9wZW5lZCBwb3BvdXQgd2luZG93LlxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9hZGp1c3RUb1dpbmRvd01vZGUoKSB7XG4gICAgICAgIHZhciBwb3BJbkJ1dHRvbiA9ICQoJzxkaXYgY2xhc3M9XCJsbV9wb3BpblwiIHRpdGxlPVwiJyArIHRoaXMuY29uZmlnLmxhYmVscy5wb3BpbiArICdcIj4nICtcbiAgICAgICAgICAgICc8ZGl2IGNsYXNzPVwibG1faWNvblwiPjwvZGl2PicgK1xuICAgICAgICAgICAgJzxkaXYgY2xhc3M9XCJsbV9iZ1wiPjwvZGl2PicgK1xuICAgICAgICAgICAgJzwvZGl2PicpO1xuXG4gICAgICAgIHBvcEluQnV0dG9uLmNsaWNrKGZuQmluZChmdW5jdGlvbigpIHtcbiAgICAgICAgICAgIHRoaXMuZW1pdCgncG9wSW4nKTtcbiAgICAgICAgfSwgdGhpcykpO1xuXG4gICAgICAgIGRvY3VtZW50LnRpdGxlID0gc3RyaXBUYWdzKHRoaXMuY29uZmlnLmNvbnRlbnRbMF0udGl0bGUpO1xuXG4gICAgICAgICQoJ2hlYWQnKS5hcHBlbmQoJCgnYm9keSBsaW5rLCBib2R5IHN0eWxlLCB0ZW1wbGF0ZSwgLmdsX2tlZXAnKSk7XG5cbiAgICAgICAgdGhpcy5jb250YWluZXIgPSAkKCdib2R5JylcbiAgICAgICAgICAgIC5odG1sKCcnKVxuICAgICAgICAgICAgLmNzcygndmlzaWJpbGl0eScsICd2aXNpYmxlJylcbiAgICAgICAgICAgIC5hcHBlbmQocG9wSW5CdXR0b24pO1xuXG4gICAgICAgIC8qXG4gICAgICAgICAqIFRoaXMgc2VlbXMgYSBiaXQgcG9pbnRsZXNzLCBidXQgYWN0dWFsbHkgY2F1c2VzIGEgcmVmbG93L3JlLWV2YWx1YXRpb24gZ2V0dGluZyBhcm91bmRcbiAgICAgICAgICogc2xpY2tncmlkJ3MgXCJDYW5ub3QgZmluZCBzdHlsZXNoZWV0LlwiIGJ1ZyBpbiBjaHJvbWVcbiAgICAgICAgICovXG4gICAgICAgIHZhciB4ID0gZG9jdW1lbnQuYm9keS5vZmZzZXRIZWlnaHQ7IC8vIGpzaGludCBpZ25vcmU6bGluZVxuXG4gICAgICAgIC8qXG4gICAgICAgICAqIEV4cG9zZSB0aGlzIGluc3RhbmNlIG9uIHRoZSB3aW5kb3cgb2JqZWN0XG4gICAgICAgICAqIHRvIGFsbG93IHRoZSBvcGVuaW5nIHdpbmRvdyB0byBpbnRlcmFjdCB3aXRoXG4gICAgICAgICAqIGl0XG4gICAgICAgICAqL1xuICAgICAgICB3aW5kb3cuX19nbEluc3RhbmNlID0gdGhpcztcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDcmVhdGVzIFN1YndpbmRvd3MgKGlmIHRoZXJlIGFyZSBhbnkpLiBUaHJvd3MgYW4gZXJyb3JcbiAgICAgKiBpZiBwb3BvdXRzIGFyZSBibG9ja2VkLlxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX2NyZWF0ZVN1YldpbmRvd3MoKSB7XG4gICAgICAgIHZhciBpLCBwb3BvdXQ7XG5cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHRoaXMuY29uZmlnLm9wZW5Qb3BvdXRzLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBwb3BvdXQgPSB0aGlzLmNvbmZpZy5vcGVuUG9wb3V0c1tpXTtcblxuICAgICAgICAgICAgdGhpcy5jcmVhdGVQb3BvdXQoXG4gICAgICAgICAgICAgICAgcG9wb3V0LmNvbnRlbnQsXG4gICAgICAgICAgICAgICAgcG9wb3V0LmRpbWVuc2lvbnMsXG4gICAgICAgICAgICAgICAgcG9wb3V0LnBhcmVudElkLFxuICAgICAgICAgICAgICAgIHBvcG91dC5pbmRleEluUGFyZW50XG4gICAgICAgICAgICApO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRGV0ZXJtaW5lcyB3aGF0IGVsZW1lbnQgdGhlIGxheW91dCB3aWxsIGJlIGNyZWF0ZWQgaW5cbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfc2V0Q29udGFpbmVyKCkge1xuICAgICAgICB2YXIgY29udGFpbmVyID0gJCh0aGlzLmNvbnRhaW5lciB8fCAnYm9keScpO1xuXG4gICAgICAgIGlmIChjb250YWluZXIubGVuZ3RoID09PSAwKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0dvbGRlbkxheW91dCBjb250YWluZXIgbm90IGZvdW5kJyk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoY29udGFpbmVyLmxlbmd0aCA+IDEpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignR29sZGVuTGF5b3V0IG1vcmUgdGhhbiBvbmUgY29udGFpbmVyIGVsZW1lbnQgc3BlY2lmaWVkJyk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoY29udGFpbmVyWzBdID09PSBkb2N1bWVudC5ib2R5KSB7XG4gICAgICAgICAgICB0aGlzLl9pc0Z1bGxQYWdlID0gdHJ1ZTtcblxuICAgICAgICAgICAgJCgnaHRtbCwgYm9keScpLmNzcyh7XG4gICAgICAgICAgICAgICAgaGVpZ2h0OiAnMTAwJScsXG4gICAgICAgICAgICAgICAgbWFyZ2luOiAwLFxuICAgICAgICAgICAgICAgIHBhZGRpbmc6IDAsXG4gICAgICAgICAgICAgICAgb3ZlcmZsb3c6ICdoaWRkZW4nXG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuY29udGFpbmVyID0gY29udGFpbmVyO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEtpY2tzIG9mIHRoZSBpbml0aWFsLCByZWN1cnNpdmUgY3JlYXRpb24gY2hhaW5cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtPYmplY3R9IGNvbmZpZyBHb2xkZW5MYXlvdXQgQ29uZmlnXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfY3JlYXRlKGNvbmZpZykge1xuICAgICAgICB2YXIgZXJyb3JNc2c7XG5cbiAgICAgICAgaWYgKCEoY29uZmlnLmNvbnRlbnQgaW5zdGFuY2VvZiBBcnJheSkpIHtcbiAgICAgICAgICAgIGlmIChjb25maWcuY29udGVudCA9PT0gdW5kZWZpbmVkKSB7XG4gICAgICAgICAgICAgICAgZXJyb3JNc2cgPSAnTWlzc2luZyBzZXR0aW5nIFxcJ2NvbnRlbnRcXCcgb24gdG9wIGxldmVsIG9mIGNvbmZpZ3VyYXRpb24nO1xuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICBlcnJvck1zZyA9ICdDb25maWd1cmF0aW9uIHBhcmFtZXRlciBcXCdjb250ZW50XFwnIG11c3QgYmUgYW4gYXJyYXknO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICB0aHJvdyBuZXcgQ29uZmlndXJhdGlvbkVycm9yKGVycm9yTXNnLCBjb25maWcpO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKGNvbmZpZy5jb250ZW50Lmxlbmd0aCA+IDEpIHtcbiAgICAgICAgICAgIGVycm9yTXNnID0gJ1RvcCBsZXZlbCBjb250ZW50IGNhblxcJ3QgY29udGFpbiBtb3JlIHRoZW4gb25lIGVsZW1lbnQuJztcbiAgICAgICAgICAgIHRocm93IG5ldyBDb25maWd1cmF0aW9uRXJyb3IoZXJyb3JNc2csIGNvbmZpZyk7XG4gICAgICAgIH1cblxuICAgICAgICB0aGlzLnJvb3QgPSBuZXcgUm9vdCh0aGlzLCB7XG4gICAgICAgICAgICBjb250ZW50OiBjb25maWcuY29udGVudFxuICAgICAgICB9LCB0aGlzLmNvbnRhaW5lcik7XG4gICAgICAgIHRoaXMucm9vdC5jYWxsRG93bndhcmRzKCdfJGluaXQnKTtcblxuICAgICAgICBpZiAoY29uZmlnLm1heGltaXNlZEl0ZW1JZCA9PT0gJ19fZ2xNYXhpbWlzZWQnKSB7XG4gICAgICAgICAgICB0aGlzLnJvb3QuZ2V0SXRlbXNCeUlkKGNvbmZpZy5tYXhpbWlzZWRJdGVtSWQpWzBdLnRvZ2dsZU1heGltaXNlKCk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxsZWQgd2hlbiB0aGUgd2luZG93IGlzIGNsb3NlZCBvciB0aGUgdXNlciBuYXZpZ2F0ZXMgYXdheVxuICAgICAqIGZyb20gdGhlIHBhZ2VcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vblVubG9hZCgpIHtcbiAgICAgICAgaWYgKHRoaXMuY29uZmlnLnNldHRpbmdzLmNsb3NlUG9wb3V0c09uVW5sb2FkID09PSB0cnVlKSB7XG4gICAgICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoaXMub3BlblBvcG91dHMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgICAgICB0aGlzLm9wZW5Qb3BvdXRzW2ldLmNsb3NlKCk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBBZGp1c3RzIHRoZSBudW1iZXIgb2YgY29sdW1ucyB0byBiZSBsb3dlciB0byBmaXQgdGhlIHNjcmVlbiBhbmQgc3RpbGwgbWFpbnRhaW4gbWluSXRlbVdpZHRoLlxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX2FkanVzdENvbHVtbnNSZXNwb25zaXZlKCkge1xuICAgICAgICAvLyBJZiB0aGVyZSBpcyBubyBtaW4gd2lkdGggc2V0LCBvciBub3QgY29udGVudCBpdGVtcywgZG8gbm90aGluZy5cbiAgICAgICAgaWYgKCF0aGlzLl91c2VSZXNwb25zaXZlTGF5b3V0KCkgfHwgdGhpcy5fdXBkYXRpbmdDb2x1bW5zUmVzcG9uc2l2ZSB8fCAhdGhpcy5jb25maWcuZGltZW5zaW9ucyB8fCAhdGhpcy5jb25maWcuZGltZW5zaW9ucy5taW5JdGVtV2lkdGggfHwgdGhpcy5yb290LmNvbnRlbnRJdGVtcy5sZW5ndGggPT09IDAgfHwgIXRoaXMucm9vdC5jb250ZW50SXRlbXNbMF0uaXNSb3cpIHtcbiAgICAgICAgICAgIHRoaXMuX2ZpcnN0TG9hZCA9IGZhbHNlO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fZmlyc3RMb2FkID0gZmFsc2U7XG5cbiAgICAgICAgLy8gSWYgdGhlcmUgaXMgb25seSBvbmUgY29sdW1uLCBkbyBub3RoaW5nLlxuICAgICAgICB2YXIgY29sdW1uQ291bnQgPSB0aGlzLnJvb3QuY29udGVudEl0ZW1zWzBdLmNvbnRlbnRJdGVtcy5sZW5ndGg7XG4gICAgICAgIGlmIChjb2x1bW5Db3VudCA8PSAxKSB7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICAvLyBJZiB0aGV5IGFsbCBzdGlsbCBmaXQsIGRvIG5vdGhpbmcuXG4gICAgICAgIHZhciBtaW5JdGVtV2lkdGggPSB0aGlzLmNvbmZpZy5kaW1lbnNpb25zLm1pbkl0ZW1XaWR0aDtcbiAgICAgICAgdmFyIHRvdGFsTWluV2lkdGggPSBjb2x1bW5Db3VudCAqIG1pbkl0ZW1XaWR0aDtcbiAgICAgICAgaWYgKHRvdGFsTWluV2lkdGggPD0gdGhpcy53aWR0aCkge1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgLy8gUHJldmVudCB1cGRhdGVzIHdoaWxlIGl0IGlzIGFscmVhZHkgaGFwcGVuaW5nLlxuICAgICAgICB0aGlzLl91cGRhdGluZ0NvbHVtbnNSZXNwb25zaXZlID0gdHJ1ZTtcblxuICAgICAgICAvLyBGaWd1cmUgb3V0IGhvdyBtYW55IGNvbHVtbnMgdG8gc3RhY2ssIGFuZCBwdXQgdGhlbSBhbGwgaW4gdGhlIGZpcnN0IHN0YWNrIGNvbnRhaW5lci5cbiAgICAgICAgdmFyIGZpbmFsQ29sdW1uQ291bnQgPSBNYXRoLm1heChNYXRoLmZsb29yKHRoaXMud2lkdGggLyBtaW5JdGVtV2lkdGgpLCAxKTtcbiAgICAgICAgdmFyIHN0YWNrQ29sdW1uQ291bnQgPSBjb2x1bW5Db3VudCAtIGZpbmFsQ29sdW1uQ291bnQ7XG5cbiAgICAgICAgdmFyIHJvb3RDb250ZW50SXRlbSA9IHRoaXMucm9vdC5jb250ZW50SXRlbXNbMF07XG4gICAgICAgIHZhciBmaXJzdFN0YWNrQ29udGFpbmVyID0gdGhpcy5fZmluZEFsbFN0YWNrQ29udGFpbmVycygpWzBdO1xuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHN0YWNrQ29sdW1uQ291bnQ7IGkrKykge1xuICAgICAgICAgICAgLy8gU3RhY2sgZnJvbSByaWdodC5cbiAgICAgICAgICAgIHZhciBjb2x1bW4gPSByb290Q29udGVudEl0ZW0uY29udGVudEl0ZW1zW3Jvb3RDb250ZW50SXRlbS5jb250ZW50SXRlbXMubGVuZ3RoIC0gMV07XG4gICAgICAgICAgICB0aGlzLl9hZGRDaGlsZENvbnRlbnRJdGVtc1RvQ29udGFpbmVyKGZpcnN0U3RhY2tDb250YWluZXIsIGNvbHVtbik7XG4gICAgICAgIH1cblxuICAgICAgICB0aGlzLl91cGRhdGluZ0NvbHVtbnNSZXNwb25zaXZlID0gZmFsc2U7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRGV0ZXJtaW5lcyBpZiByZXNwb25zaXZlIGxheW91dCBzaG91bGQgYmUgdXNlZC5cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtib29sfSAtIFRydWUgaWYgcmVzcG9uc2l2ZSBsYXlvdXQgc2hvdWxkIGJlIHVzZWQ7IG90aGVyd2lzZSBmYWxzZS5cbiAgICAgKi9cbiAgICBfdXNlUmVzcG9uc2l2ZUxheW91dCgpIHtcbiAgICAgICAgcmV0dXJuIHRoaXMuY29uZmlnLnNldHRpbmdzICYmICh0aGlzLmNvbmZpZy5zZXR0aW5ncy5yZXNwb25zaXZlTW9kZSA9PSAnYWx3YXlzJyB8fCAodGhpcy5jb25maWcuc2V0dGluZ3MucmVzcG9uc2l2ZU1vZGUgPT0gJ29ubG9hZCcgJiYgdGhpcy5fZmlyc3RMb2FkKSk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQWRkcyBhbGwgY2hpbGRyZW4gb2YgYSBub2RlIHRvIGFub3RoZXIgY29udGFpbmVyIHJlY3Vyc2l2ZWx5LlxuICAgICAqIEBwYXJhbSB7b2JqZWN0fSBjb250YWluZXIgLSBDb250YWluZXIgdG8gYWRkIGNoaWxkIGNvbnRlbnQgaXRlbXMgdG8uXG4gICAgICogQHBhcmFtIHtvYmplY3R9IG5vZGUgLSBOb2RlIHRvIHNlYXJjaCBmb3IgY29udGVudCBpdGVtcy5cbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfYWRkQ2hpbGRDb250ZW50SXRlbXNUb0NvbnRhaW5lcihjb250YWluZXIsIG5vZGUpIHtcbiAgICAgICAgaWYgKG5vZGUudHlwZSA9PT0gJ3N0YWNrJykge1xuICAgICAgICAgICAgbm9kZS5jb250ZW50SXRlbXMuZm9yRWFjaChmdW5jdGlvbihpdGVtKSB7XG4gICAgICAgICAgICAgICAgY29udGFpbmVyLmFkZENoaWxkKGl0ZW0pO1xuICAgICAgICAgICAgICAgIG5vZGUucmVtb3ZlQ2hpbGQoaXRlbSwgdHJ1ZSk7XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIG5vZGUuY29udGVudEl0ZW1zLmZvckVhY2goZm5CaW5kKGZ1bmN0aW9uKGl0ZW0pIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9hZGRDaGlsZENvbnRlbnRJdGVtc1RvQ29udGFpbmVyKGNvbnRhaW5lciwgaXRlbSk7XG4gICAgICAgICAgICB9LCB0aGlzKSk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBGaW5kcyBhbGwgdGhlIHN0YWNrIGNvbnRhaW5lcnMuXG4gICAgICogQHJldHVybnMge2FycmF5fSAtIFRoZSBmb3VuZCBzdGFjayBjb250YWluZXJzLlxuICAgICAqL1xuICAgIF9maW5kQWxsU3RhY2tDb250YWluZXJzKCkge1xuICAgICAgICB2YXIgc3RhY2tDb250YWluZXJzID0gW107XG4gICAgICAgIHRoaXMuX2ZpbmRBbGxTdGFja0NvbnRhaW5lcnNSZWN1cnNpdmUoc3RhY2tDb250YWluZXJzLCB0aGlzLnJvb3QpO1xuXG4gICAgICAgIHJldHVybiBzdGFja0NvbnRhaW5lcnM7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRmluZHMgYWxsIHRoZSBzdGFjayBjb250YWluZXJzLlxuICAgICAqXG4gICAgICogQHBhcmFtIHthcnJheX0gLSBTZXQgb2YgY29udGFpbmVycyB0byBwb3B1bGF0ZS5cbiAgICAgKiBAcGFyYW0ge29iamVjdH0gLSBDdXJyZW50IG5vZGUgdG8gcHJvY2Vzcy5cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9maW5kQWxsU3RhY2tDb250YWluZXJzUmVjdXJzaXZlKHN0YWNrQ29udGFpbmVycywgbm9kZSkge1xuICAgICAgICBub2RlLmNvbnRlbnRJdGVtcy5mb3JFYWNoKGZuQmluZChmdW5jdGlvbihpdGVtKSB7XG4gICAgICAgICAgICBpZiAoaXRlbS50eXBlID09ICdzdGFjaycpIHtcbiAgICAgICAgICAgICAgICBzdGFja0NvbnRhaW5lcnMucHVzaChpdGVtKTtcbiAgICAgICAgICAgIH0gZWxzZSBpZiAoIWl0ZW0uaXNDb21wb25lbnQpIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9maW5kQWxsU3RhY2tDb250YWluZXJzUmVjdXJzaXZlKHN0YWNrQ29udGFpbmVycywgaXRlbSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH0sIHRoaXMpKTtcbiAgICB9XG59XG5cbi8qKlxuICogSG9vayB0aGF0IGFsbG93cyB0byBhY2Nlc3MgcHJpdmF0ZSBjbGFzc2VzXG4gKi9cbi8vIExheW91dE1hbmFnZXIuX19sbSA9IGxtO1xuIiwiY29uc3QgaXRlbURlZmF1bHRDb25maWcgPSB7XG4gICAgaXNDbG9zYWJsZTogdHJ1ZSxcbiAgICByZW9yZGVyRW5hYmxlZDogdHJ1ZSxcbiAgICB0aXRsZTogJydcbn1cblxuZXhwb3J0IGRlZmF1bHQgaXRlbURlZmF1bHRDb25maWdcbiIsImNvbnN0IGRlZmF1bHRDb25maWcgPSB7XG4gICAgb3BlblBvcG91dHM6IFtdLFxuICAgIHNldHRpbmdzOiB7XG4gICAgICAgIGhhc0hlYWRlcnM6IHRydWUsXG4gICAgICAgIGNvbnN0cmFpbkRyYWdUb0NvbnRhaW5lcjogdHJ1ZSxcbiAgICAgICAgcmVvcmRlckVuYWJsZWQ6IHRydWUsXG4gICAgICAgIHNlbGVjdGlvbkVuYWJsZWQ6IGZhbHNlLFxuICAgICAgICBwb3BvdXRXaG9sZVN0YWNrOiBmYWxzZSxcbiAgICAgICAgYmxvY2tlZFBvcG91dHNUaHJvd0Vycm9yOiB0cnVlLFxuICAgICAgICBjbG9zZVBvcG91dHNPblVubG9hZDogdHJ1ZSxcbiAgICAgICAgc2hvd1BvcG91dEljb246IHRydWUsXG4gICAgICAgIHNob3dNYXhpbWlzZUljb246IHRydWUsXG4gICAgICAgIHNob3dDbG9zZUljb246IHRydWUsXG4gICAgICAgIHJlc3BvbnNpdmVNb2RlOiAnb25sb2FkJywgLy8gQ2FuIGJlIG9ubG9hZCwgYWx3YXlzLCBvciBub25lLlxuICAgICAgICB0YWJPdmVybGFwQWxsb3dhbmNlOiAwLCAvLyBtYXhpbXVtIHBpeGVsIG92ZXJsYXAgcGVyIHRhYlxuICAgICAgICByZW9yZGVyT25UYWJNZW51Q2xpY2s6IHRydWUsXG4gICAgICAgIHRhYkNvbnRyb2xPZmZzZXQ6IDEwXG4gICAgfSxcbiAgICBkaW1lbnNpb25zOiB7XG4gICAgICAgIGJvcmRlcldpZHRoOiA1LFxuICAgICAgICBib3JkZXJHcmFiV2lkdGg6IDE1LFxuICAgICAgICBtaW5JdGVtSGVpZ2h0OiAxMCxcbiAgICAgICAgbWluSXRlbVdpZHRoOiAxMCxcbiAgICAgICAgaGVhZGVySGVpZ2h0OiAyMCxcbiAgICAgICAgZHJhZ1Byb3h5V2lkdGg6IDMwMCxcbiAgICAgICAgZHJhZ1Byb3h5SGVpZ2h0OiAyMDBcbiAgICB9LFxuICAgIGxhYmVsczoge1xuICAgICAgICBjbG9zZTogJ2Nsb3NlJyxcbiAgICAgICAgbWF4aW1pc2U6ICdtYXhpbWlzZScsXG4gICAgICAgIG1pbmltaXNlOiAnbWluaW1pc2UnLFxuICAgICAgICBwb3BvdXQ6ICdvcGVuIGluIG5ldyB3aW5kb3cnLFxuICAgICAgICBwb3BpbjogJ3BvcCBpbicsXG4gICAgICAgIHRhYkRyb3Bkb3duOiAnYWRkaXRpb25hbCB0YWJzJ1xuICAgIH1cbn1cblxuZXhwb3J0IGRlZmF1bHQgZGVmYXVsdENvbmZpZ1xuIiwiaW1wb3J0IEV2ZW50RW1pdHRlciBmcm9tICcuLi91dGlscy9FdmVudEVtaXR0ZXInXG5pbXBvcnQgJCBmcm9tICdqcXVlcnknXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIEl0ZW1Db250YWluZXIgZXh0ZW5kcyBFdmVudEVtaXR0ZXIge1xuICAgIGNvbnN0cnVjdG9yKGNvbmZpZywgcGFyZW50LCBsYXlvdXRNYW5hZ2VyKSB7XG5cbiAgICAgICAgc3VwZXIoKTtcblxuICAgICAgICB0aGlzLndpZHRoID0gbnVsbDtcbiAgICAgICAgdGhpcy5oZWlnaHQgPSBudWxsO1xuICAgICAgICB0aGlzLnRpdGxlID0gY29uZmlnLmNvbXBvbmVudE5hbWU7XG4gICAgICAgIHRoaXMucGFyZW50ID0gcGFyZW50O1xuICAgICAgICB0aGlzLmxheW91dE1hbmFnZXIgPSBsYXlvdXRNYW5hZ2VyO1xuICAgICAgICB0aGlzLmlzSGlkZGVuID0gZmFsc2U7XG5cbiAgICAgICAgdGhpcy5fY29uZmlnID0gY29uZmlnO1xuICAgICAgICB0aGlzLl9lbGVtZW50ID0gJChbXG4gICAgICAgICAgICAnPGRpdiBjbGFzcz1cImxtX2l0ZW1fY29udGFpbmVyXCI+JyxcbiAgICAgICAgICAgICc8ZGl2IGNsYXNzPVwibG1fY29udGVudFwiPjwvZGl2PicsXG4gICAgICAgICAgICAnPC9kaXY+J1xuICAgICAgICBdLmpvaW4oJycpKTtcblxuICAgICAgICB0aGlzLl9jb250ZW50RWxlbWVudCA9IHRoaXMuX2VsZW1lbnQuZmluZCgnLmxtX2NvbnRlbnQnKTtcbiAgICB9XG5cblxuICAgIC8qKlxuICAgICAqIEdldCB0aGUgaW5uZXIgRE9NIGVsZW1lbnQgdGhlIGNvbnRhaW5lcidzIGNvbnRlbnRcbiAgICAgKiBpcyBpbnRlbmRlZCB0byBsaXZlIGluXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7RE9NIGVsZW1lbnR9XG4gICAgICovXG4gICAgZ2V0RWxlbWVudCgpIHtcbiAgICAgICAgcmV0dXJuIHRoaXMuX2NvbnRlbnRFbGVtZW50O1xuICAgIH1cblxuXG4gICAgLyoqXG4gICAgICogSGlkZSB0aGUgY29udGFpbmVyLiBOb3RpZmllcyB0aGUgY29udGFpbmVycyBjb250ZW50IGZpcnN0XG4gICAgICogYW5kIHRoZW4gaGlkZXMgdGhlIERPTSBub2RlLiBJZiB0aGUgY29udGFpbmVyIGlzIGFscmVhZHkgaGlkZGVuXG4gICAgICogdGhpcyBzaG91bGQgaGF2ZSBubyBlZmZlY3RcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGhpZGUoKSB7XG4gICAgICAgIHRoaXMuZW1pdCgnaGlkZScpO1xuICAgICAgICB0aGlzLmlzSGlkZGVuID0gdHJ1ZTtcbiAgICAgICAgdGhpcy5fZWxlbWVudC5oaWRlKCk7XG4gICAgfVxuXG5cbiAgICAvKipcbiAgICAgKiBTaG93cyBhIHByZXZpb3VzbHkgaGlkZGVuIGNvbnRhaW5lci4gTm90aWZpZXMgdGhlXG4gICAgICogY29udGFpbmVycyBjb250ZW50IGZpcnN0IGFuZCB0aGVuIHNob3dzIHRoZSBET00gZWxlbWVudC5cbiAgICAgKiBJZiB0aGUgY29udGFpbmVyIGlzIGFscmVhZHkgdmlzaWJsZSB0aGlzIGhhcyBubyBlZmZlY3QuXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBzaG93KCkge1xuICAgICAgICB0aGlzLmVtaXQoJ3Nob3cnKTtcbiAgICAgICAgdGhpcy5pc0hpZGRlbiA9IGZhbHNlO1xuICAgICAgICB0aGlzLl9lbGVtZW50LnNob3coKTtcbiAgICAgICAgLy8gY2FsbCBzaG93biBvbmx5IGlmIHRoZSBjb250YWluZXIgaGFzIGEgdmFsaWQgc2l6ZVxuICAgICAgICBpZiAodGhpcy5oZWlnaHQgIT0gMCB8fCB0aGlzLndpZHRoICE9IDApIHtcbiAgICAgICAgICAgIHRoaXMuZW1pdCgnc2hvd24nKTtcbiAgICAgICAgfVxuICAgIH1cblxuXG4gICAgLyoqXG4gICAgICogU2V0IHRoZSBzaXplIGZyb20gd2l0aGluIHRoZSBjb250YWluZXIuIFRyYXZlcnNlcyB1cFxuICAgICAqIHRoZSBpdGVtIHRyZWUgdW50aWwgaXQgZmluZHMgYSByb3cgb3IgY29sdW1uIGVsZW1lbnRcbiAgICAgKiBhbmQgcmVzaXplcyBpdHMgaXRlbXMgYWNjb3JkaW5nbHkuXG4gICAgICpcbiAgICAgKiBJZiB0aGlzIGNvbnRhaW5lciBpc24ndCBhIGRlc2NlbmRhbnQgb2YgYSByb3cgb3IgY29sdW1uXG4gICAgICogaXQgcmV0dXJucyBmYWxzZVxuICAgICAqIEB0b2RvICBSZXdvcmshISFcbiAgICAgKiBAcGFyYW0ge051bWJlcn0gd2lkdGggIFRoZSBuZXcgd2lkdGggaW4gcGl4ZWxcbiAgICAgKiBAcGFyYW0ge051bWJlcn0gaGVpZ2h0IFRoZSBuZXcgaGVpZ2h0IGluIHBpeGVsXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7Qm9vbGVhbn0gcmVzaXplU3VjY2VzZnVsXG4gICAgICovXG4gICAgc2V0U2l6ZSh3aWR0aCwgaGVpZ2h0KSB7XG4gICAgICAgIHZhciByb3dPckNvbHVtbiA9IHRoaXMucGFyZW50LFxuICAgICAgICAgICAgcm93T3JDb2x1bW5DaGlsZCA9IHRoaXMsXG4gICAgICAgICAgICB0b3RhbFBpeGVsLFxuICAgICAgICAgICAgcGVyY2VudGFnZSxcbiAgICAgICAgICAgIGRpcmVjdGlvbixcbiAgICAgICAgICAgIG5ld1NpemUsXG4gICAgICAgICAgICBkZWx0YSxcbiAgICAgICAgICAgIGk7XG5cbiAgICAgICAgd2hpbGUgKCFyb3dPckNvbHVtbi5pc0NvbHVtbiAmJiAhcm93T3JDb2x1bW4uaXNSb3cpIHtcbiAgICAgICAgICAgIHJvd09yQ29sdW1uQ2hpbGQgPSByb3dPckNvbHVtbjtcbiAgICAgICAgICAgIHJvd09yQ29sdW1uID0gcm93T3JDb2x1bW4ucGFyZW50O1xuXG5cbiAgICAgICAgICAgIC8qKlxuICAgICAgICAgICAgICogTm8gcm93IG9yIGNvbHVtbiBoYXMgYmVlbiBmb3VuZFxuICAgICAgICAgICAgICovXG4gICAgICAgICAgICBpZiAocm93T3JDb2x1bW4uaXNSb290KSB7XG4gICAgICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgZGlyZWN0aW9uID0gcm93T3JDb2x1bW4uaXNDb2x1bW4gPyBcImhlaWdodFwiIDogXCJ3aWR0aFwiO1xuICAgICAgICBuZXdTaXplID0gZGlyZWN0aW9uID09PSBcImhlaWdodFwiID8gaGVpZ2h0IDogd2lkdGg7XG5cbiAgICAgICAgdG90YWxQaXhlbCA9IHRoaXNbZGlyZWN0aW9uXSAqICgxIC8gKHJvd09yQ29sdW1uQ2hpbGQuY29uZmlnW2RpcmVjdGlvbl0gLyAxMDApKTtcbiAgICAgICAgcGVyY2VudGFnZSA9IChuZXdTaXplIC8gdG90YWxQaXhlbCkgKiAxMDA7XG4gICAgICAgIGRlbHRhID0gKHJvd09yQ29sdW1uQ2hpbGQuY29uZmlnW2RpcmVjdGlvbl0gLSBwZXJjZW50YWdlKSAvIChyb3dPckNvbHVtbi5jb250ZW50SXRlbXMubGVuZ3RoIC0gMSk7XG5cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHJvd09yQ29sdW1uLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHJvd09yQ29sdW1uLmNvbnRlbnRJdGVtc1tpXSA9PT0gcm93T3JDb2x1bW5DaGlsZCkge1xuICAgICAgICAgICAgICAgIHJvd09yQ29sdW1uLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbZGlyZWN0aW9uXSA9IHBlcmNlbnRhZ2U7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIHJvd09yQ29sdW1uLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbZGlyZWN0aW9uXSArPSBkZWx0YTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgIHJvd09yQ29sdW1uLmNhbGxEb3dud2FyZHMoJ3NldFNpemUnKTtcblxuICAgICAgICByZXR1cm4gdHJ1ZTtcbiAgICB9XG5cblxuICAgIC8qKlxuICAgICAqIENsb3NlcyB0aGUgY29udGFpbmVyIGlmIGl0IGlzIGNsb3NhYmxlLiBDYW4gYmUgY2FsbGVkIGJ5XG4gICAgICogYm90aCB0aGUgY29tcG9uZW50IHdpdGhpbiBhdCBhcyB3ZWxsIGFzIHRoZSBjb250ZW50SXRlbSBjb250YWluaW5nXG4gICAgICogaXQuIEVtaXRzIGEgY2xvc2UgZXZlbnQgYmVmb3JlIHRoZSBjb250YWluZXIgaXRzZWxmIGlzIGNsb3NlZC5cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGNsb3NlKCkge1xuICAgICAgICBpZiAodGhpcy5fY29uZmlnLmlzQ2xvc2FibGUpIHtcbiAgICAgICAgICAgIHRoaXMuZW1pdCgnY2xvc2UnKTtcbiAgICAgICAgICAgIHRoaXMucGFyZW50LmNsb3NlKCk7XG4gICAgICAgIH1cbiAgICB9XG5cblxuICAgIC8qKlxuICAgICAqIFJldHVybnMgdGhlIGN1cnJlbnQgc3RhdGUgb2JqZWN0XG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7T2JqZWN0fSBzdGF0ZVxuICAgICAqL1xuICAgIGdldFN0YXRlKCkge1xuICAgICAgICByZXR1cm4gdGhpcy5fY29uZmlnLmNvbXBvbmVudFN0YXRlO1xuICAgIH1cblxuXG4gICAgLyoqXG4gICAgICogTWVyZ2VzIHRoZSBwcm92aWRlZCBzdGF0ZSBpbnRvIHRoZSBjdXJyZW50IG9uZVxuICAgICAqXG4gICAgICogQHBhcmFtICAge09iamVjdH0gc3RhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGV4dGVuZFN0YXRlKHN0YXRlKSB7XG4gICAgICAgIHRoaXMuc2V0U3RhdGUoJC5leHRlbmQodHJ1ZSwgdGhpcy5nZXRTdGF0ZSgpLCBzdGF0ZSkpO1xuICAgIH1cblxuXG4gICAgLyoqXG4gICAgICogTm90aWZpZXMgdGhlIGxheW91dCBtYW5hZ2VyIG9mIGEgc3RhdGV1cGRhdGVcbiAgICAgKlxuICAgICAqIEBwYXJhbSB7c2VyaWFsaXNhYmxlfSBzdGF0ZVxuICAgICAqL1xuICAgIHNldFN0YXRlKHN0YXRlKSB7XG4gICAgICAgIHRoaXMuX2NvbmZpZy5jb21wb25lbnRTdGF0ZSA9IHN0YXRlO1xuICAgICAgICB0aGlzLnBhcmVudC5lbWl0QnViYmxpbmdFdmVudCgnc3RhdGVDaGFuZ2VkJyk7XG4gICAgfVxuXG5cbiAgICAvKipcbiAgICAgKiBTZXQncyB0aGUgY29tcG9uZW50cyB0aXRsZVxuICAgICAqXG4gICAgICogQHBhcmFtIHtTdHJpbmd9IHRpdGxlXG4gICAgICovXG4gICAgc2V0VGl0bGUodGl0bGUpIHtcbiAgICAgICAgdGhpcy5wYXJlbnQuc2V0VGl0bGUodGl0bGUpO1xuICAgIH1cblxuXG4gICAgLyoqXG4gICAgICogU2V0J3MgdGhlIGNvbnRhaW5lcnMgc2l6ZS4gQ2FsbGVkIGJ5IHRoZSBjb250YWluZXIncyBjb21wb25lbnQuXG4gICAgICogVG8gc2V0IHRoZSBzaXplIHByb2dyYW1tYXRpY2FsbHkgZnJvbSB3aXRoaW4gdGhlIGNvbnRhaW5lciBwbGVhc2VcbiAgICAgKiB1c2UgdGhlIHB1YmxpYyBzZXRTaXplIG1ldGhvZFxuICAgICAqXG4gICAgICogQHBhcmFtIHtbSW50XX0gd2lkdGggIGluIHB4XG4gICAgICogQHBhcmFtIHtbSW50XX0gaGVpZ2h0IGluIHB4XG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfJHNldFNpemUod2lkdGgsIGhlaWdodCkge1xuICAgICAgICBpZiAod2lkdGggIT09IHRoaXMud2lkdGggfHwgaGVpZ2h0ICE9PSB0aGlzLmhlaWdodCkge1xuICAgICAgICAgICAgdGhpcy53aWR0aCA9IHdpZHRoO1xuICAgICAgICAgICAgdGhpcy5oZWlnaHQgPSBoZWlnaHQ7XG4gICAgICAgICAgICAkLnplcHRvID8gdGhpcy5fY29udGVudEVsZW1lbnQud2lkdGgod2lkdGgpIDogdGhpcy5fY29udGVudEVsZW1lbnQub3V0ZXJXaWR0aCh3aWR0aCk7XG4gICAgICAgICAgICAkLnplcHRvID8gdGhpcy5fY29udGVudEVsZW1lbnQuaGVpZ2h0KGhlaWdodCkgOiB0aGlzLl9jb250ZW50RWxlbWVudC5vdXRlckhlaWdodChoZWlnaHQpO1xuICAgICAgICAgICAgdGhpcy5lbWl0KCdyZXNpemUnKTtcbiAgICAgICAgfVxuICAgIH1cbn1cbiIsImltcG9ydCBFdmVudEVtaXR0ZXIgZnJvbSAnLi4vdXRpbHMvRXZlbnRFbWl0dGVyJ1xuaW1wb3J0IENvbmZpZ01pbmlmaWVyIGZyb20gJy4uL3V0aWxzL0NvbmZpZ01pbmlmaWVyJ1xuaW1wb3J0IHtcbiAgICBmbkJpbmQsXG4gICAgZ2V0VW5pcXVlSWQsXG59IGZyb20gJy4uL3V0aWxzL3V0aWxzJ1xuaW1wb3J0ICQgZnJvbSAnanF1ZXJ5J1xuXG4vKipcbiAqIFBvcHMgYSBjb250ZW50IGl0ZW0gb3V0IGludG8gYSBuZXcgYnJvd3NlciB3aW5kb3cuXG4gKiBUaGlzIGlzIGFjaGlldmVkIGJ5XG4gKlxuICogICAgLSBDcmVhdGluZyBhIG5ldyBjb25maWd1cmF0aW9uIHdpdGggdGhlIGNvbnRlbnQgaXRlbSBhcyByb290IGVsZW1lbnRcbiAqICAgIC0gU2VyaWFsaXppbmcgYW5kIG1pbmlmeWluZyB0aGUgY29uZmlndXJhdGlvblxuICogICAgLSBPcGVuaW5nIHRoZSBjdXJyZW50IHdpbmRvdydzIFVSTCB3aXRoIHRoZSBjb25maWd1cmF0aW9uIGFzIGEgR0VUIHBhcmFtZXRlclxuICogICAgLSBHb2xkZW5MYXlvdXQgd2hlbiBvcGVuZWQgaW4gdGhlIG5ldyB3aW5kb3cgd2lsbCBsb29rIGZvciB0aGUgR0VUIHBhcmFtZXRlclxuICogICAgICBhbmQgdXNlIGl0IGluc3RlYWQgb2YgdGhlIHByb3ZpZGVkIGNvbmZpZ3VyYXRpb25cbiAqXG4gKiBAcGFyYW0ge09iamVjdH0gY29uZmlnIEdvbGRlbkxheW91dCBpdGVtIGNvbmZpZ1xuICogQHBhcmFtIHtPYmplY3R9IGRpbWVuc2lvbnMgQSBtYXAgd2l0aCB3aWR0aCwgaGVpZ2h0LCB0b3AgYW5kIGxlZnRcbiAqIEBwYXJhbSB7U3RyaW5nfSBwYXJlbnRJZCBUaGUgaWQgb2YgdGhlIGVsZW1lbnQgdGhlIGl0ZW0gd2lsbCBiZSBhcHBlbmRlZCB0byBvbiBwb3BJblxuICogQHBhcmFtIHtOdW1iZXJ9IGluZGV4SW5QYXJlbnQgVGhlIHBvc2l0aW9uIG9mIHRoaXMgZWxlbWVudCB3aXRoaW4gaXRzIHBhcmVudFxuICogQHBhcmFtIHtsbS5MYXlvdXRNYW5hZ2VyfSBsYXlvdXRNYW5hZ2VyXG4gKi9cblxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBCcm93c2VyUG9wb3V0IGV4dGVuZHMgRXZlbnRFbWl0dGVyIHtcbiAgICBjb25zdHJ1Y3Rvcihjb25maWcsIGRpbWVuc2lvbnMsIHBhcmVudElkLCBpbmRleEluUGFyZW50LCBsYXlvdXRNYW5hZ2VyKSB7XG5cbiAgICAgICAgc3VwZXIoKTtcbiAgICAgICAgXG4gICAgICAgIHRoaXMuaXNJbml0aWFsaXNlZCA9IGZhbHNlO1xuXG4gICAgICAgIHRoaXMuX2NvbmZpZyA9IGNvbmZpZztcbiAgICAgICAgdGhpcy5fZGltZW5zaW9ucyA9IGRpbWVuc2lvbnM7XG4gICAgICAgIHRoaXMuX3BhcmVudElkID0gcGFyZW50SWQ7XG4gICAgICAgIHRoaXMuX2luZGV4SW5QYXJlbnQgPSBpbmRleEluUGFyZW50O1xuICAgICAgICB0aGlzLl9sYXlvdXRNYW5hZ2VyID0gbGF5b3V0TWFuYWdlcjtcbiAgICAgICAgdGhpcy5fcG9wb3V0V2luZG93ID0gbnVsbDtcbiAgICAgICAgdGhpcy5faWQgPSBudWxsO1xuICAgICAgICB0aGlzLl9jcmVhdGVXaW5kb3coKTtcbiAgICB9XG5cbiAgICB0b0NvbmZpZygpIHtcbiAgICAgICAgaWYgKHRoaXMuaXNJbml0aWFsaXNlZCA9PT0gZmFsc2UpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ2FuXFwndCBjcmVhdGUgY29uZmlnLCBsYXlvdXQgbm90IHlldCBpbml0aWFsaXNlZCcpO1xuICAgICAgICB9XG4gICAgICAgIHJldHVybiB7XG4gICAgICAgICAgICBkaW1lbnNpb25zOiB7XG4gICAgICAgICAgICAgICAgd2lkdGg6IHRoaXMuZ2V0R2xJbnN0YW5jZSgpLndpZHRoLFxuICAgICAgICAgICAgICAgIGhlaWdodDogdGhpcy5nZXRHbEluc3RhbmNlKCkuaGVpZ2h0LFxuICAgICAgICAgICAgICAgIGxlZnQ6IHRoaXMuX3BvcG91dFdpbmRvdy5zY3JlZW5YIHx8IHRoaXMuX3BvcG91dFdpbmRvdy5zY3JlZW5MZWZ0LFxuICAgICAgICAgICAgICAgIHRvcDogdGhpcy5fcG9wb3V0V2luZG93LnNjcmVlblkgfHwgdGhpcy5fcG9wb3V0V2luZG93LnNjcmVlblRvcFxuICAgICAgICAgICAgfSxcbiAgICAgICAgICAgIGNvbnRlbnQ6IHRoaXMuZ2V0R2xJbnN0YW5jZSgpLnRvQ29uZmlnKCkuY29udGVudCxcbiAgICAgICAgICAgIHBhcmVudElkOiB0aGlzLl9wYXJlbnRJZCxcbiAgICAgICAgICAgIGluZGV4SW5QYXJlbnQ6IHRoaXMuX2luZGV4SW5QYXJlbnRcbiAgICAgICAgfTtcbiAgICB9XG5cbiAgICBnZXRHbEluc3RhbmNlKCkge1xuICAgICAgICByZXR1cm4gdGhpcy5fcG9wb3V0V2luZG93Ll9fZ2xJbnN0YW5jZTtcbiAgICB9XG5cbiAgICBnZXRXaW5kb3coKSB7XG4gICAgICAgIHJldHVybiB0aGlzLl9wb3BvdXRXaW5kb3c7XG4gICAgfVxuXG4gICAgY2xvc2UoKSB7XG4gICAgICAgIGlmICh0aGlzLmdldEdsSW5zdGFuY2UoKSkge1xuICAgICAgICAgICAgdGhpcy5nZXRHbEluc3RhbmNlKCkuXyRjbG9zZVdpbmRvdygpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgICAgICB0aGlzLmdldFdpbmRvdygpLmNsb3NlKCk7XG4gICAgICAgICAgICB9IGNhdGNoIChlKSB7XG4gICAgICAgICAgICAgICAgLy9cbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJldHVybnMgdGhlIHBvcHBlZCBvdXQgaXRlbSB0byBpdHMgb3JpZ2luYWwgcG9zaXRpb24uIElmIHRoZSBvcmlnaW5hbFxuICAgICAqIHBhcmVudCBpc24ndCBhdmFpbGFibGUgYW55bW9yZSBpdCBmYWxscyBiYWNrIHRvIHRoZSBsYXlvdXQncyB0b3Btb3N0IGVsZW1lbnRcbiAgICAgKi9cbiAgICBwb3BJbigpIHtcbiAgICAgICAgdmFyIGNoaWxkQ29uZmlnLFxuICAgICAgICAgICAgcGFyZW50SXRlbSxcbiAgICAgICAgICAgIGluZGV4ID0gdGhpcy5faW5kZXhJblBhcmVudDtcblxuICAgICAgICBpZiAodGhpcy5fcGFyZW50SWQpIHtcblxuICAgICAgICAgICAgLypcbiAgICAgICAgICAgICAqIFRoZSAkLmV4dGVuZCBjYWxsIHNlZW1zIGEgYml0IHBvaW50bGVzcywgYnV0IGl0J3MgY3J1Y2lhbCB0b1xuICAgICAgICAgICAgICogY29weSB0aGUgY29uZmlnIHJldHVybmVkIGJ5IHRoaXMuZ2V0R2xJbnN0YW5jZSgpLnRvQ29uZmlnKClcbiAgICAgICAgICAgICAqIG9udG8gYSBuZXcgb2JqZWN0LiBJbnRlcm5ldCBFeHBsb3JlciBrZWVwcyB0aGUgcmVmZXJlbmNlc1xuICAgICAgICAgICAgICogdG8gb2JqZWN0cyBvbiB0aGUgY2hpbGQgd2luZG93LCByZXN1bHRpbmcgaW4gdGhlIGZvbGxvd2luZyBlcnJvclxuICAgICAgICAgICAgICogb25jZSB0aGUgY2hpbGQgd2luZG93IGlzIGNsb3NlZDpcbiAgICAgICAgICAgICAqXG4gICAgICAgICAgICAgKiBUaGUgY2FsbGVlIChzZXJ2ZXIgW25vdCBzZXJ2ZXIgYXBwbGljYXRpb25dKSBpcyBub3QgYXZhaWxhYmxlIGFuZCBkaXNhcHBlYXJlZFxuICAgICAgICAgICAgICovXG4gICAgICAgICAgICBjaGlsZENvbmZpZyA9ICQuZXh0ZW5kKHRydWUsIHt9LCB0aGlzLmdldEdsSW5zdGFuY2UoKS50b0NvbmZpZygpKS5jb250ZW50WzBdO1xuICAgICAgICAgICAgcGFyZW50SXRlbSA9IHRoaXMuX2xheW91dE1hbmFnZXIucm9vdC5nZXRJdGVtc0J5SWQodGhpcy5fcGFyZW50SWQpWzBdO1xuXG4gICAgICAgICAgICAvKlxuICAgICAgICAgICAgICogRmFsbGJhY2sgaWYgcGFyZW50SXRlbSBpcyBub3QgYXZhaWxhYmxlLiBFaXRoZXIgYWRkIGl0IHRvIHRoZSB0b3Btb3N0XG4gICAgICAgICAgICAgKiBpdGVtIG9yIG1ha2UgaXQgdGhlIHRvcG1vc3QgaXRlbSBpZiB0aGUgbGF5b3V0IGlzIGVtcHR5XG4gICAgICAgICAgICAgKi9cbiAgICAgICAgICAgIGlmICghcGFyZW50SXRlbSkge1xuICAgICAgICAgICAgICAgIGlmICh0aGlzLl9sYXlvdXRNYW5hZ2VyLnJvb3QuY29udGVudEl0ZW1zLmxlbmd0aCA+IDApIHtcbiAgICAgICAgICAgICAgICAgICAgcGFyZW50SXRlbSA9IHRoaXMuX2xheW91dE1hbmFnZXIucm9vdC5jb250ZW50SXRlbXNbMF07XG4gICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgcGFyZW50SXRlbSA9IHRoaXMuX2xheW91dE1hbmFnZXIucm9vdDtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgaW5kZXggPSAwO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgcGFyZW50SXRlbS5hZGRDaGlsZChjaGlsZENvbmZpZywgdGhpcy5faW5kZXhJblBhcmVudCk7XG4gICAgICAgIHRoaXMuY2xvc2UoKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDcmVhdGVzIHRoZSBVUkwgYW5kIHdpbmRvdyBwYXJhbWV0ZXJcbiAgICAgKiBhbmQgb3BlbnMgYSBuZXcgd2luZG93XG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX2NyZWF0ZVdpbmRvdygpIHtcbiAgICAgICAgdmFyIGNoZWNrUmVhZHlJbnRlcnZhbCxcbiAgICAgICAgICAgIHVybCA9IHRoaXMuX2NyZWF0ZVVybCgpLFxuXG4gICAgICAgICAgICAvKipcbiAgICAgICAgICAgICAqIEJvZ3VzIHRpdGxlIHRvIHByZXZlbnQgcmUtdXNhZ2Ugb2YgZXhpc3Rpbmcgd2luZG93IHdpdGggdGhlXG4gICAgICAgICAgICAgKiBzYW1lIHRpdGxlLiBUaGUgYWN0dWFsIHRpdGxlIHdpbGwgYmUgc2V0IGJ5IHRoZSBuZXcgd2luZG93J3NcbiAgICAgICAgICAgICAqIEdvbGRlbkxheW91dCBpbnN0YW5jZSBpZiBpdCBkZXRlY3RzIHRoYXQgaXQgaXMgaW4gc3ViV2luZG93TW9kZVxuICAgICAgICAgICAgICovXG4gICAgICAgICAgICB0aXRsZSA9IE1hdGguZmxvb3IoTWF0aC5yYW5kb20oKSAqIDEwMDAwMDApLnRvU3RyaW5nKDM2KSxcblxuICAgICAgICAgICAgLyoqXG4gICAgICAgICAgICAgKiBUaGUgb3B0aW9ucyBhcyB1c2VkIGluIHRoZSB3aW5kb3cub3BlbiBzdHJpbmdcbiAgICAgICAgICAgICAqL1xuICAgICAgICAgICAgb3B0aW9ucyA9IHRoaXMuX3NlcmlhbGl6ZVdpbmRvd09wdGlvbnMoe1xuICAgICAgICAgICAgICAgIHdpZHRoOiB0aGlzLl9kaW1lbnNpb25zLndpZHRoLFxuICAgICAgICAgICAgICAgIGhlaWdodDogdGhpcy5fZGltZW5zaW9ucy5oZWlnaHQsXG4gICAgICAgICAgICAgICAgaW5uZXJXaWR0aDogdGhpcy5fZGltZW5zaW9ucy53aWR0aCxcbiAgICAgICAgICAgICAgICBpbm5lckhlaWdodDogdGhpcy5fZGltZW5zaW9ucy5oZWlnaHQsXG4gICAgICAgICAgICAgICAgbWVudWJhcjogJ25vJyxcbiAgICAgICAgICAgICAgICB0b29sYmFyOiAnbm8nLFxuICAgICAgICAgICAgICAgIGxvY2F0aW9uOiAnbm8nLFxuICAgICAgICAgICAgICAgIHBlcnNvbmFsYmFyOiAnbm8nLFxuICAgICAgICAgICAgICAgIHJlc2l6YWJsZTogJ3llcycsXG4gICAgICAgICAgICAgICAgc2Nyb2xsYmFyczogJ25vJyxcbiAgICAgICAgICAgICAgICBzdGF0dXM6ICdubydcbiAgICAgICAgICAgIH0pO1xuXG4gICAgICAgIHRoaXMuX3BvcG91dFdpbmRvdyA9IHdpbmRvdy5vcGVuKHVybCwgdGl0bGUsIG9wdGlvbnMpO1xuXG4gICAgICAgIGlmICghdGhpcy5fcG9wb3V0V2luZG93KSB7XG4gICAgICAgICAgICBpZiAodGhpcy5fbGF5b3V0TWFuYWdlci5jb25maWcuc2V0dGluZ3MuYmxvY2tlZFBvcG91dHNUaHJvd0Vycm9yID09PSB0cnVlKSB7XG4gICAgICAgICAgICAgICAgdmFyIGVycm9yID0gbmV3IEVycm9yKCdQb3BvdXQgYmxvY2tlZCcpO1xuICAgICAgICAgICAgICAgIGVycm9yLnR5cGUgPSAncG9wb3V0QmxvY2tlZCc7XG4gICAgICAgICAgICAgICAgdGhyb3cgZXJyb3I7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgICQodGhpcy5fcG9wb3V0V2luZG93KVxuICAgICAgICAgICAgLm9uKCdsb2FkJywgZm5CaW5kKHRoaXMuX3Bvc2l0aW9uV2luZG93LCB0aGlzKSlcbiAgICAgICAgICAgIC5vbigndW5sb2FkIGJlZm9yZXVubG9hZCcsIGZuQmluZCh0aGlzLl9vbkNsb3NlLCB0aGlzKSk7XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIFBvbGxpbmcgdGhlIGNoaWxkd2luZG93IHRvIGZpbmQgb3V0IGlmIEdvbGRlbkxheW91dCBoYXMgYmVlbiBpbml0aWFsaXNlZFxuICAgICAgICAgKiBkb2Vzbid0IHNlZW0gb3B0aW1hbCwgYnV0IHRoZSBhbHRlcm5hdGl2ZXMgLSBhZGRpbmcgYSBjYWxsYmFjayB0byB0aGUgcGFyZW50XG4gICAgICAgICAqIHdpbmRvdyBvciByYWlzaW5nIGFuIGV2ZW50IG9uIHRoZSB3aW5kb3cgb2JqZWN0IC0gYm90aCB3b3VsZCBpbnRyb2R1Y2Uga25vd2xlZGdlXG4gICAgICAgICAqIGFib3V0IHRoZSBwYXJlbnQgdG8gdGhlIGNoaWxkIHdpbmRvdyB3aGljaCB3ZSdkIHJhdGhlciBhdm9pZFxuICAgICAgICAgKi9cbiAgICAgICAgY2hlY2tSZWFkeUludGVydmFsID0gc2V0SW50ZXJ2YWwoZm5CaW5kKGZ1bmN0aW9uKCkge1xuICAgICAgICAgICAgaWYgKHRoaXMuX3BvcG91dFdpbmRvdy5fX2dsSW5zdGFuY2UgJiYgdGhpcy5fcG9wb3V0V2luZG93Ll9fZ2xJbnN0YW5jZS5pc0luaXRpYWxpc2VkKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5fb25Jbml0aWFsaXNlZCgpO1xuICAgICAgICAgICAgICAgIGNsZWFySW50ZXJ2YWwoY2hlY2tSZWFkeUludGVydmFsKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfSwgdGhpcyksIDEwKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBTZXJpYWxpc2VzIGEgbWFwIG9mIGtleTp2YWx1ZXMgdG8gYSB3aW5kb3cgb3B0aW9ucyBzdHJpbmdcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtPYmplY3R9IHdpbmRvd09wdGlvbnNcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtTdHJpbmd9IHNlcmlhbGlzZWQgd2luZG93IG9wdGlvbnNcbiAgICAgKi9cbiAgICBfc2VyaWFsaXplV2luZG93T3B0aW9ucyh3aW5kb3dPcHRpb25zKSB7XG4gICAgICAgIHZhciB3aW5kb3dPcHRpb25zU3RyaW5nID0gW10sXG4gICAgICAgICAgICBrZXk7XG5cbiAgICAgICAgZm9yIChrZXkgaW4gd2luZG93T3B0aW9ucykge1xuICAgICAgICAgICAgd2luZG93T3B0aW9uc1N0cmluZy5wdXNoKGtleSArICc9JyArIHdpbmRvd09wdGlvbnNba2V5XSk7XG4gICAgICAgIH1cblxuICAgICAgICByZXR1cm4gd2luZG93T3B0aW9uc1N0cmluZy5qb2luKCcsJyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ3JlYXRlcyB0aGUgVVJMIGZvciB0aGUgbmV3IHdpbmRvdywgaW5jbHVkaW5nIHRoZVxuICAgICAqIGNvbmZpZyBHRVQgcGFyYW1ldGVyXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7U3RyaW5nfSBVUkxcbiAgICAgKi9cbiAgICBfY3JlYXRlVXJsKCkge1xuICAgICAgICB2YXIgY29uZmlnID0ge1xuICAgICAgICAgICAgICAgIGNvbnRlbnQ6IHRoaXMuX2NvbmZpZ1xuICAgICAgICAgICAgfSxcbiAgICAgICAgICAgIHN0b3JhZ2VLZXkgPSAnZ2wtd2luZG93LWNvbmZpZy0nICsgZ2V0VW5pcXVlSWQoKSxcbiAgICAgICAgICAgIHVybFBhcnRzO1xuXG4gICAgICAgIGNvbmZpZyA9IChuZXcgQ29uZmlnTWluaWZpZXIoKSkubWluaWZ5Q29uZmlnKGNvbmZpZyk7XG5cbiAgICAgICAgdHJ5IHtcbiAgICAgICAgICAgIGxvY2FsU3RvcmFnZS5zZXRJdGVtKHN0b3JhZ2VLZXksIEpTT04uc3RyaW5naWZ5KGNvbmZpZykpO1xuICAgICAgICB9IGNhdGNoIChlKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0Vycm9yIHdoaWxlIHdyaXRpbmcgdG8gbG9jYWxTdG9yYWdlICcgKyBlLnRvU3RyaW5nKCkpO1xuICAgICAgICB9XG5cbiAgICAgICAgdXJsUGFydHMgPSBkb2N1bWVudC5sb2NhdGlvbi5ocmVmLnNwbGl0KCc/Jyk7XG5cbiAgICAgICAgLy8gVVJMIGRvZXNuJ3QgY29udGFpbiBHRVQtcGFyYW1ldGVyc1xuICAgICAgICBpZiAodXJsUGFydHMubGVuZ3RoID09PSAxKSB7XG4gICAgICAgICAgICByZXR1cm4gdXJsUGFydHNbMF0gKyAnP2dsLXdpbmRvdz0nICsgc3RvcmFnZUtleTtcblxuICAgICAgICAgICAgLy8gVVJMIGNvbnRhaW5zIEdFVC1wYXJhbWV0ZXJzXG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICByZXR1cm4gZG9jdW1lbnQubG9jYXRpb24uaHJlZiArICcmZ2wtd2luZG93PScgKyBzdG9yYWdlS2V5O1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogTW92ZSB0aGUgbmV3bHkgY3JlYXRlZCB3aW5kb3cgcm91Z2hseSB0b1xuICAgICAqIHdoZXJlIHRoZSBjb21wb25lbnQgdXNlZCB0byBiZS5cbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfcG9zaXRpb25XaW5kb3coKSB7XG4gICAgICAgIHRoaXMuX3BvcG91dFdpbmRvdy5tb3ZlVG8odGhpcy5fZGltZW5zaW9ucy5sZWZ0LCB0aGlzLl9kaW1lbnNpb25zLnRvcCk7XG4gICAgICAgIHRoaXMuX3BvcG91dFdpbmRvdy5mb2N1cygpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxiYWNrIHdoZW4gdGhlIG5ldyB3aW5kb3cgaXMgb3BlbmVkIGFuZCB0aGUgR29sZGVuTGF5b3V0IGluc3RhbmNlXG4gICAgICogd2l0aGluIGl0IGlzIGluaXRpYWxpc2VkXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfb25Jbml0aWFsaXNlZCgpIHtcbiAgICAgICAgdGhpcy5pc0luaXRpYWxpc2VkID0gdHJ1ZTtcbiAgICAgICAgdGhpcy5nZXRHbEluc3RhbmNlKCkub24oJ3BvcEluJywgdGhpcy5wb3BJbiwgdGhpcyk7XG4gICAgICAgIHRoaXMuZW1pdCgnaW5pdGlhbGlzZWQnKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBJbnZva2VkIDUwbXMgYWZ0ZXIgdGhlIHdpbmRvdyB1bmxvYWQgZXZlbnRcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfb25DbG9zZSgpIHtcbiAgICAgICAgc2V0VGltZW91dChmbkJpbmQodGhpcy5lbWl0LCB0aGlzLCBbJ2Nsb3NlZCddKSwgNTApO1xuICAgIH1cbn1cbiIsImltcG9ydCBFdmVudEVtaXR0ZXIgZnJvbSAnLi4vdXRpbHMvRXZlbnRFbWl0dGVyJ1xuaW1wb3J0IHtcbiAgICBzdHJpcFRhZ3MsXG4gICAgZ2V0VG91Y2hFdmVudFxufSBmcm9tICcuLi91dGlscy91dGlscyc7XG5pbXBvcnQgJCBmcm9tICdqcXVlcnknO1xuXG5jb25zdCBfdGVtcGxhdGUgPSAnPGRpdiBjbGFzcz1cImxtX2RyYWdQcm94eVwiPicgK1xuICAgICc8ZGl2IGNsYXNzPVwibG1faGVhZGVyXCI+JyArXG4gICAgJzx1bCBjbGFzcz1cImxtX3RhYnNcIj4nICtcbiAgICAnPGxpIGNsYXNzPVwibG1fdGFiIGxtX2FjdGl2ZVwiPjxpIGNsYXNzPVwibG1fbGVmdFwiPjwvaT4nICtcbiAgICAnPHNwYW4gY2xhc3M9XCJsbV90aXRsZVwiPjwvc3Bhbj4nICtcbiAgICAnPGkgY2xhc3M9XCJsbV9yaWdodFwiPjwvaT48L2xpPicgK1xuICAgICc8L3VsPicgK1xuICAgICc8L2Rpdj4nICtcbiAgICAnPGRpdiBjbGFzcz1cImxtX2NvbnRlbnRcIj48L2Rpdj4nICtcbiAgICAnPC9kaXY+JztcblxuLyoqXG4gKiBUaGlzIGNsYXNzIGNyZWF0ZXMgYSB0ZW1wb3JhcnkgY29udGFpbmVyXG4gKiBmb3IgdGhlIGNvbXBvbmVudCB3aGlsc3QgaXQgaXMgYmVpbmcgZHJhZ2dlZFxuICogYW5kIGhhbmRsZXMgZHJhZyBldmVudHNcbiAqXG4gKiBAY29uc3RydWN0b3JcbiAqIEBwcml2YXRlXG4gKlxuICogQHBhcmFtIHtOdW1iZXJ9IHggICAgICAgICAgICAgIFRoZSBpbml0aWFsIHggcG9zaXRpb25cbiAqIEBwYXJhbSB7TnVtYmVyfSB5ICAgICAgICAgICAgICBUaGUgaW5pdGlhbCB5IHBvc2l0aW9uXG4gKiBAcGFyYW0ge0RyYWdMaXN0ZW5lcn0gZHJhZ0xpc3RlbmVyXG4gKiBAcGFyYW0ge2xtLkxheW91dE1hbmFnZXJ9IGxheW91dE1hbmFnZXJcbiAqIEBwYXJhbSB7QWJzdHJhY3RDb250ZW50SXRlbX0gY29udGVudEl0ZW1cbiAqIEBwYXJhbSB7QWJzdHJhY3RDb250ZW50SXRlbX0gb3JpZ2luYWxQYXJlbnRcbiAqL1xuZXhwb3J0IGRlZmF1bHQgY2xhc3MgRHJhZ1Byb3h5IGV4dGVuZHMgRXZlbnRFbWl0dGVyIHtcblxuICAgIGNvbnN0cnVjdG9yKHgsIHksIGRyYWdMaXN0ZW5lciwgbGF5b3V0TWFuYWdlciwgY29udGVudEl0ZW0sIG9yaWdpbmFsUGFyZW50KSB7XG5cbiAgICAgICAgc3VwZXIoKTtcblxuICAgICAgICB0aGlzLl9kcmFnTGlzdGVuZXIgPSBkcmFnTGlzdGVuZXI7XG4gICAgICAgIHRoaXMuX2xheW91dE1hbmFnZXIgPSBsYXlvdXRNYW5hZ2VyO1xuICAgICAgICB0aGlzLl9jb250ZW50SXRlbSA9IGNvbnRlbnRJdGVtO1xuICAgICAgICB0aGlzLl9vcmlnaW5hbFBhcmVudCA9IG9yaWdpbmFsUGFyZW50O1xuXG4gICAgICAgIHRoaXMuX2FyZWEgPSBudWxsO1xuICAgICAgICB0aGlzLl9sYXN0VmFsaWRBcmVhID0gbnVsbDtcblxuICAgICAgICB0aGlzLl9kcmFnTGlzdGVuZXIub24oJ2RyYWcnLCB0aGlzLl9vbkRyYWcsIHRoaXMpO1xuICAgICAgICB0aGlzLl9kcmFnTGlzdGVuZXIub24oJ2RyYWdTdG9wJywgdGhpcy5fb25Ecm9wLCB0aGlzKTtcblxuICAgICAgICB0aGlzLmVsZW1lbnQgPSAkKF90ZW1wbGF0ZSk7XG4gICAgICAgIGlmIChvcmlnaW5hbFBhcmVudCAmJiBvcmlnaW5hbFBhcmVudC5fc2lkZSkge1xuICAgICAgICAgICAgdGhpcy5fc2lkZWQgPSBvcmlnaW5hbFBhcmVudC5fc2lkZWQ7XG4gICAgICAgICAgICB0aGlzLmVsZW1lbnQuYWRkQ2xhc3MoJ2xtXycgKyBvcmlnaW5hbFBhcmVudC5fc2lkZSk7XG4gICAgICAgICAgICBpZiAoWydyaWdodCcsICdib3R0b20nXS5pbmRleE9mKG9yaWdpbmFsUGFyZW50Ll9zaWRlKSA+PSAwKVxuICAgICAgICAgICAgICAgIHRoaXMuZWxlbWVudC5maW5kKCcubG1fY29udGVudCcpLmFmdGVyKHRoaXMuZWxlbWVudC5maW5kKCcubG1faGVhZGVyJykpO1xuICAgICAgICB9XG4gICAgICAgIHRoaXMuZWxlbWVudC5jc3Moe1xuICAgICAgICAgICAgbGVmdDogeCxcbiAgICAgICAgICAgIHRvcDogeVxuICAgICAgICB9KTtcbiAgICAgICAgdGhpcy5lbGVtZW50LmZpbmQoJy5sbV90YWInKS5hdHRyKCd0aXRsZScsIHN0cmlwVGFncyh0aGlzLl9jb250ZW50SXRlbS5jb25maWcudGl0bGUpKTtcbiAgICAgICAgdGhpcy5lbGVtZW50LmZpbmQoJy5sbV90aXRsZScpLmh0bWwodGhpcy5fY29udGVudEl0ZW0uY29uZmlnLnRpdGxlKTtcbiAgICAgICAgdGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIgPSB0aGlzLmVsZW1lbnQuZmluZCgnLmxtX2NvbnRlbnQnKTtcbiAgICAgICAgdGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIuYXBwZW5kKGNvbnRlbnRJdGVtLmVsZW1lbnQpO1xuXG4gICAgICAgIHRoaXMuX3VuZGlzcGxheVRyZWUoKTtcbiAgICAgICAgdGhpcy5fbGF5b3V0TWFuYWdlci5fJGNhbGN1bGF0ZUl0ZW1BcmVhcygpO1xuICAgICAgICB0aGlzLl9zZXREaW1lbnNpb25zKCk7XG5cbiAgICAgICAgJChkb2N1bWVudC5ib2R5KS5hcHBlbmQodGhpcy5lbGVtZW50KTtcblxuICAgICAgICB2YXIgb2Zmc2V0ID0gdGhpcy5fbGF5b3V0TWFuYWdlci5jb250YWluZXIub2Zmc2V0KCk7XG5cbiAgICAgICAgdGhpcy5fbWluWCA9IG9mZnNldC5sZWZ0O1xuICAgICAgICB0aGlzLl9taW5ZID0gb2Zmc2V0LnRvcDtcbiAgICAgICAgdGhpcy5fbWF4WCA9IHRoaXMuX2xheW91dE1hbmFnZXIuY29udGFpbmVyLndpZHRoKCkgKyB0aGlzLl9taW5YO1xuICAgICAgICB0aGlzLl9tYXhZID0gdGhpcy5fbGF5b3V0TWFuYWdlci5jb250YWluZXIuaGVpZ2h0KCkgKyB0aGlzLl9taW5ZO1xuICAgICAgICB0aGlzLl93aWR0aCA9IHRoaXMuZWxlbWVudC53aWR0aCgpO1xuICAgICAgICB0aGlzLl9oZWlnaHQgPSB0aGlzLmVsZW1lbnQuaGVpZ2h0KCk7XG5cbiAgICAgICAgdGhpcy5fc2V0RHJvcFBvc2l0aW9uKHgsIHkpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxiYWNrIG9uIGV2ZXJ5IG1vdXNlTW92ZSBldmVudCBkdXJpbmcgYSBkcmFnLiBEZXRlcm1pbmVzIGlmIHRoZSBkcmFnIGlzXG4gICAgICogc3RpbGwgd2l0aGluIHRoZSB2YWxpZCBkcmFnIGFyZWEgYW5kIGNhbGxzIHRoZSBsYXlvdXRNYW5hZ2VyIHRvIGhpZ2hsaWdodCB0aGVcbiAgICAgKiBjdXJyZW50IGRyb3AgYXJlYVxuICAgICAqXG4gICAgICogQHBhcmFtICAge051bWJlcn0gb2Zmc2V0WCBUaGUgZGlmZmVyZW5jZSBmcm9tIHRoZSBvcmlnaW5hbCB4IHBvc2l0aW9uIGluIHB4XG4gICAgICogQHBhcmFtICAge051bWJlcn0gb2Zmc2V0WSBUaGUgZGlmZmVyZW5jZSBmcm9tIHRoZSBvcmlnaW5hbCB5IHBvc2l0aW9uIGluIHB4XG4gICAgICogQHBhcmFtICAge2pRdWVyeSBET00gZXZlbnR9IGV2ZW50XG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX29uRHJhZyhvZmZzZXRYLCBvZmZzZXRZLCBldmVudCkge1xuICAgICAgICBldmVudCA9IGdldFRvdWNoRXZlbnQoZXZlbnQpXG5cbiAgICAgICAgdmFyIHggPSBldmVudC5wYWdlWCxcbiAgICAgICAgICAgIHkgPSBldmVudC5wYWdlWSxcbiAgICAgICAgICAgIGlzV2l0aGluQ29udGFpbmVyID0geCA+IHRoaXMuX21pblggJiYgeCA8IHRoaXMuX21heFggJiYgeSA+IHRoaXMuX21pblkgJiYgeSA8IHRoaXMuX21heFk7XG5cbiAgICAgICAgaWYgKCFpc1dpdGhpbkNvbnRhaW5lciAmJiB0aGlzLl9sYXlvdXRNYW5hZ2VyLmNvbmZpZy5zZXR0aW5ncy5jb25zdHJhaW5EcmFnVG9Db250YWluZXIgPT09IHRydWUpIHtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuX3NldERyb3BQb3NpdGlvbih4LCB5KTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBTZXRzIHRoZSB0YXJnZXQgcG9zaXRpb24sIGhpZ2hsaWdodGluZyB0aGUgYXBwcm9wcmlhdGUgYXJlYVxuICAgICAqXG4gICAgICogQHBhcmFtICAge051bWJlcn0geCBUaGUgeCBwb3NpdGlvbiBpbiBweFxuICAgICAqIEBwYXJhbSAgIHtOdW1iZXJ9IHkgVGhlIHkgcG9zaXRpb24gaW4gcHhcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfc2V0RHJvcFBvc2l0aW9uKHgsIHkpIHtcbiAgICAgICAgdGhpcy5lbGVtZW50LmNzcyh7XG4gICAgICAgICAgICBsZWZ0OiB4LFxuICAgICAgICAgICAgdG9wOiB5XG4gICAgICAgIH0pO1xuICAgICAgICB0aGlzLl9hcmVhID0gdGhpcy5fbGF5b3V0TWFuYWdlci5fJGdldEFyZWEoeCwgeSk7XG5cbiAgICAgICAgaWYgKHRoaXMuX2FyZWEgIT09IG51bGwpIHtcbiAgICAgICAgICAgIHRoaXMuX2xhc3RWYWxpZEFyZWEgPSB0aGlzLl9hcmVhO1xuICAgICAgICAgICAgdGhpcy5fYXJlYS5jb250ZW50SXRlbS5fJGhpZ2hsaWdodERyb3Bab25lKHgsIHksIHRoaXMuX2FyZWEpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ2FsbGJhY2sgd2hlbiB0aGUgZHJhZyBoYXMgZmluaXNoZWQuIERldGVybWluZXMgdGhlIGRyb3AgYXJlYVxuICAgICAqIGFuZCBhZGRzIHRoZSBjaGlsZCB0byBpdFxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vbkRyb3AoKSB7XG4gICAgICAgIHRoaXMuX3VwZGF0ZVRyZWUoKVxuICAgICAgICB0aGlzLl9sYXlvdXRNYW5hZ2VyLmRyb3BUYXJnZXRJbmRpY2F0b3IuaGlkZSgpO1xuXG4gICAgICAgIC8qXG4gICAgICAgICAqIFZhbGlkIGRyb3AgYXJlYSBmb3VuZFxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuX2FyZWEgIT09IG51bGwpIHtcbiAgICAgICAgICAgIHRoaXMuX2FyZWEuY29udGVudEl0ZW0uXyRvbkRyb3AodGhpcy5fY29udGVudEl0ZW0sIHRoaXMuX2FyZWEpO1xuXG4gICAgICAgICAgICAvKipcbiAgICAgICAgICAgICAqIE5vIHZhbGlkIGRyb3AgYXJlYSBhdmFpbGFibGUgYXQgcHJlc2VudCwgYnV0IG9uZSBoYXMgYmVlbiBmb3VuZCBiZWZvcmUuXG4gICAgICAgICAgICAgKiBVc2UgaXRcbiAgICAgICAgICAgICAqL1xuICAgICAgICB9IGVsc2UgaWYgKHRoaXMuX2xhc3RWYWxpZEFyZWEgIT09IG51bGwpIHtcbiAgICAgICAgICAgIHRoaXMuX2xhc3RWYWxpZEFyZWEuY29udGVudEl0ZW0uXyRvbkRyb3AodGhpcy5fY29udGVudEl0ZW0sIHRoaXMuX2xhc3RWYWxpZEFyZWEpO1xuXG4gICAgICAgICAgICAvKipcbiAgICAgICAgICAgICAqIE5vIHZhbGlkIGRyb3AgYXJlYSBmb3VuZCBkdXJpbmcgdGhlIGR1cmF0aW9uIG9mIHRoZSBkcmFnLiBSZXR1cm5cbiAgICAgICAgICAgICAqIGNvbnRlbnQgaXRlbSB0byBpdHMgb3JpZ2luYWwgcG9zaXRpb24gaWYgYSBvcmlnaW5hbCBwYXJlbnQgaXMgcHJvdmlkZWQuXG4gICAgICAgICAgICAgKiAoV2hpY2ggaXMgbm90IHRoZSBjYXNlIGlmIHRoZSBkcmFnIGhhZCBiZWVuIGluaXRpYXRlZCBieSBjcmVhdGVEcmFnU291cmNlKVxuICAgICAgICAgICAgICovXG4gICAgICAgIH0gZWxzZSBpZiAodGhpcy5fb3JpZ2luYWxQYXJlbnQpIHtcbiAgICAgICAgICAgIHRoaXMuX29yaWdpbmFsUGFyZW50LmFkZENoaWxkKHRoaXMuX2NvbnRlbnRJdGVtKTtcblxuICAgICAgICAgICAgLyoqXG4gICAgICAgICAgICAgKiBUaGUgZHJhZyBkaWRuJ3QgdWx0aW1hdGVseSBlbmQgdXAgd2l0aCBhZGRpbmcgdGhlIGNvbnRlbnQgaXRlbSB0b1xuICAgICAgICAgICAgICogYW55IGNvbnRhaW5lci4gSW4gb3JkZXIgdG8gZW5zdXJlIGNsZWFuIHVwIGhhcHBlbnMsIGRlc3Ryb3kgdGhlXG4gICAgICAgICAgICAgKiBjb250ZW50IGl0ZW0uXG4gICAgICAgICAgICAgKi9cbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRoaXMuX2NvbnRlbnRJdGVtLl8kZGVzdHJveSgpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5lbGVtZW50LnJlbW92ZSgpO1xuXG4gICAgICAgIHRoaXMuX2xheW91dE1hbmFnZXIuZW1pdCgnaXRlbURyb3BwZWQnLCB0aGlzLl9jb250ZW50SXRlbSk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVW5kaXNwbGF5cyB0aGUgaXRlbSBmcm9tIGl0cyBvcmlnaW5hbCBwb3NpdGlvbiB3aXRoaW4gdGhlIHRyZWVcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfdW5kaXNwbGF5VHJlZSgpIHtcblxuICAgICAgICAvKipcbiAgICAgICAgICogcGFyZW50IGlzIG51bGwgaWYgdGhlIGRyYWcgaGFkIGJlZW4gaW5pdGlhdGVkIGJ5IGEgZXh0ZXJuYWwgZHJhZyBzb3VyY2VcbiAgICAgICAgICovXG4gICAgICAgIGlmICh0aGlzLl9jb250ZW50SXRlbS5wYXJlbnQpIHtcbiAgICAgICAgICAgIHRoaXMuX2NvbnRlbnRJdGVtLnBhcmVudC51bmRpc3BsYXlDaGlsZCh0aGlzLl9jb250ZW50SXRlbSk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBSZW1vdmVzIHRoZSBpdGVtIGZyb20gaXRzIG9yaWdpbmFsIHBvc2l0aW9uIHdpdGhpbiB0aGUgdHJlZVxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF91cGRhdGVUcmVlKCkge1xuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBwYXJlbnQgaXMgbnVsbCBpZiB0aGUgZHJhZyBoYWQgYmVlbiBpbml0aWF0ZWQgYnkgYSBleHRlcm5hbCBkcmFnIHNvdXJjZVxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuX2NvbnRlbnRJdGVtLnBhcmVudCkge1xuICAgICAgICAgICAgdGhpcy5fY29udGVudEl0ZW0ucGFyZW50LnJlbW92ZUNoaWxkKHRoaXMuX2NvbnRlbnRJdGVtLCB0cnVlKTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuX2NvbnRlbnRJdGVtLl8kc2V0UGFyZW50KHRoaXMpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFVwZGF0ZXMgdGhlIERyYWcgUHJveGllJ3MgZGltZW5zaW9uc1xuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9zZXREaW1lbnNpb25zKCkge1xuICAgICAgICB2YXIgZGltZW5zaW9ucyA9IHRoaXMuX2xheW91dE1hbmFnZXIuY29uZmlnLmRpbWVuc2lvbnMsXG4gICAgICAgICAgICB3aWR0aCA9IGRpbWVuc2lvbnMuZHJhZ1Byb3h5V2lkdGgsXG4gICAgICAgICAgICBoZWlnaHQgPSBkaW1lbnNpb25zLmRyYWdQcm94eUhlaWdodDtcblxuICAgICAgICB0aGlzLmVsZW1lbnQud2lkdGgod2lkdGgpO1xuICAgICAgICB0aGlzLmVsZW1lbnQuaGVpZ2h0KGhlaWdodCk7XG4gICAgICAgIHdpZHRoIC09ICh0aGlzLl9zaWRlZCA/IGRpbWVuc2lvbnMuaGVhZGVySGVpZ2h0IDogMCk7XG4gICAgICAgIGhlaWdodCAtPSAoIXRoaXMuX3NpZGVkID8gZGltZW5zaW9ucy5oZWFkZXJIZWlnaHQgOiAwKTtcbiAgICAgICAgdGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIud2lkdGgod2lkdGgpO1xuICAgICAgICB0aGlzLmNoaWxkRWxlbWVudENvbnRhaW5lci5oZWlnaHQoaGVpZ2h0KTtcbiAgICAgICAgdGhpcy5fY29udGVudEl0ZW0uZWxlbWVudC53aWR0aCh3aWR0aCk7XG4gICAgICAgIHRoaXMuX2NvbnRlbnRJdGVtLmVsZW1lbnQuaGVpZ2h0KGhlaWdodCk7XG4gICAgICAgIHRoaXMuX2NvbnRlbnRJdGVtLmNhbGxEb3dud2FyZHMoJ18kc2hvdycpO1xuICAgICAgICB0aGlzLl9jb250ZW50SXRlbS5jYWxsRG93bndhcmRzKCdzZXRTaXplJyk7XG4gICAgfVxufVxuIiwiaW1wb3J0IERyYWdMaXN0ZW5lciBmcm9tICcuLi91dGlscy9EcmFnTGlzdGVuZXInXG5pbXBvcnQgRHJhZ1Byb3h5IGZyb20gJy4uL2NvbnRyb2xzL0RyYWdQcm94eSdcbmltcG9ydCB7XG4gICAgaXNGdW5jdGlvblxufSBmcm9tICcuLi91dGlscy91dGlscydcbmltcG9ydCAkIGZyb20gJ2pxdWVyeSdcblxuLyoqXG4gKiBBbGxvd3MgZm9yIGFueSBET00gaXRlbSB0byBjcmVhdGUgYSBjb21wb25lbnQgb24gZHJhZ1xuICogc3RhcnQgdG9iZSBkcmFnZ2VkIGludG8gdGhlIExheW91dFxuICpcbiAqIEBwYXJhbSB7alF1ZXJ5IGVsZW1lbnR9IGVsZW1lbnRcbiAqIEBwYXJhbSB7T2JqZWN0fSBpdGVtQ29uZmlnIHRoZSBjb25maWd1cmF0aW9uIGZvciB0aGUgY29udGVudEl0ZW0gdGhhdCB3aWxsIGJlIGNyZWF0ZWRcbiAqIEBwYXJhbSB7TGF5b3V0TWFuYWdlcn0gbGF5b3V0TWFuYWdlclxuICpcbiAqIEBjb25zdHJ1Y3RvclxuICovXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBEcmFnU291cmNlIHtcbiAgICBjb25zdHJ1Y3RvcihlbGVtZW50LCBpdGVtQ29uZmlnLCBsYXlvdXRNYW5hZ2VyKSB7XG4gICAgICAgIHRoaXMuX2VsZW1lbnQgPSBlbGVtZW50O1xuICAgICAgICB0aGlzLl9pdGVtQ29uZmlnID0gaXRlbUNvbmZpZztcbiAgICAgICAgdGhpcy5fbGF5b3V0TWFuYWdlciA9IGxheW91dE1hbmFnZXI7XG4gICAgICAgIHRoaXMuX2RyYWdMaXN0ZW5lciA9IG51bGw7XG5cbiAgICAgICAgdGhpcy5fY3JlYXRlRHJhZ0xpc3RlbmVyKCk7XG4gICAgfVxuXG5cdC8qKlxuXHQgKiBEaXNwb3NlcyBvZiB0aGUgZHJhZyBsaXN0ZW5lcnMgc28gdGhlIGRyYWcgc291cmNlIGlzIG5vdCB1c2FibGUgYW55IG1vcmUuXG5cdCAqXG5cdCAqIEByZXR1cm5zIHt2b2lkfVxuXHQgKi9cblx0ZGVzdHJveSgpIHtcblx0XHR0aGlzLl9yZW1vdmVEcmFnTGlzdGVuZXIoKTtcbiAgICB9XG4gICAgXG4gICAgLyoqXG4gICAgICogQ2FsbGVkIGluaXRpYWxseSBhbmQgYWZ0ZXIgZXZlcnkgZHJhZ1xuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX2NyZWF0ZURyYWdMaXN0ZW5lcigpIHtcbiAgICAgICAgdGhpcy5fcmVtb3ZlRHJhZ0xpc3RlbmVyKCk7XG5cbiAgICAgICAgdGhpcy5fZHJhZ0xpc3RlbmVyID0gbmV3IERyYWdMaXN0ZW5lcih0aGlzLl9lbGVtZW50KTtcbiAgICAgICAgdGhpcy5fZHJhZ0xpc3RlbmVyLm9uKCdkcmFnU3RhcnQnLCB0aGlzLl9vbkRyYWdTdGFydCwgdGhpcyk7XG4gICAgICAgIHRoaXMuX2RyYWdMaXN0ZW5lci5vbignZHJhZ1N0b3AnLCB0aGlzLl9jcmVhdGVEcmFnTGlzdGVuZXIsIHRoaXMpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxiYWNrIGZvciB0aGUgRHJhZ0xpc3RlbmVyJ3MgZHJhZ1N0YXJ0IGV2ZW50XG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7aW50fSB4IHRoZSB4IHBvc2l0aW9uIG9mIHRoZSBtb3VzZSBvbiBkcmFnU3RhcnRcbiAgICAgKiBAcGFyYW0gICB7aW50fSB5IHRoZSB4IHBvc2l0aW9uIG9mIHRoZSBtb3VzZSBvbiBkcmFnU3RhcnRcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vbkRyYWdTdGFydCh4LCB5KSB7XG4gICAgICAgIHZhciBpdGVtQ29uZmlnID0gdGhpcy5faXRlbUNvbmZpZztcbiAgICAgICAgaWYgKGlzRnVuY3Rpb24oaXRlbUNvbmZpZykpIHtcbiAgICAgICAgICAgIGl0ZW1Db25maWcgPSBpdGVtQ29uZmlnKCk7XG4gICAgICAgIH1cbiAgICAgICAgdmFyIGNvbnRlbnRJdGVtID0gdGhpcy5fbGF5b3V0TWFuYWdlci5fJG5vcm1hbGl6ZUNvbnRlbnRJdGVtKCQuZXh0ZW5kKHRydWUsIHt9LCBpdGVtQ29uZmlnKSksXG4gICAgICAgICAgICBkcmFnUHJveHkgPSBuZXcgRHJhZ1Byb3h5KHgsIHksIHRoaXMuX2RyYWdMaXN0ZW5lciwgdGhpcy5fbGF5b3V0TWFuYWdlciwgY29udGVudEl0ZW0sIG51bGwpO1xuXG4gICAgICAgIHRoaXMuX2xheW91dE1hbmFnZXIudHJhbnNpdGlvbkluZGljYXRvci50cmFuc2l0aW9uRWxlbWVudHModGhpcy5fZWxlbWVudCwgZHJhZ1Byb3h5LmVsZW1lbnQpO1xuICAgIH1cblxuICAgIC8qKlxuXHQgKiBDYWxsZWQgYWZ0ZXIgZXZlcnkgZHJhZyBhbmQgd2hlbiB0aGUgZHJhZyBzb3VyY2UgaXMgYmVpbmcgZGlzcG9zZWQgb2YuXG5cdCAqXG5cdCAqIEByZXR1cm5zIHt2b2lkfVxuXHQgKi9cblx0X3JlbW92ZURyYWdMaXN0ZW5lcigpIHtcblx0XHRpZiggdGhpcy5fZHJhZ0xpc3RlbmVyICE9PSBudWxsICkge1xuXHRcdFx0dGhpcy5fZHJhZ0xpc3RlbmVyLmRlc3Ryb3koKTtcblx0XHR9XG5cdH1cbn1cbiIsImltcG9ydCAkIGZyb20gJ2pxdWVyeSdcblxuY29uc3QgX3RlbXBsYXRlID0gJzxkaXYgY2xhc3M9XCJsbV9kcm9wVGFyZ2V0SW5kaWNhdG9yXCI+PGRpdiBjbGFzcz1cImxtX2lubmVyXCI+PC9kaXY+PC9kaXY+J1xuXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIERyb3BUYXJnZXRJbmRpY2F0b3Ige1xuXG4gICAgY29uc3RydWN0b3IoKSB7XG4gICAgICAgIHRoaXMuZWxlbWVudCA9ICQoX3RlbXBsYXRlKTtcbiAgICAgICAgJChkb2N1bWVudC5ib2R5KS5hcHBlbmQodGhpcy5lbGVtZW50KTtcbiAgICB9XG5cbiAgICBkZXN0cm95KCkge1xuICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlKCk7XG4gICAgfVxuXG4gICAgaGlnaGxpZ2h0KHgxLCB5MSwgeDIsIHkyKSB7XG4gICAgICAgIHRoaXMuaGlnaGxpZ2h0QXJlYSh7XG4gICAgICAgICAgICB4MTogeDEsXG4gICAgICAgICAgICB5MTogeTEsXG4gICAgICAgICAgICB4MjogeDIsXG4gICAgICAgICAgICB5MjogeTJcbiAgICAgICAgfSk7XG4gICAgfVxuXG4gICAgaGlnaGxpZ2h0QXJlYShhcmVhKSB7XG4gICAgICAgIHRoaXMuZWxlbWVudC5jc3Moe1xuICAgICAgICAgICAgbGVmdDogYXJlYS54MSxcbiAgICAgICAgICAgIHRvcDogYXJlYS55MSxcbiAgICAgICAgICAgIHdpZHRoOiBhcmVhLngyIC0gYXJlYS54MSxcbiAgICAgICAgICAgIGhlaWdodDogYXJlYS55MiAtIGFyZWEueTFcbiAgICAgICAgfSkuc2hvdygpO1xuICAgIH1cblxuICAgIGhpZGUoKSB7XG4gICAgICAgIHRoaXMuZWxlbWVudC5oaWRlKCk7XG4gICAgfVxufVxuIiwiaW1wb3J0IEV2ZW50RW1pdHRlciBmcm9tICcuLi91dGlscy9FdmVudEVtaXR0ZXInXG5pbXBvcnQgVGFiIGZyb20gJy4uL2NvbnRyb2xzL1RhYidcbmltcG9ydCBIZWFkZXJCdXR0b24gZnJvbSAnLi4vY29udHJvbHMvSGVhZGVyQnV0dG9uJ1xuaW1wb3J0IHtcbiAgICBmbkJpbmRcbn0gZnJvbSAnLi4vdXRpbHMvdXRpbHMnO1xuaW1wb3J0ICQgZnJvbSAnanF1ZXJ5JztcblxuY29uc3QgX3RlbXBsYXRlID0gW1xuICAgICAgICAnPGRpdiBjbGFzcz1cImxtX2hlYWRlclwiPicsXG4gICAgICAgICc8dWwgY2xhc3M9XCJsbV90YWJzXCI+PC91bD4nLFxuICAgICAgICAnPHVsIGNsYXNzPVwibG1fY29udHJvbHNcIj48L3VsPicsXG4gICAgICAgICc8dWwgY2xhc3M9XCJsbV90YWJkcm9wZG93bl9saXN0XCI+PC91bD4nLFxuICAgICAgICAnPC9kaXY+J1xuICAgIF0uam9pbignJyk7XG5cbi8qKlxuICogVGhpcyBjbGFzcyByZXByZXNlbnRzIGEgaGVhZGVyIGFib3ZlIGEgU3RhY2sgQ29udGVudEl0ZW0uXG4gKlxuICogQHBhcmFtIHtsbS5MYXlvdXRNYW5hZ2VyfSBsYXlvdXRNYW5hZ2VyXG4gKiBAcGFyYW0ge0Fic3RyYWN0Q29udGVudEl0ZW19IHBhcmVudFxuICovXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBIZWFkZXIgZXh0ZW5kcyBFdmVudEVtaXR0ZXIge1xuXG4gICAgY29uc3RydWN0b3IobGF5b3V0TWFuYWdlciwgcGFyZW50KSB7XG5cbiAgICAgICAgc3VwZXIoKTtcbiAgICAgICAgXG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlciA9IGxheW91dE1hbmFnZXI7XG4gICAgICAgIHRoaXMuZWxlbWVudCA9ICQoX3RlbXBsYXRlKTtcblxuICAgICAgICBpZiAodGhpcy5sYXlvdXRNYW5hZ2VyLmNvbmZpZy5zZXR0aW5ncy5zZWxlY3Rpb25FbmFibGVkID09PSB0cnVlKSB7XG4gICAgICAgICAgICB0aGlzLmVsZW1lbnQuYWRkQ2xhc3MoJ2xtX3NlbGVjdGFibGUnKTtcbiAgICAgICAgICAgIHRoaXMuZWxlbWVudC5vbignY2xpY2sgdG91Y2hzdGFydCcsIGZuQmluZCh0aGlzLl9vbkhlYWRlckNsaWNrLCB0aGlzKSk7XG4gICAgICAgIH1cblxuICAgICAgICB0aGlzLnRhYnNDb250YWluZXIgPSB0aGlzLmVsZW1lbnQuZmluZCgnLmxtX3RhYnMnKTtcbiAgICAgICAgdGhpcy50YWJEcm9wZG93bkNvbnRhaW5lciA9IHRoaXMuZWxlbWVudC5maW5kKCcubG1fdGFiZHJvcGRvd25fbGlzdCcpO1xuICAgICAgICB0aGlzLnRhYkRyb3Bkb3duQ29udGFpbmVyLmhpZGUoKTtcbiAgICAgICAgdGhpcy5jb250cm9sc0NvbnRhaW5lciA9IHRoaXMuZWxlbWVudC5maW5kKCcubG1fY29udHJvbHMnKTtcbiAgICAgICAgdGhpcy5wYXJlbnQgPSBwYXJlbnQ7XG4gICAgICAgIHRoaXMucGFyZW50Lm9uKCdyZXNpemUnLCB0aGlzLl91cGRhdGVUYWJTaXplcywgdGhpcyk7XG4gICAgICAgIHRoaXMudGFicyA9IFtdO1xuICAgICAgICB0aGlzLnRhYnNNYXJrZWRGb3JSZW1vdmFsID0gW107XG4gICAgICAgIHRoaXMuYWN0aXZlQ29udGVudEl0ZW0gPSBudWxsO1xuICAgICAgICB0aGlzLmNsb3NlQnV0dG9uID0gbnVsbDtcbiAgICAgICAgdGhpcy5kb2NrQnV0dG9uID0gbnVsbDtcbiAgICAgICAgdGhpcy50YWJEcm9wZG93bkJ1dHRvbiA9IG51bGw7XG4gICAgICAgIHRoaXMuaGlkZUFkZGl0aW9uYWxUYWJzRHJvcGRvd24gPSBmbkJpbmQodGhpcy5faGlkZUFkZGl0aW9uYWxUYWJzRHJvcGRvd24sIHRoaXMpO1xuICAgICAgICAkKGRvY3VtZW50KS5tb3VzZXVwKHRoaXMuaGlkZUFkZGl0aW9uYWxUYWJzRHJvcGRvd24pO1xuXG4gICAgICAgIHRoaXMuX2xhc3RWaXNpYmxlVGFiSW5kZXggPSAtMTtcbiAgICAgICAgdGhpcy5fdGFiQ29udHJvbE9mZnNldCA9IHRoaXMubGF5b3V0TWFuYWdlci5jb25maWcuc2V0dGluZ3MudGFiQ29udHJvbE9mZnNldDtcbiAgICAgICAgdGhpcy5fY3JlYXRlQ29udHJvbHMoKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDcmVhdGVzIGEgbmV3IHRhYiBhbmQgYXNzb2NpYXRlcyBpdCB3aXRoIGEgY29udGVudEl0ZW1cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgICB7QWJzdHJhY3RDb250ZW50SXRlbX0gY29udGVudEl0ZW1cbiAgICAgKiBAcGFyYW0gICAge0ludGVnZXJ9IGluZGV4IFRoZSBwb3NpdGlvbiBvZiB0aGUgdGFiXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBjcmVhdGVUYWIoY29udGVudEl0ZW0sIGluZGV4KSB7XG4gICAgICAgIHZhciB0YWIsIGk7XG5cbiAgICAgICAgLy9JZiB0aGVyZSdzIGFscmVhZHkgYSB0YWIgcmVsYXRpbmcgdG8gdGhlXG4gICAgICAgIC8vY29udGVudCBpdGVtLCBkb24ndCBkbyBhbnl0aGluZ1xuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy50YWJzLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBpZiAodGhpcy50YWJzW2ldLmNvbnRlbnRJdGVtID09PSBjb250ZW50SXRlbSkge1xuICAgICAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgIHRhYiA9IG5ldyBUYWIodGhpcywgY29udGVudEl0ZW0pO1xuXG4gICAgICAgIGlmICh0aGlzLnRhYnMubGVuZ3RoID09PSAwKSB7XG4gICAgICAgICAgICB0aGlzLnRhYnMucHVzaCh0YWIpO1xuICAgICAgICAgICAgdGhpcy50YWJzQ29udGFpbmVyLmFwcGVuZCh0YWIuZWxlbWVudCk7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoaW5kZXggPT09IHVuZGVmaW5lZCkge1xuICAgICAgICAgICAgaW5kZXggPSB0aGlzLnRhYnMubGVuZ3RoO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKGluZGV4ID4gMCkge1xuICAgICAgICAgICAgdGhpcy50YWJzW2luZGV4IC0gMV0uZWxlbWVudC5hZnRlcih0YWIuZWxlbWVudCk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICB0aGlzLnRhYnNbMF0uZWxlbWVudC5iZWZvcmUodGFiLmVsZW1lbnQpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy50YWJzLnNwbGljZShpbmRleCwgMCwgdGFiKTtcbiAgICAgICAgdGhpcy5fdXBkYXRlVGFiU2l6ZXMoKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBGaW5kcyBhIHRhYiBiYXNlZCBvbiB0aGUgY29udGVudEl0ZW0gaXRzIGFzc29jaWF0ZWQgd2l0aCBhbmQgcmVtb3ZlcyBpdC5cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgICB7QWJzdHJhY3RDb250ZW50SXRlbX0gY29udGVudEl0ZW1cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIHJlbW92ZVRhYihjb250ZW50SXRlbSkge1xuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoaXMudGFicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMudGFic1tpXS5jb250ZW50SXRlbSA9PT0gY29udGVudEl0ZW0pIHtcbiAgICAgICAgICAgICAgICB0aGlzLnRhYnNbaV0uXyRkZXN0cm95KCk7XG4gICAgICAgICAgICAgICAgdGhpcy50YWJzLnNwbGljZShpLCAxKTtcbiAgICAgICAgICAgICAgICByZXR1cm47XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy50YWJzTWFya2VkRm9yUmVtb3ZhbC5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMudGFic01hcmtlZEZvclJlbW92YWxbaV0uY29udGVudEl0ZW0gPT09IGNvbnRlbnRJdGVtKSB7XG4gICAgICAgICAgICAgICAgdGhpcy50YWJzTWFya2VkRm9yUmVtb3ZhbFtpXS5fJGRlc3Ryb3koKTtcbiAgICAgICAgICAgICAgICB0aGlzLnRhYnNNYXJrZWRGb3JSZW1vdmFsLnNwbGljZShpLCAxKTtcbiAgICAgICAgICAgICAgICByZXR1cm47XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuXG4gICAgICAgIHRocm93IG5ldyBFcnJvcignY29udGVudEl0ZW0gaXMgbm90IGNvbnRyb2xsZWQgYnkgdGhpcyBoZWFkZXInKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBGaW5kcyBhIHRhYiBiYXNlZCBvbiB0aGUgY29udGVudEl0ZW0gaXRzIGFzc29jaWF0ZWQgd2l0aCBhbmQgbWFya3MgaXRcbiAgICAgKiBmb3IgcmVtb3ZhbCwgaGlkaW5nIGl0IHRvby5cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgICB7QWJzdHJhY3RDb250ZW50SXRlbX0gY29udGVudEl0ZW1cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGhpZGVUYWIoY29udGVudEl0ZW0pe1xuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoaXMudGFicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMudGFic1tpXS5jb250ZW50SXRlbSA9PT0gY29udGVudEl0ZW0pIHtcbiAgICAgICAgICAgICAgICB0aGlzLnRhYnNbaV0uZWxlbWVudC5oaWRlKClcbiAgICAgICAgICAgICAgICB0aGlzLnRhYnNNYXJrZWRGb3JSZW1vdmFsLnB1c2godGhpcy50YWJzW2ldKVxuICAgICAgICAgICAgICAgIHRoaXMudGFicy5zcGxpY2UoaSwgMSk7XG4gICAgICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICAgICAgfVxuICAgICAgICB9ICAgICAgICBcblxuICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ2NvbnRlbnRJdGVtIGlzIG5vdCBjb250cm9sbGVkIGJ5IHRoaXMgaGVhZGVyJyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVGhlIHByb2dyYW1tYXRpY2FsIGVxdWl2YWxlbnQgb2YgY2xpY2tpbmcgYSBUYWIuXG4gICAgICpcbiAgICAgKiBAcGFyYW0ge0Fic3RyYWN0Q29udGVudEl0ZW19IGNvbnRlbnRJdGVtXG4gICAgICovXG4gICAgc2V0QWN0aXZlQ29udGVudEl0ZW0oY29udGVudEl0ZW0pIHtcbiAgICAgICAgdmFyIGksIGosIGlzQWN0aXZlLCBhY3RpdmVUYWI7XG5cbiAgICAgICAgaWYgKHRoaXMuYWN0aXZlQ29udGVudEl0ZW0gPT09IGNvbnRlbnRJdGVtKSByZXR1cm47XG5cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHRoaXMudGFicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaXNBY3RpdmUgPSB0aGlzLnRhYnNbaV0uY29udGVudEl0ZW0gPT09IGNvbnRlbnRJdGVtO1xuICAgICAgICAgICAgdGhpcy50YWJzW2ldLnNldEFjdGl2ZShpc0FjdGl2ZSk7XG4gICAgICAgICAgICBpZiAoaXNBY3RpdmUgPT09IHRydWUpIHtcbiAgICAgICAgICAgICAgICB0aGlzLmFjdGl2ZUNvbnRlbnRJdGVtID0gY29udGVudEl0ZW07XG4gICAgICAgICAgICAgICAgdGhpcy5wYXJlbnQuY29uZmlnLmFjdGl2ZUl0ZW1JbmRleCA9IGk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICBpZiAodGhpcy5sYXlvdXRNYW5hZ2VyLmNvbmZpZy5zZXR0aW5ncy5yZW9yZGVyT25UYWJNZW51Q2xpY2spIHtcbiAgICAgICAgICAgIC8qKlxuICAgICAgICAgICAgICogSWYgdGhlIHRhYiBzZWxlY3RlZCB3YXMgaW4gdGhlIGRyb3Bkb3duLCBtb3ZlIGV2ZXJ5dGhpbmcgZG93biBvbmUgdG8gbWFrZSB3YXkgZm9yIHRoaXMgb25lIHRvIGJlIHRoZSBmaXJzdC5cbiAgICAgICAgICAgICAqIFRoaXMgd2lsbCBtYWtlIHN1cmUgdGhlIG1vc3QgdXNlZCB0YWJzIHN0YXkgdmlzaWJsZS5cbiAgICAgICAgICAgICAqL1xuICAgICAgICAgICAgaWYgKHRoaXMuX2xhc3RWaXNpYmxlVGFiSW5kZXggIT09IC0xICYmIHRoaXMucGFyZW50LmNvbmZpZy5hY3RpdmVJdGVtSW5kZXggPiB0aGlzLl9sYXN0VmlzaWJsZVRhYkluZGV4KSB7XG4gICAgICAgICAgICAgICAgYWN0aXZlVGFiID0gdGhpcy50YWJzW3RoaXMucGFyZW50LmNvbmZpZy5hY3RpdmVJdGVtSW5kZXhdO1xuICAgICAgICAgICAgICAgIGZvciAoaiA9IHRoaXMucGFyZW50LmNvbmZpZy5hY3RpdmVJdGVtSW5kZXg7IGogPiAwOyBqLS0pIHtcbiAgICAgICAgICAgICAgICAgICAgdGhpcy50YWJzW2pdID0gdGhpcy50YWJzW2ogLSAxXTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgdGhpcy50YWJzWzBdID0gYWN0aXZlVGFiO1xuICAgICAgICAgICAgICAgIHRoaXMucGFyZW50LmNvbmZpZy5hY3RpdmVJdGVtSW5kZXggPSAwO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fdXBkYXRlVGFiU2l6ZXMoKTtcbiAgICAgICAgdGhpcy5wYXJlbnQuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFByb2dyYW1tYXRpY2FsbHkgb3BlcmF0ZSB3aXRoIGhlYWRlciBwb3NpdGlvbi5cbiAgICAgKlxuICAgICAqIEBwYXJhbSB7c3RyaW5nfSBwb3NpdGlvbiBvbmUgb2YgKCd0b3AnLCdsZWZ0JywncmlnaHQnLCdib3R0b20nKSB0byBzZXQgb3IgZW1wdHkgdG8gZ2V0IGl0LlxuICAgICAqXG4gICAgICogQHJldHVybnMge3N0cmluZ30gcHJldmlvdXMgaGVhZGVyIHBvc2l0aW9uXG4gICAgICovXG4gICAgcG9zaXRpb24ocG9zaXRpb24pIHtcbiAgICAgICAgdmFyIHByZXZpb3VzID0gdGhpcy5wYXJlbnQuX2hlYWRlci5zaG93O1xuICAgICAgICBpZiAodGhpcy5wYXJlbnQuX2RvY2tlciAmJiB0aGlzLnBhcmVudC5fZG9ja2VyLmRvY2tlZClcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ2FuXFwndCBjaGFuZ2UgaGVhZGVyIHBvc2l0aW9uIGluIGRvY2tlZCBzdGFjaycpO1xuICAgICAgICBpZiAocHJldmlvdXMgJiYgIXRoaXMucGFyZW50Ll9zaWRlKVxuICAgICAgICAgICAgcHJldmlvdXMgPSAndG9wJztcbiAgICAgICAgaWYgKHBvc2l0aW9uICE9PSB1bmRlZmluZWQgJiYgdGhpcy5wYXJlbnQuX2hlYWRlci5zaG93ICE9IHBvc2l0aW9uKSB7XG4gICAgICAgICAgICB0aGlzLnBhcmVudC5faGVhZGVyLnNob3cgPSBwb3NpdGlvbjtcbiAgICAgICAgICAgIHRoaXMucGFyZW50LmNvbmZpZy5oZWFkZXIgPyB0aGlzLnBhcmVudC5jb25maWcuaGVhZGVyLnNob3cgPSBwb3NpdGlvbiA6IHRoaXMucGFyZW50LmNvbmZpZy5oZWFkZXIgPSB7IHNob3c6IHBvc2l0aW9uIH07XG4gICAgICAgICAgICB0aGlzLnBhcmVudC5fc2V0dXBIZWFkZXJQb3NpdGlvbigpO1xuICAgICAgICB9XG4gICAgICAgIHJldHVybiBwcmV2aW91cztcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBQcm9ncmFtbWF0aWNhbGx5IHNldCBjbG9zYWJpbGl0eS5cbiAgICAgKlxuICAgICAqIEBwYWNrYWdlIHByaXZhdGVcbiAgICAgKiBAcGFyYW0ge0Jvb2xlYW59IGlzQ2xvc2FibGUgV2hldGhlciB0byBlbmFibGUvZGlzYWJsZSBjbG9zYWJpbGl0eS5cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtCb29sZWFufSBXaGV0aGVyIHRoZSBhY3Rpb24gd2FzIHN1Y2Nlc3NmdWxcbiAgICAgKi9cbiAgICBfJHNldENsb3NhYmxlKGlzQ2xvc2FibGUpIHtcbiAgICAgICAgdGhpcy5fY2FuRGVzdHJveSA9IGlzQ2xvc2FibGUgfHwgdGhpcy50YWJzLmxlbmd0aCA+IDE7XG4gICAgICAgIGlmICh0aGlzLmNsb3NlQnV0dG9uICYmIHRoaXMuX2lzQ2xvc2FibGUoKSkge1xuICAgICAgICAgICAgdGhpcy5jbG9zZUJ1dHRvbi5lbGVtZW50W2lzQ2xvc2FibGUgPyBcInNob3dcIiA6IFwiaGlkZVwiXSgpO1xuICAgICAgICAgICAgcmV0dXJuIHRydWU7XG4gICAgICAgIH1cblxuICAgICAgICByZXR1cm4gZmFsc2U7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogUHJvZ3JhbW1hdGljYWxseSBzZXQgYWJpbGl0eSB0byBkb2NrLlxuICAgICAqXG4gICAgICogQHBhY2thZ2UgcHJpdmF0ZVxuICAgICAqIEBwYXJhbSB7Qm9vbGVhbn0gaXNEb2NrYWJsZSBXaGV0aGVyIHRvIGVuYWJsZS9kaXNhYmxlIGFiaWxpdHkgdG8gZG9jay5cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtCb29sZWFufSBXaGV0aGVyIHRoZSBhY3Rpb24gd2FzIHN1Y2Nlc3NmdWxcbiAgICAgKi9cbiAgICBfc2V0RG9ja2FibGUoaXNEb2NrYWJsZSkge1xuICAgICAgICBpZiAodGhpcy5kb2NrQnV0dG9uICYmIHRoaXMucGFyZW50Ll9oZWFkZXIgJiYgdGhpcy5wYXJlbnQuX2hlYWRlci5kb2NrKSB7XG4gICAgICAgICAgICB0aGlzLmRvY2tCdXR0b24uZWxlbWVudC50b2dnbGUoISFpc0RvY2thYmxlKTtcbiAgICAgICAgICAgIHJldHVybiB0cnVlO1xuICAgICAgICB9XG4gICAgICAgIHJldHVybiBmYWxzZTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBEZXN0cm95cyB0aGUgZW50aXJlIGhlYWRlclxuICAgICAqXG4gICAgICogQHBhY2thZ2UgcHJpdmF0ZVxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgXyRkZXN0cm95KCkge1xuICAgICAgICB0aGlzLmVtaXQoJ2Rlc3Ryb3knLCB0aGlzKTtcblxuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoaXMudGFicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgdGhpcy50YWJzW2ldLl8kZGVzdHJveSgpO1xuICAgICAgICB9XG4gICAgICAgICQoZG9jdW1lbnQpLm9mZignbW91c2V1cCcsIHRoaXMuaGlkZUFkZGl0aW9uYWxUYWJzRHJvcGRvd24pO1xuICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlKCk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogZ2V0IHNldHRpbmdzIGZyb20gaGVhZGVyXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7c3RyaW5nfSB3aGVuIGV4aXN0c1xuICAgICAqL1xuICAgIF9nZXRIZWFkZXJTZXR0aW5nKG5hbWUpIHtcbiAgICAgICAgaWYgKG5hbWUgaW4gdGhpcy5wYXJlbnQuX2hlYWRlcilcbiAgICAgICAgICAgIHJldHVybiB0aGlzLnBhcmVudC5faGVhZGVyW25hbWVdO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENyZWF0ZXMgdGhlIHBvcG91dCwgbWF4aW1pc2UgYW5kIGNsb3NlIGJ1dHRvbnMgaW4gdGhlIGhlYWRlcidzIHRvcCByaWdodCBjb3JuZXJcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9jcmVhdGVDb250cm9scygpIHtcbiAgICAgICAgdmFyIGNsb3NlU3RhY2ssXG4gICAgICAgICAgICBwb3BvdXQsXG4gICAgICAgICAgICBsYWJlbCxcbiAgICAgICAgICAgIG1heGltaXNlTGFiZWwsXG4gICAgICAgICAgICBtaW5pbWlzZUxhYmVsLFxuICAgICAgICAgICAgbWF4aW1pc2UsXG4gICAgICAgICAgICBtYXhpbWlzZUJ1dHRvbixcbiAgICAgICAgICAgIHRhYkRyb3Bkb3duTGFiZWwsXG4gICAgICAgICAgICBzaG93VGFiRHJvcGRvd247XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIERyb3Bkb3duIHRvIHNob3cgYWRkaXRpb25hbCB0YWJzLlxuICAgICAgICAgKi9cbiAgICAgICAgc2hvd1RhYkRyb3Bkb3duID0gZm5CaW5kKHRoaXMuX3Nob3dBZGRpdGlvbmFsVGFic0Ryb3Bkb3duLCB0aGlzKTtcbiAgICAgICAgdGFiRHJvcGRvd25MYWJlbCA9IHRoaXMubGF5b3V0TWFuYWdlci5jb25maWcubGFiZWxzLnRhYkRyb3Bkb3duO1xuICAgICAgICB0aGlzLnRhYkRyb3Bkb3duQnV0dG9uID0gbmV3IEhlYWRlckJ1dHRvbih0aGlzLCB0YWJEcm9wZG93bkxhYmVsLCAnbG1fdGFiZHJvcGRvd24nLCBzaG93VGFiRHJvcGRvd24pO1xuICAgICAgICB0aGlzLnRhYkRyb3Bkb3duQnV0dG9uLmVsZW1lbnQuaGlkZSgpO1xuXG4gICAgICAgIGlmICh0aGlzLnBhcmVudC5faGVhZGVyICYmIHRoaXMucGFyZW50Ll9oZWFkZXIuZG9jaykge1xuICAgICAgICAgICAgdmFyIGJ1dHRvbiA9IGZuQmluZCh0aGlzLnBhcmVudC5kb2NrLCB0aGlzLnBhcmVudCk7XG4gICAgICAgICAgICBsYWJlbCA9IHRoaXMuX2dldEhlYWRlclNldHRpbmcoJ2RvY2snKTtcbiAgICAgICAgICAgIHRoaXMuZG9ja0J1dHRvbiA9IG5ldyBIZWFkZXJCdXR0b24odGhpcywgbGFiZWwsICdsbV9kb2NrJywgYnV0dG9uKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBQb3BvdXQgY29udHJvbCB0byBsYXVuY2ggY29tcG9uZW50IGluIG5ldyB3aW5kb3cuXG4gICAgICAgICAqL1xuICAgICAgICBpZiAodGhpcy5fZ2V0SGVhZGVyU2V0dGluZygncG9wb3V0JykpIHtcbiAgICAgICAgICAgIHBvcG91dCA9IGZuQmluZCh0aGlzLl9vblBvcG91dENsaWNrLCB0aGlzKTtcbiAgICAgICAgICAgIGxhYmVsID0gdGhpcy5fZ2V0SGVhZGVyU2V0dGluZygncG9wb3V0Jyk7XG4gICAgICAgICAgICBuZXcgSGVhZGVyQnV0dG9uKHRoaXMsIGxhYmVsLCAnbG1fcG9wb3V0JywgcG9wb3V0KTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBNYXhpbWlzZSBjb250cm9sIC0gc2V0IHRoZSBjb21wb25lbnQgdG8gdGhlIGZ1bGwgc2l6ZSBvZiB0aGUgbGF5b3V0XG4gICAgICAgICAqL1xuICAgICAgICBpZiAodGhpcy5fZ2V0SGVhZGVyU2V0dGluZygnbWF4aW1pc2UnKSkge1xuICAgICAgICAgICAgbWF4aW1pc2UgPSBmbkJpbmQodGhpcy5wYXJlbnQudG9nZ2xlTWF4aW1pc2UsIHRoaXMucGFyZW50KTtcbiAgICAgICAgICAgIG1heGltaXNlTGFiZWwgPSB0aGlzLl9nZXRIZWFkZXJTZXR0aW5nKCdtYXhpbWlzZScpO1xuICAgICAgICAgICAgbWluaW1pc2VMYWJlbCA9IHRoaXMuX2dldEhlYWRlclNldHRpbmcoJ21pbmltaXNlJyk7XG4gICAgICAgICAgICBtYXhpbWlzZUJ1dHRvbiA9IG5ldyBIZWFkZXJCdXR0b24odGhpcywgbWF4aW1pc2VMYWJlbCwgJ2xtX21heGltaXNlJywgbWF4aW1pc2UpO1xuXG4gICAgICAgICAgICB0aGlzLnBhcmVudC5vbignbWF4aW1pc2VkJywgZnVuY3Rpb24oKSB7XG4gICAgICAgICAgICAgICAgbWF4aW1pc2VCdXR0b24uZWxlbWVudC5hdHRyKCd0aXRsZScsIG1pbmltaXNlTGFiZWwpO1xuICAgICAgICAgICAgfSk7XG5cbiAgICAgICAgICAgIHRoaXMucGFyZW50Lm9uKCdtaW5pbWlzZWQnLCBmdW5jdGlvbigpIHtcbiAgICAgICAgICAgICAgICBtYXhpbWlzZUJ1dHRvbi5lbGVtZW50LmF0dHIoJ3RpdGxlJywgbWF4aW1pc2VMYWJlbCk7XG4gICAgICAgICAgICB9KTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBDbG9zZSBidXR0b25cbiAgICAgICAgICovXG4gICAgICAgIGlmICh0aGlzLl9pc0Nsb3NhYmxlKCkpIHtcbiAgICAgICAgICAgIGNsb3NlU3RhY2sgPSBmbkJpbmQodGhpcy5wYXJlbnQucmVtb3ZlLCB0aGlzLnBhcmVudCk7XG4gICAgICAgICAgICBsYWJlbCA9IHRoaXMuX2dldEhlYWRlclNldHRpbmcoJ2Nsb3NlJyk7XG4gICAgICAgICAgICB0aGlzLmNsb3NlQnV0dG9uID0gbmV3IEhlYWRlckJ1dHRvbih0aGlzLCBsYWJlbCwgJ2xtX2Nsb3NlJywgY2xvc2VTdGFjayk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBTaG93cyBkcm9wIGRvd24gZm9yIGFkZGl0aW9uYWwgdGFicyB3aGVuIHRoZXJlIGFyZSB0b28gbWFueSB0byBkaXNwbGF5LlxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX3Nob3dBZGRpdGlvbmFsVGFic0Ryb3Bkb3duKCkge1xuICAgICAgICB0aGlzLnRhYkRyb3Bkb3duQ29udGFpbmVyLnNob3coKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBIaWRlcyBkcm9wIGRvd24gZm9yIGFkZGl0aW9uYWwgdGFicyB3aGVuIHRoZXJlIGFyZSB0b28gbWFueSB0byBkaXNwbGF5LlxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX2hpZGVBZGRpdGlvbmFsVGFic0Ryb3Bkb3duKGUpIHtcbiAgICAgICAgdGhpcy50YWJEcm9wZG93bkNvbnRhaW5lci5oaWRlKCk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ2hlY2tzIHdoZXRoZXIgdGhlIGhlYWRlciBpcyBjbG9zYWJsZSBiYXNlZCBvbiB0aGUgcGFyZW50IGNvbmZpZyBhbmRcbiAgICAgKiB0aGUgZ2xvYmFsIGNvbmZpZy5cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtCb29sZWFufSBXaGV0aGVyIHRoZSBoZWFkZXIgaXMgY2xvc2FibGUuXG4gICAgICovXG4gICAgX2lzQ2xvc2FibGUoKSB7XG4gICAgICAgIHJldHVybiB0aGlzLnBhcmVudC5jb25maWcuaXNDbG9zYWJsZSAmJiB0aGlzLmxheW91dE1hbmFnZXIuY29uZmlnLnNldHRpbmdzLnNob3dDbG9zZUljb247XG4gICAgfVxuXG4gICAgX29uUG9wb3V0Q2xpY2soKSB7XG4gICAgICAgIGlmICh0aGlzLmxheW91dE1hbmFnZXIuY29uZmlnLnNldHRpbmdzLnBvcG91dFdob2xlU3RhY2sgPT09IHRydWUpIHtcbiAgICAgICAgICAgIHRoaXMucGFyZW50LnBvcG91dCgpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgdGhpcy5hY3RpdmVDb250ZW50SXRlbS5wb3BvdXQoKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEludm9rZWQgd2hlbiB0aGUgaGVhZGVyJ3MgYmFja2dyb3VuZCBpcyBjbGlja2VkIChub3QgaXQncyB0YWJzIG9yIGNvbnRyb2xzKVxuICAgICAqXG4gICAgICogQHBhcmFtICAgIHtqUXVlcnkgRE9NIGV2ZW50fSBldmVudFxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX29uSGVhZGVyQ2xpY2soZXZlbnQpIHtcbiAgICAgICAgaWYgKGV2ZW50LnRhcmdldCA9PT0gdGhpcy5lbGVtZW50WzBdKSB7XG4gICAgICAgICAgICB0aGlzLnBhcmVudC5zZWxlY3QoKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFB1c2hlcyB0aGUgdGFicyB0byB0aGUgdGFiIGRyb3Bkb3duIGlmIHRoZSBhdmFpbGFibGUgc3BhY2UgaXMgbm90IHN1ZmZpY2llbnRcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF91cGRhdGVUYWJTaXplcyhzaG93VGFiTWVudSkge1xuICAgICAgICBpZiAodGhpcy50YWJzLmxlbmd0aCA9PT0gMCkge1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgLy9TaG93IHRoZSBtZW51IGJhc2VkIG9uIGZ1bmN0aW9uIGFyZ3VtZW50XG4gICAgICAgIHRoaXMudGFiRHJvcGRvd25CdXR0b24uZWxlbWVudC50b2dnbGUoc2hvd1RhYk1lbnUgPT09IHRydWUpO1xuXG4gICAgICAgIHZhciBzaXplID0gZnVuY3Rpb24odmFsKSB7XG4gICAgICAgICAgICByZXR1cm4gdmFsID8gJ3dpZHRoJyA6ICdoZWlnaHQnO1xuICAgICAgICB9O1xuICAgICAgICB0aGlzLmVsZW1lbnQuY3NzKHNpemUoIXRoaXMucGFyZW50Ll9zaWRlZCksICcnKTtcbiAgICAgICAgdGhpcy5lbGVtZW50W3NpemUodGhpcy5wYXJlbnQuX3NpZGVkKV0odGhpcy5sYXlvdXRNYW5hZ2VyLmNvbmZpZy5kaW1lbnNpb25zLmhlYWRlckhlaWdodCk7XG4gICAgICAgIHZhciBhdmFpbGFibGVXaWR0aCA9IHRoaXMuZWxlbWVudC5vdXRlcldpZHRoKCkgLSB0aGlzLmNvbnRyb2xzQ29udGFpbmVyLm91dGVyV2lkdGgoKSAtIHRoaXMuX3RhYkNvbnRyb2xPZmZzZXQsXG4gICAgICAgICAgICBjdW11bGF0aXZlVGFiV2lkdGggPSAwLFxuICAgICAgICAgICAgdmlzaWJsZVRhYldpZHRoID0gMCxcbiAgICAgICAgICAgIHRhYkVsZW1lbnQsXG4gICAgICAgICAgICBpLFxuICAgICAgICAgICAgaixcbiAgICAgICAgICAgIG1hcmdpbkxlZnQsXG4gICAgICAgICAgICBvdmVybGFwID0gMCxcbiAgICAgICAgICAgIHRhYldpZHRoLFxuICAgICAgICAgICAgdGFiT3ZlcmxhcEFsbG93YW5jZSA9IHRoaXMubGF5b3V0TWFuYWdlci5jb25maWcuc2V0dGluZ3MudGFiT3ZlcmxhcEFsbG93YW5jZSxcbiAgICAgICAgICAgIHRhYk92ZXJsYXBBbGxvd2FuY2VFeGNlZWRlZCA9IGZhbHNlLFxuICAgICAgICAgICAgYWN0aXZlSW5kZXggPSAodGhpcy5hY3RpdmVDb250ZW50SXRlbSA/IHRoaXMudGFicy5pbmRleE9mKHRoaXMuYWN0aXZlQ29udGVudEl0ZW0udGFiKSA6IDApLFxuICAgICAgICAgICAgYWN0aXZlVGFiID0gdGhpcy50YWJzW2FjdGl2ZUluZGV4XTtcbiAgICAgICAgaWYgKHRoaXMucGFyZW50Ll9zaWRlZClcbiAgICAgICAgICAgIGF2YWlsYWJsZVdpZHRoID0gdGhpcy5lbGVtZW50Lm91dGVySGVpZ2h0KCkgLSB0aGlzLmNvbnRyb2xzQ29udGFpbmVyLm91dGVySGVpZ2h0KCkgLSB0aGlzLl90YWJDb250cm9sT2Zmc2V0O1xuICAgICAgICB0aGlzLl9sYXN0VmlzaWJsZVRhYkluZGV4ID0gLTE7XG5cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHRoaXMudGFicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgdGFiRWxlbWVudCA9IHRoaXMudGFic1tpXS5lbGVtZW50O1xuXG4gICAgICAgICAgICAvL1B1dCB0aGUgdGFiIGluIHRoZSB0YWJDb250YWluZXIgc28gaXRzIHRydWUgd2lkdGggY2FuIGJlIGNoZWNrZWRcbiAgICAgICAgICAgIHRoaXMudGFic0NvbnRhaW5lci5hcHBlbmQodGFiRWxlbWVudCk7XG4gICAgICAgICAgICB0YWJXaWR0aCA9IHRhYkVsZW1lbnQub3V0ZXJXaWR0aCgpICsgcGFyc2VJbnQodGFiRWxlbWVudC5jc3MoJ21hcmdpbi1yaWdodCcpLCAxMCk7XG5cbiAgICAgICAgICAgIGN1bXVsYXRpdmVUYWJXaWR0aCArPSB0YWJXaWR0aDtcblxuICAgICAgICAgICAgLy9JbmNsdWRlIHRoZSBhY3RpdmUgdGFiJ3Mgd2lkdGggaWYgaXQgaXNuJ3QgYWxyZWFkeVxuICAgICAgICAgICAgLy9UaGlzIGlzIHRvIGVuc3VyZSB0aGVyZSBpcyByb29tIHRvIHNob3cgdGhlIGFjdGl2ZSB0YWJcbiAgICAgICAgICAgIGlmIChhY3RpdmVJbmRleCA8PSBpKSB7XG4gICAgICAgICAgICAgICAgdmlzaWJsZVRhYldpZHRoID0gY3VtdWxhdGl2ZVRhYldpZHRoO1xuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICB2aXNpYmxlVGFiV2lkdGggPSBjdW11bGF0aXZlVGFiV2lkdGggKyBhY3RpdmVUYWIuZWxlbWVudC5vdXRlcldpZHRoKCkgKyBwYXJzZUludChhY3RpdmVUYWIuZWxlbWVudC5jc3MoJ21hcmdpbi1yaWdodCcpLCAxMCk7XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIC8vIElmIHRoZSB0YWJzIHdvbid0IGZpdCwgY2hlY2sgdGhlIG92ZXJsYXAgYWxsb3dhbmNlLlxuICAgICAgICAgICAgaWYgKHZpc2libGVUYWJXaWR0aCA+IGF2YWlsYWJsZVdpZHRoKSB7XG5cbiAgICAgICAgICAgICAgICAvL09uY2UgYWxsb3dhbmNlIGlzIGV4Y2VlZGVkLCBhbGwgcmVtYWluaW5nIHRhYnMgZ28gdG8gbWVudS5cbiAgICAgICAgICAgICAgICBpZiAoIXRhYk92ZXJsYXBBbGxvd2FuY2VFeGNlZWRlZCkge1xuXG4gICAgICAgICAgICAgICAgICAgIC8vTm8gb3ZlcmxhcCBmb3IgZmlyc3QgdGFiIG9yIGFjdGl2ZSB0YWJcbiAgICAgICAgICAgICAgICAgICAgLy9PdmVybGFwIHNwcmVhZHMgYW1vbmcgbm9uLWFjdGl2ZSwgbm9uLWZpcnN0IHRhYnNcbiAgICAgICAgICAgICAgICAgICAgaWYgKGFjdGl2ZUluZGV4ID4gMCAmJiBhY3RpdmVJbmRleCA8PSBpKSB7XG4gICAgICAgICAgICAgICAgICAgICAgICBvdmVybGFwID0gKHZpc2libGVUYWJXaWR0aCAtIGF2YWlsYWJsZVdpZHRoKSAvIChpIC0gMSk7XG4gICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgICAgICBvdmVybGFwID0gKHZpc2libGVUYWJXaWR0aCAtIGF2YWlsYWJsZVdpZHRoKSAvIGk7XG4gICAgICAgICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgICAgICAgICAvL0NoZWNrIG92ZXJsYXAgYWdhaW5zdCBhbGxvd2FuY2UuXG4gICAgICAgICAgICAgICAgICAgIGlmIChvdmVybGFwIDwgdGFiT3ZlcmxhcEFsbG93YW5jZSkge1xuICAgICAgICAgICAgICAgICAgICAgICAgZm9yIChqID0gMDsgaiA8PSBpOyBqKyspIHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBtYXJnaW5MZWZ0ID0gKGogIT09IGFjdGl2ZUluZGV4ICYmIGogIT09IDApID8gJy0nICsgb3ZlcmxhcCArICdweCcgOiAnJztcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICB0aGlzLnRhYnNbal0uZWxlbWVudC5jc3Moe1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAnei1pbmRleCc6IGkgLSBqLFxuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAnbWFyZ2luLWxlZnQnOiBtYXJnaW5MZWZ0XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICAgICAgICAgICAgICB0aGlzLl9sYXN0VmlzaWJsZVRhYkluZGV4ID0gaTtcbiAgICAgICAgICAgICAgICAgICAgICAgIHRoaXMudGFic0NvbnRhaW5lci5hcHBlbmQodGFiRWxlbWVudCk7XG4gICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgICAgICB0YWJPdmVybGFwQWxsb3dhbmNlRXhjZWVkZWQgPSB0cnVlO1xuICAgICAgICAgICAgICAgICAgICB9XG5cbiAgICAgICAgICAgICAgICB9IGVsc2UgaWYgKGkgPT09IGFjdGl2ZUluZGV4KSB7XG4gICAgICAgICAgICAgICAgICAgIC8vQWN0aXZlIHRhYiBzaG91bGQgc2hvdyBldmVuIGlmIGFsbG93YW5jZSBleGNlZWRlZC4gKFdlIGxlZnQgcm9vbS4pXG4gICAgICAgICAgICAgICAgICAgIHRhYkVsZW1lbnQuY3NzKHtcbiAgICAgICAgICAgICAgICAgICAgICAgICd6LWluZGV4JzogJ2F1dG8nLFxuICAgICAgICAgICAgICAgICAgICAgICAgJ21hcmdpbi1sZWZ0JzogJydcbiAgICAgICAgICAgICAgICAgICAgfSk7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMudGFic0NvbnRhaW5lci5hcHBlbmQodGFiRWxlbWVudCk7XG4gICAgICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICAgICAgaWYgKHRhYk92ZXJsYXBBbGxvd2FuY2VFeGNlZWRlZCAmJiBpICE9PSBhY3RpdmVJbmRleCkge1xuICAgICAgICAgICAgICAgICAgICBpZiAoc2hvd1RhYk1lbnUpIHtcbiAgICAgICAgICAgICAgICAgICAgICAgIC8vVGFiIG1lbnUgYWxyZWFkeSBzaG93biwgc28gd2UganVzdCBhZGQgdG8gaXQuXG4gICAgICAgICAgICAgICAgICAgICAgICB0YWJFbGVtZW50LmNzcyh7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgJ3otaW5kZXgnOiAnYXV0bycsXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgJ21hcmdpbi1sZWZ0JzogJydcbiAgICAgICAgICAgICAgICAgICAgICAgIH0pO1xuICAgICAgICAgICAgICAgICAgICAgICAgdGhpcy50YWJEcm9wZG93bkNvbnRhaW5lci5hcHBlbmQodGFiRWxlbWVudCk7XG4gICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgICAgICAvL1dlIG5vdyBrbm93IHRoZSB0YWIgbWVudSBtdXN0IGJlIHNob3duLCBzbyB3ZSBoYXZlIHRvIHJlY2FsY3VsYXRlIGV2ZXJ5dGhpbmcuXG4gICAgICAgICAgICAgICAgICAgICAgICB0aGlzLl91cGRhdGVUYWJTaXplcyh0cnVlKTtcbiAgICAgICAgICAgICAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9sYXN0VmlzaWJsZVRhYkluZGV4ID0gaTtcbiAgICAgICAgICAgICAgICB0YWJFbGVtZW50LmNzcyh7XG4gICAgICAgICAgICAgICAgICAgICd6LWluZGV4JzogJ2F1dG8nLFxuICAgICAgICAgICAgICAgICAgICAnbWFyZ2luLWxlZnQnOiAnJ1xuICAgICAgICAgICAgICAgIH0pO1xuICAgICAgICAgICAgICAgIHRoaXMudGFic0NvbnRhaW5lci5hcHBlbmQodGFiRWxlbWVudCk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgIH1cbn1cbiIsImltcG9ydCAkIGZyb20gJ2pxdWVyeSc7XG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIEhlYWRlckJ1dHRvbiB7XG4gICAgY29uc3RydWN0b3IoaGVhZGVyLCBsYWJlbCwgY3NzQ2xhc3MsIGFjdGlvbikge1xuICAgICAgICB0aGlzLl9oZWFkZXIgPSBoZWFkZXI7XG4gICAgICAgIHRoaXMuZWxlbWVudCA9ICQoJzxsaSBjbGFzcz1cIicgKyBjc3NDbGFzcyArICdcIiB0aXRsZT1cIicgKyBsYWJlbCArICdcIj48L2xpPicpO1xuICAgICAgICB0aGlzLl9oZWFkZXIub24oJ2Rlc3Ryb3knLCB0aGlzLl8kZGVzdHJveSwgdGhpcyk7XG4gICAgICAgIHRoaXMuX2FjdGlvbiA9IGFjdGlvbjtcbiAgICAgICAgdGhpcy5lbGVtZW50Lm9uKCdjbGljayB0b3VjaHN0YXJ0JywgdGhpcy5fYWN0aW9uKTtcbiAgICAgICAgdGhpcy5faGVhZGVyLmNvbnRyb2xzQ29udGFpbmVyLmFwcGVuZCh0aGlzLmVsZW1lbnQpO1xuICAgIH1cblxuICAgIF8kZGVzdHJveSgpIHtcbiAgICAgICAgdGhpcy5lbGVtZW50Lm9mZigpO1xuICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlKCk7XG4gICAgfVxufVxuIiwiaW1wb3J0IERyYWdMaXN0ZW5lciBmcm9tICcuLi91dGlscy9EcmFnTGlzdGVuZXInXG5pbXBvcnQgJCBmcm9tICdqcXVlcnknXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFNwbGl0dGVyIHtcbiAgICBjb25zdHJ1Y3Rvcihpc1ZlcnRpY2FsLCBzaXplLCBncmFiU2l6ZSkge1xuICAgICAgICB0aGlzLl9pc1ZlcnRpY2FsID0gaXNWZXJ0aWNhbDtcbiAgICAgICAgdGhpcy5fc2l6ZSA9IHNpemU7XG4gICAgICAgIHRoaXMuX2dyYWJTaXplID0gZ3JhYlNpemUgPCBzaXplID8gc2l6ZSA6IGdyYWJTaXplO1xuXG4gICAgICAgIHRoaXMuZWxlbWVudCA9IHRoaXMuX2NyZWF0ZUVsZW1lbnQoKTtcbiAgICAgICAgdGhpcy5fZHJhZ0xpc3RlbmVyID0gbmV3IERyYWdMaXN0ZW5lcih0aGlzLmVsZW1lbnQpO1xuICAgIH1cblxuICAgIG9uKGV2ZW50LCBjYWxsYmFjaywgY29udGV4dCkge1xuICAgICAgICB0aGlzLl9kcmFnTGlzdGVuZXIub24oZXZlbnQsIGNhbGxiYWNrLCBjb250ZXh0KTtcbiAgICB9XG5cbiAgICBfJGRlc3Ryb3koKSB7XG4gICAgICAgIHRoaXMuZWxlbWVudC5yZW1vdmUoKTtcbiAgICB9XG5cbiAgICBfY3JlYXRlRWxlbWVudCgpIHtcbiAgICAgICAgdmFyIGRyYWdIYW5kbGUgPSAkKCc8ZGl2IGNsYXNzPVwibG1fZHJhZ19oYW5kbGVcIj48L2Rpdj4nKTtcbiAgICAgICAgdmFyIGVsZW1lbnQgPSAkKCc8ZGl2IGNsYXNzPVwibG1fc3BsaXR0ZXJcIj48L2Rpdj4nKTtcbiAgICAgICAgZWxlbWVudC5hcHBlbmQoZHJhZ0hhbmRsZSk7XG5cbiAgICAgICAgdmFyIGhhbmRsZUV4Y2Vzc1NpemUgPSB0aGlzLl9ncmFiU2l6ZSAtIHRoaXMuX3NpemU7XG4gICAgICAgIHZhciBoYW5kbGVFeGNlc3NQb3MgPSBoYW5kbGVFeGNlc3NTaXplIC8gMjtcblxuICAgICAgICBpZiAodGhpcy5faXNWZXJ0aWNhbCkge1xuICAgICAgICAgICAgZHJhZ0hhbmRsZS5jc3MoJ3RvcCcsIC1oYW5kbGVFeGNlc3NQb3MpO1xuICAgICAgICAgICAgZHJhZ0hhbmRsZS5jc3MoJ2hlaWdodCcsIHRoaXMuX3NpemUgKyBoYW5kbGVFeGNlc3NTaXplKTtcbiAgICAgICAgICAgIGVsZW1lbnQuYWRkQ2xhc3MoJ2xtX3ZlcnRpY2FsJyk7XG4gICAgICAgICAgICBlbGVtZW50WydoZWlnaHQnXSh0aGlzLl9zaXplKTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIGRyYWdIYW5kbGUuY3NzKCdsZWZ0JywgLWhhbmRsZUV4Y2Vzc1Bvcyk7XG4gICAgICAgICAgICBkcmFnSGFuZGxlLmNzcygnd2lkdGgnLCB0aGlzLl9zaXplICsgaGFuZGxlRXhjZXNzU2l6ZSk7XG4gICAgICAgICAgICBlbGVtZW50LmFkZENsYXNzKCdsbV9ob3Jpem9udGFsJyk7XG4gICAgICAgICAgICBlbGVtZW50Wyd3aWR0aCddKHRoaXMuX3NpemUpO1xuICAgICAgICB9XG5cbiAgICAgICAgcmV0dXJuIGVsZW1lbnQ7XG4gICAgfVxufVxuIiwiaW1wb3J0IERyYWdMaXN0ZW5lciBmcm9tICcuLi91dGlscy9EcmFnTGlzdGVuZXInXG5pbXBvcnQgRHJhZ1Byb3h5IGZyb20gJy4uL2NvbnRyb2xzL0RyYWdQcm94eSdcbmltcG9ydCB7XG4gICAgZm5CaW5kLFxuICAgIHN0cmlwVGFnc1xufSBmcm9tICcuLi91dGlscy91dGlscydcbmltcG9ydCAkIGZyb20gJ2pxdWVyeSdcblxuLyoqXG4gKiBSZXByZXNlbnRzIGFuIGluZGl2aWR1YWwgdGFiIHdpdGhpbiBhIFN0YWNrJ3MgaGVhZGVyXG4gKlxuICogQHBhcmFtIHtIZWFkZXJ9IGhlYWRlclxuICogQHBhcmFtIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBjb250ZW50SXRlbVxuICpcbiAqIEBjb25zdHJ1Y3RvclxuICovXG5cbmNvbnN0IF90ZW1wbGF0ZSA9ICc8bGkgY2xhc3M9XCJsbV90YWJcIj48aSBjbGFzcz1cImxtX2xlZnRcIj48L2k+JyArXG4gICAgICAgICc8c3BhbiBjbGFzcz1cImxtX3RpdGxlXCI+PC9zcGFuPjxkaXYgY2xhc3M9XCJsbV9jbG9zZV90YWJcIj48L2Rpdj4nICtcbiAgICAgICAgJzxpIGNsYXNzPVwibG1fcmlnaHRcIj48L2k+PC9saT4nXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFRhYiB7XG5cbiAgICBjb25zdHJ1Y3RvcihoZWFkZXIsIGNvbnRlbnRJdGVtKSB7XG4gICAgICAgIHRoaXMuaGVhZGVyID0gaGVhZGVyO1xuICAgICAgICB0aGlzLmNvbnRlbnRJdGVtID0gY29udGVudEl0ZW07XG4gICAgICAgIHRoaXMuZWxlbWVudCA9ICQoX3RlbXBsYXRlKTtcbiAgICAgICAgdGhpcy50aXRsZUVsZW1lbnQgPSB0aGlzLmVsZW1lbnQuZmluZCgnLmxtX3RpdGxlJyk7XG4gICAgICAgIHRoaXMuY2xvc2VFbGVtZW50ID0gdGhpcy5lbGVtZW50LmZpbmQoJy5sbV9jbG9zZV90YWInKTtcbiAgICAgICAgdGhpcy5jbG9zZUVsZW1lbnRbY29udGVudEl0ZW0uY29uZmlnLmlzQ2xvc2FibGUgPyAnc2hvdycgOiAnaGlkZSddKCk7XG4gICAgICAgIHRoaXMuaXNBY3RpdmUgPSBmYWxzZTtcblxuICAgICAgICB0aGlzLnNldFRpdGxlKGNvbnRlbnRJdGVtLmNvbmZpZy50aXRsZSk7XG4gICAgICAgIHRoaXMuY29udGVudEl0ZW0ub24oJ3RpdGxlQ2hhbmdlZCcsIHRoaXMuc2V0VGl0bGUsIHRoaXMpO1xuXG4gICAgICAgIHRoaXMuX2xheW91dE1hbmFnZXIgPSB0aGlzLmNvbnRlbnRJdGVtLmxheW91dE1hbmFnZXI7XG5cbiAgICAgICAgaWYgKFxuICAgICAgICAgICAgdGhpcy5fbGF5b3V0TWFuYWdlci5jb25maWcuc2V0dGluZ3MucmVvcmRlckVuYWJsZWQgPT09IHRydWUgJiZcbiAgICAgICAgICAgIGNvbnRlbnRJdGVtLmNvbmZpZy5yZW9yZGVyRW5hYmxlZCA9PT0gdHJ1ZVxuICAgICAgICApIHtcbiAgICAgICAgICAgIHRoaXMuX2RyYWdMaXN0ZW5lciA9IG5ldyBEcmFnTGlzdGVuZXIodGhpcy5lbGVtZW50KTtcbiAgICAgICAgICAgIHRoaXMuX2RyYWdMaXN0ZW5lci5vbignZHJhZ1N0YXJ0JywgdGhpcy5fb25EcmFnU3RhcnQsIHRoaXMpO1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbS5vbignZGVzdHJveScsIHRoaXMuX2RyYWdMaXN0ZW5lci5kZXN0cm95LCB0aGlzLl9kcmFnTGlzdGVuZXIpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fb25UYWJDbGlja0ZuID0gZm5CaW5kKHRoaXMuX29uVGFiQ2xpY2ssIHRoaXMpO1xuICAgICAgICB0aGlzLl9vbkNsb3NlQ2xpY2tGbiA9IGZuQmluZCh0aGlzLl9vbkNsb3NlQ2xpY2ssIHRoaXMpO1xuXG4gICAgICAgIHRoaXMuZWxlbWVudC5vbignbW91c2Vkb3duIHRvdWNoc3RhcnQnLCB0aGlzLl9vblRhYkNsaWNrRm4pO1xuXG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtLmNvbmZpZy5pc0Nsb3NhYmxlKSB7XG4gICAgICAgICAgICB0aGlzLmNsb3NlRWxlbWVudC5vbignY2xpY2sgdG91Y2hzdGFydCcsIHRoaXMuX29uQ2xvc2VDbGlja0ZuKTtcbiAgICAgICAgICAgIHRoaXMuY2xvc2VFbGVtZW50Lm9uKCdtb3VzZWRvd24nLCB0aGlzLl9vbkNsb3NlTW91c2Vkb3duKTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRoaXMuY2xvc2VFbGVtZW50LnJlbW92ZSgpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5jb250ZW50SXRlbS50YWIgPSB0aGlzO1xuICAgICAgICB0aGlzLmNvbnRlbnRJdGVtLmVtaXQoJ3RhYicsIHRoaXMpO1xuICAgICAgICB0aGlzLmNvbnRlbnRJdGVtLmxheW91dE1hbmFnZXIuZW1pdCgndGFiQ3JlYXRlZCcsIHRoaXMpO1xuXG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtLmlzQ29tcG9uZW50KSB7XG4gICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtLmNvbnRhaW5lci50YWIgPSB0aGlzO1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbS5jb250YWluZXIuZW1pdCgndGFiJywgdGhpcyk7XG4gICAgICAgIH1cbiAgICB9XG5cblxuICAgIC8qKlxuICAgICAqIFNldHMgdGhlIHRhYidzIHRpdGxlIHRvIHRoZSBwcm92aWRlZCBzdHJpbmcgYW5kIHNldHNcbiAgICAgKiBpdHMgdGl0bGUgYXR0cmlidXRlIHRvIGEgcHVyZSB0ZXh0IHJlcHJlc2VudGF0aW9uICh3aXRob3V0XG4gICAgICogaHRtbCB0YWdzKSBvZiB0aGUgc2FtZSBzdHJpbmcuXG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHBhcmFtIHtTdHJpbmd9IHRpdGxlIGNhbiBjb250YWluIGh0bWxcbiAgICAgKi9cbiAgICBzZXRUaXRsZSh0aXRsZSkge1xuICAgICAgICB0aGlzLmVsZW1lbnQuYXR0cigndGl0bGUnLCBzdHJpcFRhZ3ModGl0bGUpKTtcbiAgICAgICAgdGhpcy50aXRsZUVsZW1lbnQuaHRtbCh0aXRsZSk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogU2V0cyB0aGlzIHRhYidzIGFjdGl2ZSBzdGF0ZS4gVG8gcHJvZ3JhbW1hdGljYWxseVxuICAgICAqIHN3aXRjaCB0YWJzLCB1c2UgaGVhZGVyLnNldEFjdGl2ZUNvbnRlbnRJdGVtKCBpdGVtICkgaW5zdGVhZC5cbiAgICAgKlxuICAgICAqIEBwdWJsaWNcbiAgICAgKiBAcGFyYW0ge0Jvb2xlYW59IGlzQWN0aXZlXG4gICAgICovXG4gICAgc2V0QWN0aXZlKGlzQWN0aXZlKSB7XG4gICAgICAgIGlmIChpc0FjdGl2ZSA9PT0gdGhpcy5pc0FjdGl2ZSkge1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG4gICAgICAgIHRoaXMuaXNBY3RpdmUgPSBpc0FjdGl2ZTtcblxuICAgICAgICBpZiAoaXNBY3RpdmUpIHtcbiAgICAgICAgICAgIHRoaXMuZWxlbWVudC5hZGRDbGFzcygnbG1fYWN0aXZlJyk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlQ2xhc3MoJ2xtX2FjdGl2ZScpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRGVzdHJveXMgdGhlIHRhYlxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfJGRlc3Ryb3koKSB7XG4gICAgICAgIHRoaXMuZWxlbWVudC5vZmYoJ21vdXNlZG93biB0b3VjaHN0YXJ0JywgdGhpcy5fb25UYWJDbGlja0ZuKTtcbiAgICAgICAgdGhpcy5jbG9zZUVsZW1lbnQub2ZmKCdjbGljayB0b3VjaHN0YXJ0JywgdGhpcy5fb25DbG9zZUNsaWNrRm4pO1xuICAgICAgICBpZiAodGhpcy5fZHJhZ0xpc3RlbmVyKSB7XG4gICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtLm9mZignZGVzdHJveScsIHRoaXMuX2RyYWdMaXN0ZW5lci5kZXN0cm95LCB0aGlzLl9kcmFnTGlzdGVuZXIpO1xuICAgICAgICAgICAgdGhpcy5fZHJhZ0xpc3RlbmVyLm9mZignZHJhZ1N0YXJ0JywgdGhpcy5fb25EcmFnU3RhcnQpO1xuICAgICAgICAgICAgdGhpcy5fZHJhZ0xpc3RlbmVyID0gbnVsbDtcbiAgICAgICAgfVxuICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlKCk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ2FsbGJhY2sgZm9yIHRoZSBEcmFnTGlzdGVuZXJcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtOdW1iZXJ9IHggVGhlIHRhYnMgYWJzb2x1dGUgeCBwb3NpdGlvblxuICAgICAqIEBwYXJhbSAgIHtOdW1iZXJ9IHkgVGhlIHRhYnMgYWJzb2x1dGUgeSBwb3NpdGlvblxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfb25EcmFnU3RhcnQoeCwgeSkge1xuICAgICAgICBpZiAoIXRoaXMuaGVhZGVyLl9jYW5EZXN0cm95KVxuICAgICAgICAgICAgcmV0dXJuIG51bGw7XG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtLnBhcmVudC5pc01heGltaXNlZCA9PT0gdHJ1ZSkge1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbS5wYXJlbnQudG9nZ2xlTWF4aW1pc2UoKTtcbiAgICAgICAgfVxuICAgICAgICBuZXcgRHJhZ1Byb3h5KFxuICAgICAgICAgICAgeCxcbiAgICAgICAgICAgIHksXG4gICAgICAgICAgICB0aGlzLl9kcmFnTGlzdGVuZXIsXG4gICAgICAgICAgICB0aGlzLl9sYXlvdXRNYW5hZ2VyLFxuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbSxcbiAgICAgICAgICAgIHRoaXMuaGVhZGVyLnBhcmVudFxuICAgICAgICApO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxiYWNrIHdoZW4gdGhlIHRhYiBpcyBjbGlja2VkXG4gICAgICpcbiAgICAgKiBAcGFyYW0ge2pRdWVyeSBET00gZXZlbnR9IGV2ZW50XG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vblRhYkNsaWNrKGV2ZW50KSB7XG4gICAgICAgIC8vIGxlZnQgbW91c2UgYnV0dG9uIG9yIHRhcFxuICAgICAgICBpZiAoZXZlbnQuYnV0dG9uID09PSAwIHx8IGV2ZW50LnR5cGUgPT09ICd0b3VjaHN0YXJ0Jykge1xuICAgICAgICAgICAgdGhpcy5oZWFkZXIucGFyZW50LnNldEFjdGl2ZUNvbnRlbnRJdGVtKCB0aGlzLmNvbnRlbnRJdGVtICk7XG5cbiAgICAgICAgICAgIC8vIG1pZGRsZSBtb3VzZSBidXR0b25cbiAgICAgICAgfSBlbHNlIGlmIChldmVudC5idXR0b24gPT09IDEgJiYgdGhpcy5jb250ZW50SXRlbS5jb25maWcuaXNDbG9zYWJsZSkge1xuICAgICAgICAgICAgdGhpcy5fb25DbG9zZUNsaWNrKGV2ZW50KTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxiYWNrIHdoZW4gdGhlIHRhYidzIGNsb3NlIGJ1dHRvbiBpc1xuICAgICAqIGNsaWNrZWRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtqUXVlcnkgRE9NIGV2ZW50fSBldmVudFxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfb25DbG9zZUNsaWNrKGV2ZW50KSB7XG4gICAgICAgIGV2ZW50LnN0b3BQcm9wYWdhdGlvbigpO1xuICAgICAgICBpZiAoIXRoaXMuaGVhZGVyLl9jYW5EZXN0cm95KVxuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB0aGlzLmhlYWRlci5wYXJlbnQucmVtb3ZlQ2hpbGQodGhpcy5jb250ZW50SXRlbSk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ2FsbGJhY2sgdG8gY2FwdHVyZSB0YWIgY2xvc2UgYnV0dG9uIG1vdXNlZG93blxuICAgICAqIHRvIHByZXZlbnQgdGFiIGZyb20gYWN0aXZhdGluZy5cbiAgICAgKlxuICAgICAqIEBwYXJhbSAoalF1ZXJ5IERPTSBldmVudCkgZXZlbnRcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX29uQ2xvc2VNb3VzZWRvd24oZXZlbnQpIHtcbiAgICAgICAgZXZlbnQuc3RvcFByb3BhZ2F0aW9uKCk7XG4gICAgfVxufVxuIiwiaW1wb3J0IHtcbiAgICBub3csXG4gICAgYW5pbUZyYW1lLFxuICAgIGZuQmluZFxufSBmcm9tICcuLi91dGlscy91dGlscydcbmltcG9ydCAkIGZyb20gJ2pxdWVyeSdcblxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBUcmFuc2l0aW9uSW5kaWNhdG9yIHtcbiAgICBjb25zdHJ1Y3RvcigpIHtcbiAgICAgICAgdGhpcy5fZWxlbWVudCA9ICQoJzxkaXYgY2xhc3M9XCJsbV90cmFuc2l0aW9uX2luZGljYXRvclwiPjwvZGl2PicpO1xuICAgICAgICAkKGRvY3VtZW50LmJvZHkpLmFwcGVuZCh0aGlzLl9lbGVtZW50KTtcblxuICAgICAgICB0aGlzLl90b0VsZW1lbnQgPSBudWxsO1xuICAgICAgICB0aGlzLl9mcm9tRGltZW5zaW9ucyA9IG51bGw7XG4gICAgICAgIHRoaXMuX3RvdGFsQW5pbWF0aW9uRHVyYXRpb24gPSAyMDA7XG4gICAgICAgIHRoaXMuX2FuaW1hdGlvblN0YXJ0VGltZSA9IG51bGw7XG4gICAgfVxuXG4gICAgZGVzdHJveSgpIHtcbiAgICAgICAgdGhpcy5fZWxlbWVudC5yZW1vdmUoKTtcbiAgICB9XG5cbiAgICB0cmFuc2l0aW9uRWxlbWVudHMoZnJvbUVsZW1lbnQsIHRvRWxlbWVudCkge1xuICAgICAgICAvKipcbiAgICAgICAgICogVE9ETyAtIFRoaXMgaXMgbm90IHF1aXRlIGFzIGNvb2wgYXMgZXhwZWN0ZWQuIFJldmlldy5cbiAgICAgICAgICovXG4gICAgICAgIHJldHVybjtcbiAgICAgICAgLy8gdGhpcy5fdG9FbGVtZW50ID0gdG9FbGVtZW50O1xuICAgICAgICAvLyB0aGlzLl9hbmltYXRpb25TdGFydFRpbWUgPSBub3coKTtcbiAgICAgICAgLy8gdGhpcy5fZnJvbURpbWVuc2lvbnMgPSB0aGlzLl9tZWFzdXJlKGZyb21FbGVtZW50KTtcbiAgICAgICAgLy8gdGhpcy5fZnJvbURpbWVuc2lvbnMub3BhY2l0eSA9IDAuODtcbiAgICAgICAgLy8gdGhpcy5fZWxlbWVudC5zaG93KCkuY3NzKHRoaXMuX2Zyb21EaW1lbnNpb25zKTtcbiAgICAgICAgLy8gYW5pbUZyYW1lKGZuQmluZCh0aGlzLl9uZXh0QW5pbWF0aW9uRnJhbWUsIHRoaXMpKTtcbiAgICB9XG5cbiAgICBfbmV4dEFuaW1hdGlvbkZyYW1lKCkge1xuICAgICAgICB2YXIgdG9EaW1lbnNpb25zID0gdGhpcy5fbWVhc3VyZSh0aGlzLl90b0VsZW1lbnQpLFxuICAgICAgICAgICAgYW5pbWF0aW9uUHJvZ3Jlc3MgPSAobm93KCkgLSB0aGlzLl9hbmltYXRpb25TdGFydFRpbWUpIC8gdGhpcy5fdG90YWxBbmltYXRpb25EdXJhdGlvbixcbiAgICAgICAgICAgIGN1cnJlbnRGcmFtZVN0eWxlcyA9IHt9LFxuICAgICAgICAgICAgY3NzUHJvcGVydHk7XG5cbiAgICAgICAgaWYgKGFuaW1hdGlvblByb2dyZXNzID49IDEpIHtcbiAgICAgICAgICAgIHRoaXMuX2VsZW1lbnQuaGlkZSgpO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgdG9EaW1lbnNpb25zLm9wYWNpdHkgPSAwO1xuXG4gICAgICAgIGZvciAoY3NzUHJvcGVydHkgaW4gdGhpcy5fZnJvbURpbWVuc2lvbnMpIHtcbiAgICAgICAgICAgIGN1cnJlbnRGcmFtZVN0eWxlc1tjc3NQcm9wZXJ0eV0gPSB0aGlzLl9mcm9tRGltZW5zaW9uc1tjc3NQcm9wZXJ0eV0gK1xuICAgICAgICAgICAgICAgICh0b0RpbWVuc2lvbnNbY3NzUHJvcGVydHldIC0gdGhpcy5fZnJvbURpbWVuc2lvbnNbY3NzUHJvcGVydHldKSAqXG4gICAgICAgICAgICAgICAgYW5pbWF0aW9uUHJvZ3Jlc3M7XG4gICAgICAgIH1cblxuICAgICAgICB0aGlzLl9lbGVtZW50LmNzcyhjdXJyZW50RnJhbWVTdHlsZXMpO1xuICAgICAgICBhbmltRnJhbWUoZm5CaW5kKHRoaXMuX25leHRBbmltYXRpb25GcmFtZSwgdGhpcykpO1xuICAgIH1cblxuICAgIF9tZWFzdXJlKGVsZW1lbnQpIHtcbiAgICAgICAgdmFyIG9mZnNldCA9IGVsZW1lbnQub2Zmc2V0KCk7XG5cbiAgICAgICAgcmV0dXJuIHtcbiAgICAgICAgICAgIGxlZnQ6IG9mZnNldC5sZWZ0LFxuICAgICAgICAgICAgdG9wOiBvZmZzZXQudG9wLFxuICAgICAgICAgICAgd2lkdGg6IGVsZW1lbnQub3V0ZXJXaWR0aCgpLFxuICAgICAgICAgICAgaGVpZ2h0OiBlbGVtZW50Lm91dGVySGVpZ2h0KClcbiAgICAgICAgfTtcbiAgICB9XG59XG4iLCJcblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgQ29uZmlndXJhdGlvbkVycm9yIGV4dGVuZHMgRXJyb3Ige1xuICAgIGNvbnN0cnVjdG9yKG1lc3NhZ2UsIG5vZGUpIHtcbiAgICAgICAgc3VwZXIoKTtcblxuICAgICAgICB0aGlzLm5hbWUgPSAnQ29uZmlndXJhdGlvbiBFcnJvcic7XG4gICAgICAgIHRoaXMubWVzc2FnZSA9IG1lc3NhZ2U7XG4gICAgICAgIHRoaXMubm9kZSA9IG5vZGU7XG4gICAgfVxufVxuIiwiaW1wb3J0IEV2ZW50RW1pdHRlciBmcm9tICcuLi91dGlscy9FdmVudEVtaXR0ZXInXG5pbXBvcnQgeyBcbiAgQUxMX0VWRU5UXG59IGZyb20gJy4uL3V0aWxzL0V2ZW50RW1pdHRlcidcblxuaW1wb3J0IEJ1YmJsaW5nRXZlbnQgZnJvbSAnLi4vdXRpbHMvQnViYmxpbmdFdmVudCdcbmltcG9ydCBSb290IGZyb20gJy4vUm9vdCdcbmltcG9ydCBDb25maWd1cmF0aW9uRXJyb3IgZnJvbSAnLi4vZXJyb3JzL0NvbmZpZ3VyYXRpb25FcnJvcidcbmltcG9ydCBpdGVtRGVmYXVsdENvbmZpZyBmcm9tICcuLi9jb25maWcvSXRlbURlZmF1bHRDb25maWcnXG5cbmltcG9ydCB7XG4gICAgZm5CaW5kLFxuICAgIGFuaW1GcmFtZSxcbiAgICBpbmRleE9mXG59IGZyb20gJy4uL3V0aWxzL3V0aWxzJ1xuXG4vKipcbiAqIFRoaXMgaXMgdGhlIGJhc2VjbGFzcyB0aGF0IGFsbCBjb250ZW50IGl0ZW1zIGluaGVyaXQgZnJvbS5cbiAqIE1vc3QgbWV0aG9kcyBwcm92aWRlIGEgc3Vic2V0IG9mIHdoYXQgdGhlIHN1Yi1jbGFzc2VzIGRvLlxuICpcbiAqIEl0IGFsc28gcHJvdmlkZXMgYSBudW1iZXIgb2YgZnVuY3Rpb25zIGZvciB0cmVlIHRyYXZlcnNhbFxuICpcbiAqIEBwYXJhbSB7bG0uTGF5b3V0TWFuYWdlcn0gbGF5b3V0TWFuYWdlclxuICogQHBhcmFtIHtpdGVtIG5vZGUgY29uZmlndXJhdGlvbn0gY29uZmlnXG4gKiBAcGFyYW0ge2xtLml0ZW19IHBhcmVudFxuICpcbiAqIEBldmVudCBzdGF0ZUNoYW5nZWRcbiAqIEBldmVudCBiZWZvcmVJdGVtRGVzdHJveWVkXG4gKiBAZXZlbnQgaXRlbURlc3Ryb3llZFxuICogQGV2ZW50IGl0ZW1DcmVhdGVkXG4gKiBAZXZlbnQgY29tcG9uZW50Q3JlYXRlZFxuICogQGV2ZW50IHJvd0NyZWF0ZWRcbiAqIEBldmVudCBjb2x1bW5DcmVhdGVkXG4gKiBAZXZlbnQgc3RhY2tDcmVhdGVkXG4gKlxuICogQGNvbnN0cnVjdG9yXG4gKi9cblxuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBBYnN0cmFjdENvbnRlbnRJdGVtIGV4dGVuZHMgRXZlbnRFbWl0dGVyIHtcbiAgICBjb25zdHJ1Y3RvcihsYXlvdXRNYW5hZ2VyLCBjb25maWcsIHBhcmVudCkge1xuXG4gICAgICAgIHN1cGVyKCk7XG5cbiAgICAgICAgdGhpcy5jb25maWcgPSB0aGlzLl9leHRlbmRJdGVtTm9kZShjb25maWcpO1xuICAgICAgICB0aGlzLnR5cGUgPSBjb25maWcudHlwZTtcbiAgICAgICAgdGhpcy5jb250ZW50SXRlbXMgPSBbXTtcbiAgICAgICAgdGhpcy5wYXJlbnQgPSBwYXJlbnQ7XG5cbiAgICAgICAgdGhpcy5pc0luaXRpYWxpc2VkID0gZmFsc2U7XG4gICAgICAgIHRoaXMuaXNNYXhpbWlzZWQgPSBmYWxzZTtcbiAgICAgICAgdGhpcy5pc1Jvb3QgPSBmYWxzZTtcbiAgICAgICAgdGhpcy5pc1JvdyA9IGZhbHNlO1xuICAgICAgICB0aGlzLmlzQ29sdW1uID0gZmFsc2U7XG4gICAgICAgIHRoaXMuaXNTdGFjayA9IGZhbHNlO1xuICAgICAgICB0aGlzLmlzQ29tcG9uZW50ID0gZmFsc2U7XG5cbiAgICAgICAgdGhpcy5sYXlvdXRNYW5hZ2VyID0gbGF5b3V0TWFuYWdlcjtcbiAgICAgICAgdGhpcy5fcGVuZGluZ0V2ZW50UHJvcGFnYXRpb25zID0ge307XG4gICAgICAgIHRoaXMuX3Rocm90dGxlZEV2ZW50cyA9IFsnc3RhdGVDaGFuZ2VkJ107XG5cbiAgICAgICAgdGhpcy5vbihBTExfRVZFTlQsIHRoaXMuX3Byb3BhZ2F0ZUV2ZW50LCB0aGlzKTtcblxuICAgICAgICBpZiAoY29uZmlnLmNvbnRlbnQpIHtcbiAgICAgICAgICAgIHRoaXMuX2NyZWF0ZUNvbnRlbnRJdGVtcyhjb25maWcpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogU2V0IHRoZSBzaXplIG9mIHRoZSBjb21wb25lbnQgYW5kIGl0cyBjaGlsZHJlbiwgY2FsbGVkIHJlY3Vyc2l2ZWx5XG4gICAgICpcbiAgICAgKiBAYWJzdHJhY3RcbiAgICAgKiBAcmV0dXJucyB2b2lkXG4gICAgICovXG4gICAgc2V0U2l6ZSgpIHtcbiAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdBYnN0cmFjdCBNZXRob2QnKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxscyBhIG1ldGhvZCByZWN1cnNpdmVseSBkb3dud2FyZHMgb24gdGhlIHRyZWVcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtTdHJpbmd9IGZ1bmN0aW9uTmFtZSAgICAgIHRoZSBuYW1lIG9mIHRoZSBmdW5jdGlvbiB0byBiZSBjYWxsZWRcbiAgICAgKiBAcGFyYW0gICB7W0FycmF5XX1mdW5jdGlvbkFyZ3VtZW50cyBvcHRpb25hbCBhcmd1bWVudHMgdGhhdCBhcmUgcGFzc2VkIHRvIGV2ZXJ5IGZ1bmN0aW9uXG4gICAgICogQHBhcmFtICAge1tib29sXX0gYm90dG9tVXAgICAgICAgICAgQ2FsbCBtZXRob2RzIGZyb20gYm90dG9tIHRvIHRvcCwgZGVmYXVsdHMgdG8gZmFsc2VcbiAgICAgKiBAcGFyYW0gICB7W2Jvb2xdfSBza2lwU2VsZiAgICAgICAgICBEb24ndCBpbnZva2UgdGhlIG1ldGhvZCBvbiB0aGUgY2xhc3MgdGhhdCBjYWxscyBpdCwgZGVmYXVsdHMgdG8gZmFsc2VcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGNhbGxEb3dud2FyZHMoZnVuY3Rpb25OYW1lLCBmdW5jdGlvbkFyZ3VtZW50cywgYm90dG9tVXAsIHNraXBTZWxmKSB7XG4gICAgICAgIHZhciBpO1xuXG4gICAgICAgIGlmIChib3R0b21VcCAhPT0gdHJ1ZSAmJiBza2lwU2VsZiAhPT0gdHJ1ZSkge1xuICAgICAgICAgICAgdGhpc1tmdW5jdGlvbk5hbWVdLmFwcGx5KHRoaXMsIGZ1bmN0aW9uQXJndW1lbnRzIHx8IFtdKTtcbiAgICAgICAgfVxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zW2ldLmNhbGxEb3dud2FyZHMoZnVuY3Rpb25OYW1lLCBmdW5jdGlvbkFyZ3VtZW50cywgYm90dG9tVXApO1xuICAgICAgICB9XG4gICAgICAgIGlmIChib3R0b21VcCA9PT0gdHJ1ZSAmJiBza2lwU2VsZiAhPT0gdHJ1ZSkge1xuICAgICAgICAgICAgdGhpc1tmdW5jdGlvbk5hbWVdLmFwcGx5KHRoaXMsIGZ1bmN0aW9uQXJndW1lbnRzIHx8IFtdKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJlbW92ZXMgYSBjaGlsZCBub2RlIChhbmQgaXRzIGNoaWxkcmVuKSBmcm9tIHRoZSB0cmVlXG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7Q29udGVudEl0ZW19IGNvbnRlbnRJdGVtXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICByZW1vdmVDaGlsZChjb250ZW50SXRlbSwga2VlcENoaWxkKSB7XG4gICAgICAgIC8qXG4gICAgICAgICAqIEdldCB0aGUgcG9zaXRpb24gb2YgdGhlIGl0ZW0gdGhhdCdzIHRvIGJlIHJlbW92ZWQgd2l0aGluIGFsbCBjb250ZW50IGl0ZW1zIHRoaXMgbm9kZSBjb250YWluc1xuICAgICAgICAgKi9cbiAgICAgICAgdmFyIGluZGV4ID0gaW5kZXhPZihjb250ZW50SXRlbSwgdGhpcy5jb250ZW50SXRlbXMpO1xuXG4gICAgICAgIC8qXG4gICAgICAgICAqIE1ha2Ugc3VyZSB0aGUgY29udGVudCBpdGVtIHRvIGJlIHJlbW92ZWQgaXMgYWN0dWFsbHkgYSBjaGlsZCBvZiB0aGlzIGl0ZW1cbiAgICAgICAgICovXG4gICAgICAgIGlmIChpbmRleCA9PT0gLTEpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ2FuXFwndCByZW1vdmUgY2hpbGQgaXRlbS4gVW5rbm93biBjb250ZW50IGl0ZW0nKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuXHRcdCAqIENhbGwgLl8kZGVzdHJveSBvbiB0aGUgY29udGVudCBpdGVtLiBcblx0XHQgKiBUaGVuIHVzZSAnY2FsbERvd253YXJkcycgdG8gZGVzdHJveSBhbnkgY2hpbGRyZW5cblx0XHQgKi9cbiAgICAgICAgaWYgKGtlZXBDaGlsZCAhPT0gdHJ1ZSkge1xuXHRcdFx0dGhpcy5jb250ZW50SXRlbXNbaW5kZXhdLl8kZGVzdHJveSgpO1xuXHRcdFx0dGhpcy5jb250ZW50SXRlbXNbaW5kZXhdLmNhbGxEb3dud2FyZHMoJ18kZGVzdHJveScsIFtdLCB0cnVlLCB0cnVlKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBSZW1vdmUgdGhlIGNvbnRlbnQgaXRlbSBmcm9tIHRoaXMgbm9kZXMgYXJyYXkgb2YgY2hpbGRyZW5cbiAgICAgICAgICovXG4gICAgICAgIHRoaXMuY29udGVudEl0ZW1zLnNwbGljZShpbmRleCwgMSk7XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIFJlbW92ZSB0aGUgaXRlbSBmcm9tIHRoZSBjb25maWd1cmF0aW9uXG4gICAgICAgICAqL1xuICAgICAgICB0aGlzLmNvbmZpZy5jb250ZW50LnNwbGljZShpbmRleCwgMSk7XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIElmIHRoaXMgbm9kZSBzdGlsbCBjb250YWlucyBvdGhlciBjb250ZW50IGl0ZW1zLCBhZGp1c3QgdGhlaXIgc2l6ZVxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA+IDApIHtcbiAgICAgICAgICAgIHRoaXMuY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuXG4gICAgICAgICAgICAvKipcbiAgICAgICAgICAgICAqIElmIHRoaXMgd2FzIHRoZSBsYXN0IGNvbnRlbnQgaXRlbSwgcmVtb3ZlIHRoaXMgbm9kZSBhcyB3ZWxsXG4gICAgICAgICAgICAgKi9cbiAgICAgICAgfSBlbHNlIGlmICghKHRoaXMgaW5zdGFuY2VvZiBSb290KSAmJiB0aGlzLmNvbmZpZy5pc0Nsb3NhYmxlID09PSB0cnVlKSB7XG4gICAgICAgICAgICB0aGlzLnBhcmVudC5yZW1vdmVDaGlsZCh0aGlzKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEhpZGVzIGEgY2hpbGQgbm9kZSAoYW5kIGl0cyBjaGlsZHJlbikgZnJvbSB0aGUgdHJlZSByZWNsYWltaW5nIGl0cyBzcGFjZSBpbiB0aGUgbGF5b3V0XG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7Q29udGVudEl0ZW19IGNvbnRlbnRJdGVtXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICB1bmRpc3BsYXlDaGlsZChjb250ZW50SXRlbSkge1xuICAgICAgICAvKlxuICAgICAgICAgKiBHZXQgdGhlIHBvc2l0aW9uIG9mIHRoZSBpdGVtIHRoYXQncyB0byBiZSByZW1vdmVkIHdpdGhpbiBhbGwgY29udGVudCBpdGVtcyB0aGlzIG5vZGUgY29udGFpbnNcbiAgICAgICAgICovXG4gICAgICAgIHZhciBpbmRleCA9IGluZGV4T2YoY29udGVudEl0ZW0sIHRoaXMuY29udGVudEl0ZW1zKTtcblxuICAgICAgICAvKlxuICAgICAgICAgKiBNYWtlIHN1cmUgdGhlIGNvbnRlbnQgaXRlbSB0byBiZSByZW1vdmVkIGlzIGFjdHVhbGx5IGEgY2hpbGQgb2YgdGhpcyBpdGVtXG4gICAgICAgICAqL1xuICAgICAgICBpZiAoaW5kZXggPT09IC0xKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0NhblxcJ3QgcmVtb3ZlIGNoaWxkIGl0ZW0uIFVua25vd24gY29udGVudCBpdGVtJyk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoISh0aGlzIGluc3RhbmNlb2YgUm9vdCkgJiYgdGhpcy5jb25maWcuaXNDbG9zYWJsZSA9PT0gdHJ1ZSkge1xuICAgICAgICAgICAgdGhpcy5wYXJlbnQudW5kaXNwbGF5Q2hpbGQodGhpcyk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBTZXRzIHVwIHRoZSB0cmVlIHN0cnVjdHVyZSBmb3IgdGhlIG5ld2x5IGFkZGVkIGNoaWxkXG4gICAgICogVGhlIHJlc3BvbnNpYmlsaXR5IGZvciB0aGUgYWN0dWFsIERPTSBtYW5pcHVsYXRpb25zIGxpZXNcbiAgICAgKiB3aXRoIHRoZSBjb25jcmV0ZSBpdGVtXG4gICAgICpcbiAgICAgKiBAcGFyYW0ge0Fic3RyYWN0Q29udGVudEl0ZW19IGNvbnRlbnRJdGVtXG4gICAgICogQHBhcmFtIHtbSW50XX0gaW5kZXggSWYgb21pdHRlZCBpdGVtIHdpbGwgYmUgYXBwZW5kZWRcbiAgICAgKi9cbiAgICBhZGRDaGlsZChjb250ZW50SXRlbSwgaW5kZXgpIHtcbiAgICAgICAgaWYgKGluZGV4ID09PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgIGluZGV4ID0gdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5jb250ZW50SXRlbXMuc3BsaWNlKGluZGV4LCAwLCBjb250ZW50SXRlbSk7XG5cbiAgICAgICAgaWYgKHRoaXMuY29uZmlnLmNvbnRlbnQgPT09IHVuZGVmaW5lZCkge1xuICAgICAgICAgICAgdGhpcy5jb25maWcuY29udGVudCA9IFtdO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5jb25maWcuY29udGVudC5zcGxpY2UoaW5kZXgsIDAsIGNvbnRlbnRJdGVtLmNvbmZpZyk7XG4gICAgICAgIGNvbnRlbnRJdGVtLnBhcmVudCA9IHRoaXM7XG5cbiAgICAgICAgaWYgKGNvbnRlbnRJdGVtLnBhcmVudC5pc0luaXRpYWxpc2VkID09PSB0cnVlICYmIGNvbnRlbnRJdGVtLmlzSW5pdGlhbGlzZWQgPT09IGZhbHNlKSB7XG4gICAgICAgICAgICBjb250ZW50SXRlbS5fJGluaXQoKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJlcGxhY2VzIG9sZENoaWxkIHdpdGggbmV3Q2hpbGQuIFRoaXMgdXNlZCB0byB1c2UgalF1ZXJ5LnJlcGxhY2VXaXRoLi4uIHdoaWNoIGZvclxuICAgICAqIHNvbWUgcmVhc29uIHJlbW92ZXMgYWxsIGV2ZW50IGxpc3RlbmVycywgc28gaXNuJ3QgcmVhbGx5IGFuIG9wdGlvbi5cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBvbGRDaGlsZFxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBuZXdDaGlsZFxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgcmVwbGFjZUNoaWxkKG9sZENoaWxkLCBuZXdDaGlsZCwgXyRkZXN0cm95T2xkQ2hpbGQpIHtcblxuICAgICAgICBuZXdDaGlsZCA9IHRoaXMubGF5b3V0TWFuYWdlci5fJG5vcm1hbGl6ZUNvbnRlbnRJdGVtKG5ld0NoaWxkKTtcblxuICAgICAgICB2YXIgaW5kZXggPSBpbmRleE9mKG9sZENoaWxkLCB0aGlzLmNvbnRlbnRJdGVtcyksXG4gICAgICAgICAgICBwYXJlbnROb2RlID0gb2xkQ2hpbGQuZWxlbWVudFswXS5wYXJlbnROb2RlO1xuXG4gICAgICAgIGlmIChpbmRleCA9PT0gLTEpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ2FuXFwndCByZXBsYWNlIGNoaWxkLiBvbGRDaGlsZCBpcyBub3QgY2hpbGQgb2YgdGhpcycpO1xuICAgICAgICB9XG5cbiAgICAgICAgcGFyZW50Tm9kZS5yZXBsYWNlQ2hpbGQobmV3Q2hpbGQuZWxlbWVudFswXSwgb2xkQ2hpbGQuZWxlbWVudFswXSk7XG5cbiAgICAgICAgLypcbiAgICAgICAgICogT3B0aW9uYWxseSBkZXN0cm95IHRoZSBvbGQgY29udGVudCBpdGVtXG4gICAgICAgICAqL1xuICAgICAgICBpZiAoXyRkZXN0cm95T2xkQ2hpbGQgPT09IHRydWUpIHtcbiAgICAgICAgICAgIG9sZENoaWxkLnBhcmVudCA9IG51bGw7XG4gICAgICAgICAgICBvbGRDaGlsZC5fJGRlc3Ryb3koKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qXG4gICAgICAgICAqIFdpcmUgdGhlIG5ldyBjb250ZW50SXRlbSBpbnRvIHRoZSB0cmVlXG4gICAgICAgICAqL1xuICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpbmRleF0gPSBuZXdDaGlsZDtcbiAgICAgICAgbmV3Q2hpbGQucGFyZW50ID0gdGhpcztcblxuICAgICAgICAvKlxuICAgICAgICAgKiBVcGRhdGUgdGFiIHJlZmVyZW5jZVxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuaXNTdGFjaykge1xuICAgICAgICAgICAgdGhpcy5oZWFkZXIudGFic1tpbmRleF0uY29udGVudEl0ZW0gPSBuZXdDaGlsZDtcbiAgICAgICAgfVxuXG4gICAgICAgIC8vVE9ETyBUaGlzIGRvZXNuJ3QgdXBkYXRlIHRoZSBjb25maWcuLi4gcmVmYWN0b3IgdG8gbGVhdmUgaXRlbSBub2RlcyB1bnRvdWNoZWQgYWZ0ZXIgY3JlYXRpb25cbiAgICAgICAgaWYgKG5ld0NoaWxkLnBhcmVudC5pc0luaXRpYWxpc2VkID09PSB0cnVlICYmIG5ld0NoaWxkLmlzSW5pdGlhbGlzZWQgPT09IGZhbHNlKSB7XG4gICAgICAgICAgICBuZXdDaGlsZC5fJGluaXQoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENvbnZlbmllbmNlIG1ldGhvZC5cbiAgICAgKiBTaG9ydGhhbmQgZm9yIHRoaXMucGFyZW50LnJlbW92ZUNoaWxkKCB0aGlzIClcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIHJlbW92ZSgpIHtcbiAgICAgICAgdGhpcy5wYXJlbnQucmVtb3ZlQ2hpbGQodGhpcyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogUmVtb3ZlcyB0aGUgY29tcG9uZW50IGZyb20gdGhlIGxheW91dCBhbmQgY3JlYXRlcyBhIG5ld1xuICAgICAqIGJyb3dzZXIgd2luZG93IHdpdGggdGhlIGNvbXBvbmVudCBhbmQgaXRzIGNoaWxkcmVuIGluc2lkZVxuICAgICAqXG4gICAgICogQHJldHVybnMge0Jyb3dzZXJQb3BvdXR9XG4gICAgICovXG4gICAgcG9wb3V0KCkge1xuICAgICAgICB2YXIgYnJvd3NlclBvcG91dCA9IHRoaXMubGF5b3V0TWFuYWdlci5jcmVhdGVQb3BvdXQodGhpcyk7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgICAgICByZXR1cm4gYnJvd3NlclBvcG91dDtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBNYXhpbWlzZXMgdGhlIEl0ZW0gb3IgbWluaW1pc2VzIGl0IGlmIGl0IGlzIGFscmVhZHkgbWF4aW1pc2VkXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICB0b2dnbGVNYXhpbWlzZShlKSB7XG4gICAgICAgIGUgJiYgZS5wcmV2ZW50RGVmYXVsdCgpO1xuICAgICAgICBpZiAodGhpcy5pc01heGltaXNlZCA9PT0gdHJ1ZSkge1xuICAgICAgICAgICAgdGhpcy5sYXlvdXRNYW5hZ2VyLl8kbWluaW1pc2VJdGVtKHRoaXMpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgdGhpcy5sYXlvdXRNYW5hZ2VyLl8kbWF4aW1pc2VJdGVtKHRoaXMpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5pc01heGltaXNlZCA9ICF0aGlzLmlzTWF4aW1pc2VkO1xuICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBTZWxlY3RzIHRoZSBpdGVtIGlmIGl0IGlzIG5vdCBhbHJlYWR5IHNlbGVjdGVkXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBzZWxlY3QoKSB7XG4gICAgICAgIGlmICh0aGlzLmxheW91dE1hbmFnZXIuc2VsZWN0ZWRJdGVtICE9PSB0aGlzKSB7XG4gICAgICAgICAgICB0aGlzLmxheW91dE1hbmFnZXIuc2VsZWN0SXRlbSh0aGlzLCB0cnVlKTtcbiAgICAgICAgICAgIHRoaXMuZWxlbWVudC5hZGRDbGFzcygnbG1fc2VsZWN0ZWQnKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIERlLXNlbGVjdHMgdGhlIGl0ZW0gaWYgaXQgaXMgc2VsZWN0ZWRcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGRlc2VsZWN0KCkge1xuICAgICAgICBpZiAodGhpcy5sYXlvdXRNYW5hZ2VyLnNlbGVjdGVkSXRlbSA9PT0gdGhpcykge1xuICAgICAgICAgICAgdGhpcy5sYXlvdXRNYW5hZ2VyLnNlbGVjdGVkSXRlbSA9IG51bGw7XG4gICAgICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlQ2xhc3MoJ2xtX3NlbGVjdGVkJyk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBTZXQgdGhpcyBjb21wb25lbnQncyB0aXRsZVxuICAgICAqXG4gICAgICogQHB1YmxpY1xuICAgICAqIEBwYXJhbSB7U3RyaW5nfSB0aXRsZVxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgc2V0VGl0bGUodGl0bGUpIHtcbiAgICAgICAgdGhpcy5jb25maWcudGl0bGUgPSB0aXRsZTtcbiAgICAgICAgdGhpcy5lbWl0KCd0aXRsZUNoYW5nZWQnLCB0aXRsZSk7XG4gICAgICAgIHRoaXMuZW1pdCgnc3RhdGVDaGFuZ2VkJyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ2hlY2tzIHdoZXRoZXIgYSBwcm92aWRlZCBpZCBpcyBwcmVzZW50XG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHBhcmFtICAge1N0cmluZ30gIGlkXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7Qm9vbGVhbn0gaXNQcmVzZW50XG4gICAgICovXG4gICAgaGFzSWQoaWQpIHtcbiAgICAgICAgaWYgKCF0aGlzLmNvbmZpZy5pZCkge1xuICAgICAgICAgICAgcmV0dXJuIGZhbHNlO1xuICAgICAgICB9IGVsc2UgaWYgKHR5cGVvZiB0aGlzLmNvbmZpZy5pZCA9PT0gJ3N0cmluZycpIHtcbiAgICAgICAgICAgIHJldHVybiB0aGlzLmNvbmZpZy5pZCA9PT0gaWQ7XG4gICAgICAgIH0gZWxzZSBpZiAodGhpcy5jb25maWcuaWQgaW5zdGFuY2VvZiBBcnJheSkge1xuICAgICAgICAgICAgcmV0dXJuIGluZGV4T2YoaWQsIHRoaXMuY29uZmlnLmlkKSAhPT0gLTE7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBBZGRzIGFuIGlkLiBBZGRzIGl0IGFzIGEgc3RyaW5nIGlmIHRoZSBjb21wb25lbnQgZG9lc24ndFxuICAgICAqIGhhdmUgYW4gaWQgeWV0IG9yIGNyZWF0ZXMvdXNlcyBhbiBhcnJheVxuICAgICAqXG4gICAgICogQHB1YmxpY1xuICAgICAqIEBwYXJhbSB7U3RyaW5nfSBpZFxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgYWRkSWQoaWQpIHtcbiAgICAgICAgaWYgKHRoaXMuaGFzSWQoaWQpKSB7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoIXRoaXMuY29uZmlnLmlkKSB7XG4gICAgICAgICAgICB0aGlzLmNvbmZpZy5pZCA9IGlkO1xuICAgICAgICB9IGVsc2UgaWYgKHR5cGVvZiB0aGlzLmNvbmZpZy5pZCA9PT0gJ3N0cmluZycpIHtcbiAgICAgICAgICAgIHRoaXMuY29uZmlnLmlkID0gW3RoaXMuY29uZmlnLmlkLCBpZF07XG4gICAgICAgIH0gZWxzZSBpZiAodGhpcy5jb25maWcuaWQgaW5zdGFuY2VvZiBBcnJheSkge1xuICAgICAgICAgICAgdGhpcy5jb25maWcuaWQucHVzaChpZCk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBSZW1vdmVzIGFuIGV4aXN0aW5nIGlkLiBUaHJvd3MgYW4gZXJyb3JcbiAgICAgKiBpZiB0aGUgaWQgaXMgbm90IHByZXNlbnRcbiAgICAgKlxuICAgICAqIEBwdWJsaWNcbiAgICAgKiBAcGFyYW0gICB7U3RyaW5nfSBpZFxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgcmVtb3ZlSWQoaWQpIHtcbiAgICAgICAgaWYgKCF0aGlzLmhhc0lkKGlkKSkge1xuICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdJZCBub3QgZm91bmQnKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmICh0eXBlb2YgdGhpcy5jb25maWcuaWQgPT09ICdzdHJpbmcnKSB7XG4gICAgICAgICAgICBkZWxldGUgdGhpcy5jb25maWcuaWQ7XG4gICAgICAgIH0gZWxzZSBpZiAodGhpcy5jb25maWcuaWQgaW5zdGFuY2VvZiBBcnJheSkge1xuICAgICAgICAgICAgdmFyIGluZGV4ID0gaW5kZXhPZihpZCwgdGhpcy5jb25maWcuaWQpO1xuICAgICAgICAgICAgdGhpcy5jb25maWcuaWQuc3BsaWNlKGluZGV4LCAxKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqXG4gICAgICogU0VMRUNUT1JcbiAgICAgKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKi9cbiAgICBnZXRJdGVtc0J5RmlsdGVyKGZpbHRlcikge1xuICAgICAgICB2YXIgcmVzdWx0ID0gW10sXG4gICAgICAgICAgICBuZXh0ID0gZnVuY3Rpb24oY29udGVudEl0ZW0pIHtcbiAgICAgICAgICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IGNvbnRlbnRJdGVtLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuXG4gICAgICAgICAgICAgICAgICAgIGlmIChmaWx0ZXIoY29udGVudEl0ZW0uY29udGVudEl0ZW1zW2ldKSA9PT0gdHJ1ZSkge1xuICAgICAgICAgICAgICAgICAgICAgICAgcmVzdWx0LnB1c2goY29udGVudEl0ZW0uY29udGVudEl0ZW1zW2ldKTtcbiAgICAgICAgICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICAgICAgICAgIG5leHQoY29udGVudEl0ZW0uY29udGVudEl0ZW1zW2ldKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9O1xuXG4gICAgICAgIG5leHQodGhpcyk7XG4gICAgICAgIHJldHVybiByZXN1bHQ7XG4gICAgfVxuXG4gICAgZ2V0SXRlbXNCeUlkKGlkKSB7XG4gICAgICAgIHJldHVybiB0aGlzLmdldEl0ZW1zQnlGaWx0ZXIoZnVuY3Rpb24oaXRlbSkge1xuICAgICAgICAgICAgaWYgKGl0ZW0uY29uZmlnLmlkIGluc3RhbmNlb2YgQXJyYXkpIHtcbiAgICAgICAgICAgICAgICByZXR1cm4gaW5kZXhPZihpZCwgaXRlbS5jb25maWcuaWQpICE9PSAtMTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgcmV0dXJuIGl0ZW0uY29uZmlnLmlkID09PSBpZDtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfSk7XG4gICAgfVxuXG4gICAgZ2V0SXRlbXNCeVR5cGUodHlwZSkge1xuICAgICAgICByZXR1cm4gdGhpcy5fJGdldEl0ZW1zQnlQcm9wZXJ0eSgndHlwZScsIHR5cGUpO1xuICAgIH1cblxuICAgIGdldENvbXBvbmVudHNCeU5hbWUoY29tcG9uZW50TmFtZSkge1xuICAgICAgICB2YXIgY29tcG9uZW50cyA9IHRoaXMuXyRnZXRJdGVtc0J5UHJvcGVydHkoJ2NvbXBvbmVudE5hbWUnLCBjb21wb25lbnROYW1lKSxcbiAgICAgICAgICAgIGluc3RhbmNlcyA9IFtdLFxuICAgICAgICAgICAgaTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgY29tcG9uZW50cy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaW5zdGFuY2VzLnB1c2goY29tcG9uZW50c1tpXS5pbnN0YW5jZSk7XG4gICAgICAgIH1cblxuICAgICAgICByZXR1cm4gaW5zdGFuY2VzO1xuICAgIH1cblxuICAgIC8qKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqXG4gICAgICogUEFDS0FHRSBQUklWQVRFXG4gICAgICoqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKiovXG4gICAgXyRnZXRJdGVtc0J5UHJvcGVydHkoa2V5LCB2YWx1ZSkge1xuICAgICAgICByZXR1cm4gdGhpcy5nZXRJdGVtc0J5RmlsdGVyKGZ1bmN0aW9uKGl0ZW0pIHtcbiAgICAgICAgICAgIHJldHVybiBpdGVtW2tleV0gPT09IHZhbHVlO1xuICAgICAgICB9KTtcbiAgICB9XG5cbiAgICBfJHNldFBhcmVudChwYXJlbnQpIHtcbiAgICAgICAgdGhpcy5wYXJlbnQgPSBwYXJlbnQ7XG4gICAgfVxuXG4gICAgXyRoaWdobGlnaHREcm9wWm9uZSh4LCB5LCBhcmVhKSB7XG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci5kcm9wVGFyZ2V0SW5kaWNhdG9yLmhpZ2hsaWdodEFyZWEoYXJlYSk7XG4gICAgfVxuXG4gICAgXyRvbkRyb3AoY29udGVudEl0ZW0pIHtcbiAgICAgICAgdGhpcy5hZGRDaGlsZChjb250ZW50SXRlbSk7XG4gICAgfVxuXG4gICAgXyRoaWRlKCkge1xuICAgICAgICB0aGlzLl9jYWxsT25BY3RpdmVDb21wb25lbnRzKCdoaWRlJyk7XG4gICAgICAgIHRoaXMuZWxlbWVudC5oaWRlKCk7XG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci51cGRhdGVTaXplKCk7XG4gICAgfVxuXG4gICAgXyRzaG93KCkge1xuICAgICAgICB0aGlzLl9jYWxsT25BY3RpdmVDb21wb25lbnRzKCdzaG93Jyk7XG4gICAgICAgIHRoaXMuZWxlbWVudC5zaG93KCk7XG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci51cGRhdGVTaXplKCk7XG4gICAgfVxuXG4gICAgX2NhbGxPbkFjdGl2ZUNvbXBvbmVudHMobWV0aG9kTmFtZSkge1xuICAgICAgICB2YXIgc3RhY2tzID0gdGhpcy5nZXRJdGVtc0J5VHlwZSgnc3RhY2snKSxcbiAgICAgICAgICAgIGFjdGl2ZUNvbnRlbnRJdGVtLFxuICAgICAgICAgICAgaTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgc3RhY2tzLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBhY3RpdmVDb250ZW50SXRlbSA9IHN0YWNrc1tpXS5nZXRBY3RpdmVDb250ZW50SXRlbSgpO1xuXG4gICAgICAgICAgICBpZiAoYWN0aXZlQ29udGVudEl0ZW0gJiYgYWN0aXZlQ29udGVudEl0ZW0uaXNDb21wb25lbnQpIHtcbiAgICAgICAgICAgICAgICBhY3RpdmVDb250ZW50SXRlbS5jb250YWluZXJbbWV0aG9kTmFtZV0oKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIERlc3Ryb3lzIHRoaXMgaXRlbSBhbmRzIGl0cyBjaGlsZHJlblxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgXyRkZXN0cm95KCkge1xuICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdiZWZvcmVJdGVtRGVzdHJveWVkJyk7XG4gICAgICAgIHRoaXMuZWxlbWVudC5yZW1vdmUoKTtcbiAgICAgICAgdGhpcy5lbWl0QnViYmxpbmdFdmVudCgnaXRlbURlc3Ryb3llZCcpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJldHVybnMgdGhlIGFyZWEgdGhlIGNvbXBvbmVudCBjdXJyZW50bHkgb2NjdXBpZXMgaW4gdGhlIGZvcm1hdFxuICAgICAqXG4gICAgICoge1xuICAgICAqXHRcdHgxOiBpbnRcbiAgICAgKlx0XHR4eTogaW50XG4gICAgICpcdFx0eTE6IGludFxuICAgICAqXHRcdHkyOiBpbnRcbiAgICAgKlx0XHRjb250ZW50SXRlbTogY29udGVudEl0ZW1cbiAgICAgKiB9XG4gICAgICovXG4gICAgXyRnZXRBcmVhKGVsZW1lbnQpIHtcbiAgICAgICAgZWxlbWVudCA9IGVsZW1lbnQgfHwgdGhpcy5lbGVtZW50O1xuXG4gICAgICAgIHZhciBvZmZzZXQgPSBlbGVtZW50Lm9mZnNldCgpLFxuICAgICAgICAgICAgd2lkdGggPSBlbGVtZW50LndpZHRoKCksXG4gICAgICAgICAgICBoZWlnaHQgPSBlbGVtZW50LmhlaWdodCgpO1xuXG4gICAgICAgIHJldHVybiB7XG4gICAgICAgICAgICB4MTogb2Zmc2V0LmxlZnQsXG4gICAgICAgICAgICB5MTogb2Zmc2V0LnRvcCxcbiAgICAgICAgICAgIHgyOiBvZmZzZXQubGVmdCArIHdpZHRoLFxuICAgICAgICAgICAgeTI6IG9mZnNldC50b3AgKyBoZWlnaHQsXG4gICAgICAgICAgICBzdXJmYWNlOiB3aWR0aCAqIGhlaWdodCxcbiAgICAgICAgICAgIGNvbnRlbnRJdGVtOiB0aGlzXG4gICAgICAgIH07XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVGhlIHRyZWUgb2YgY29udGVudCBpdGVtcyBpcyBjcmVhdGVkIGluIHR3byBzdGVwczogRmlyc3QgYWxsIGNvbnRlbnQgaXRlbXMgYXJlIGluc3RhbnRpYXRlZCxcbiAgICAgKiB0aGVuIGluaXQgaXMgY2FsbGVkIHJlY3Vyc2l2ZWx5IGZyb20gdG9wIHRvIGJvdHRlbS4gVGhpcyBpcyB0aGUgYmFzaWMgaW5pdCBmdW5jdGlvbixcbiAgICAgKiBpdCBjYW4gYmUgdXNlZCwgZXh0ZW5kZWQgb3Igb3ZlcndyaXR0ZW4gYnkgdGhlIGNvbnRlbnQgaXRlbXNcbiAgICAgKlxuICAgICAqIEl0cyBiZWhhdmlvdXIgZGVwZW5kcyBvbiB0aGUgY29udGVudCBpdGVtXG4gICAgICpcbiAgICAgKiBAcGFja2FnZSBwcml2YXRlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfJGluaXQoKSB7XG4gICAgICAgIHZhciBpO1xuICAgICAgICB0aGlzLnNldFNpemUoKTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIHRoaXMuY2hpbGRFbGVtZW50Q29udGFpbmVyLmFwcGVuZCh0aGlzLmNvbnRlbnRJdGVtc1tpXS5lbGVtZW50KTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuaXNJbml0aWFsaXNlZCA9IHRydWU7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ2l0ZW1DcmVhdGVkJyk7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQodGhpcy50eXBlICsgJ0NyZWF0ZWQnKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBFbWl0IGFuIGV2ZW50IHRoYXQgYnViYmxlcyB1cCB0aGUgaXRlbSB0cmVlLlxuICAgICAqXG4gICAgICogQHBhcmFtICAge1N0cmluZ30gbmFtZSBUaGUgbmFtZSBvZiB0aGUgZXZlbnRcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGVtaXRCdWJibGluZ0V2ZW50KG5hbWUpIHtcbiAgICAgICAgdmFyIGV2ZW50ID0gbmV3IEJ1YmJsaW5nRXZlbnQobmFtZSwgdGhpcyk7XG4gICAgICAgIHRoaXMuZW1pdChuYW1lLCBldmVudCk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogUHJpdmF0ZSBtZXRob2QsIGNyZWF0ZXMgYWxsIGNvbnRlbnQgaXRlbXMgZm9yIHRoaXMgbm9kZSBhdCBpbml0aWFsaXNhdGlvbiB0aW1lXG4gICAgICogUExFQVNFIE5PVEUsIHBsZWFzZSBzZWUgYWRkQ2hpbGQgZm9yIGFkZGluZyBjb250ZW50SXRlbXMgYWRkIHJ1bnRpbWVcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqIEBwYXJhbSAgIHtjb25maWd1cmF0aW9uIGl0ZW0gbm9kZX0gY29uZmlnXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfY3JlYXRlQ29udGVudEl0ZW1zKGNvbmZpZykge1xuICAgICAgICB2YXIgb0NvbnRlbnRJdGVtLCBpO1xuXG4gICAgICAgIGlmICghKGNvbmZpZy5jb250ZW50IGluc3RhbmNlb2YgQXJyYXkpKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgQ29uZmlndXJhdGlvbkVycm9yKCdjb250ZW50IG11c3QgYmUgYW4gQXJyYXknLCBjb25maWcpO1xuICAgICAgICB9XG5cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IGNvbmZpZy5jb250ZW50Lmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBvQ29udGVudEl0ZW0gPSB0aGlzLmxheW91dE1hbmFnZXIuY3JlYXRlQ29udGVudEl0ZW0oY29uZmlnLmNvbnRlbnRbaV0sIHRoaXMpO1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXMucHVzaChvQ29udGVudEl0ZW0pO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRXh0ZW5kcyBhbiBpdGVtIGNvbmZpZ3VyYXRpb24gbm9kZSB3aXRoIGRlZmF1bHQgc2V0dGluZ3NcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqIEBwYXJhbSAgIHtjb25maWd1cmF0aW9uIGl0ZW0gbm9kZX0gY29uZmlnXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7Y29uZmlndXJhdGlvbiBpdGVtIG5vZGV9IGV4dGVuZGVkIGNvbmZpZ1xuICAgICAqL1xuICAgIF9leHRlbmRJdGVtTm9kZShjb25maWcpIHtcblxuICAgICAgICBmb3IgKHZhciBrZXkgaW4gaXRlbURlZmF1bHRDb25maWcpIHtcbiAgICAgICAgICAgIGlmIChjb25maWdba2V5XSA9PT0gdW5kZWZpbmVkKSB7XG4gICAgICAgICAgICAgICAgY29uZmlnW2tleV0gPSBpdGVtRGVmYXVsdENvbmZpZ1trZXldO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgcmV0dXJuIGNvbmZpZztcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxsZWQgZm9yIGV2ZXJ5IGV2ZW50IG9uIHRoZSBpdGVtIHRyZWUuIERlY2lkZXMgd2hldGhlciB0aGUgZXZlbnQgaXMgYSBidWJibGluZ1xuICAgICAqIGV2ZW50IGFuZCBwcm9wYWdhdGVzIGl0IHRvIGl0cyBwYXJlbnRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgICB7U3RyaW5nfSBuYW1lIHRoZSBuYW1lIG9mIHRoZSBldmVudFxuICAgICAqIEBwYXJhbSAgIHtCdWJibGluZ0V2ZW50fSBldmVudFxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX3Byb3BhZ2F0ZUV2ZW50KG5hbWUsIGV2ZW50KSB7XG4gICAgICAgIGlmIChldmVudCBpbnN0YW5jZW9mIEJ1YmJsaW5nRXZlbnQgJiZcbiAgICAgICAgICAgIGV2ZW50LmlzUHJvcGFnYXRpb25TdG9wcGVkID09PSBmYWxzZSAmJlxuICAgICAgICAgICAgdGhpcy5pc0luaXRpYWxpc2VkID09PSB0cnVlKSB7XG5cbiAgICAgICAgICAgIC8qKlxuICAgICAgICAgICAgICogSW4gc29tZSBjYXNlcyAoZS5nLiBpZiBhbiBlbGVtZW50IGlzIGNyZWF0ZWQgZnJvbSBhIERyYWdTb3VyY2UpIGl0XG4gICAgICAgICAgICAgKiBkb2Vzbid0IGhhdmUgYSBwYXJlbnQgYW5kIGlzIG5vdCBiZWxvdyByb290LiBJZiB0aGF0J3MgdGhlIGNhc2VcbiAgICAgICAgICAgICAqIHByb3BhZ2F0ZSB0aGUgYnViYmxpbmcgZXZlbnQgZnJvbSB0aGUgdG9wIGxldmVsIG9mIHRoZSBzdWJzdHJlZSBkaXJlY3RseVxuICAgICAgICAgICAgICogdG8gdGhlIGxheW91dE1hbmFnZXJcbiAgICAgICAgICAgICAqL1xuICAgICAgICAgICAgaWYgKHRoaXMuaXNSb290ID09PSBmYWxzZSAmJiB0aGlzLnBhcmVudCkge1xuICAgICAgICAgICAgICAgIHRoaXMucGFyZW50LmVtaXQuYXBwbHkodGhpcy5wYXJlbnQsIEFycmF5LnByb3RvdHlwZS5zbGljZS5jYWxsKGFyZ3VtZW50cywgMCkpO1xuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9zY2hlZHVsZUV2ZW50UHJvcGFnYXRpb25Ub0xheW91dE1hbmFnZXIobmFtZSwgZXZlbnQpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQWxsIHJhdyBldmVudHMgYnViYmxlIHVwIHRvIHRoZSByb290IGVsZW1lbnQuIFNvbWUgZXZlbnRzIHRoYXRcbiAgICAgKiBhcmUgcHJvcGFnYXRlZCB0byAtIGFuZCBlbWl0dGVkIGJ5IC0gdGhlIGxheW91dE1hbmFnZXIgaG93ZXZlciBhcmVcbiAgICAgKiBvbmx5IHN0cmluZy1iYXNlZCwgYmF0Y2hlZCBhbmQgc2FuaXRpemVkIHRvIG1ha2UgdGhlbSBtb3JlIHVzYWJsZVxuICAgICAqXG4gICAgICogQHBhcmFtIHtTdHJpbmd9IG5hbWUgdGhlIG5hbWUgb2YgdGhlIGV2ZW50XG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9zY2hlZHVsZUV2ZW50UHJvcGFnYXRpb25Ub0xheW91dE1hbmFnZXIobmFtZSwgZXZlbnQpIHtcbiAgICAgICAgaWYgKGluZGV4T2YobmFtZSwgdGhpcy5fdGhyb3R0bGVkRXZlbnRzKSA9PT0gLTEpIHtcbiAgICAgICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci5lbWl0KG5hbWUsIGV2ZW50Lm9yaWdpbik7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICBpZiAodGhpcy5fcGVuZGluZ0V2ZW50UHJvcGFnYXRpb25zW25hbWVdICE9PSB0cnVlKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5fcGVuZGluZ0V2ZW50UHJvcGFnYXRpb25zW25hbWVdID0gdHJ1ZTtcbiAgICAgICAgICAgICAgICBhbmltRnJhbWUoZm5CaW5kKHRoaXMuX3Byb3BhZ2F0ZUV2ZW50VG9MYXlvdXRNYW5hZ2VyLCB0aGlzLCBbbmFtZSwgZXZlbnRdKSk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxiYWNrIGZvciBldmVudHMgc2NoZWR1bGVkIGJ5IF9zY2hlZHVsZUV2ZW50UHJvcGFnYXRpb25Ub0xheW91dE1hbmFnZXJcbiAgICAgKlxuICAgICAqIEBwYXJhbSB7U3RyaW5nfSBuYW1lIHRoZSBuYW1lIG9mIHRoZSBldmVudFxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfcHJvcGFnYXRlRXZlbnRUb0xheW91dE1hbmFnZXIobmFtZSwgZXZlbnQpIHtcbiAgICAgICAgdGhpcy5fcGVuZGluZ0V2ZW50UHJvcGFnYXRpb25zW25hbWVdID0gZmFsc2U7XG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci5lbWl0KG5hbWUsIGV2ZW50KTtcbiAgICB9XG59XG4iLCJpbXBvcnQgQWJzdHJhY3RDb250ZW50SXRlbSBmcm9tICcuLi9pdGVtcy9BYnN0cmFjdENvbnRlbnRJdGVtJ1xuaW1wb3J0IEl0ZW1Db250YWluZXIgZnJvbSAnLi4vY29udGFpbmVyL0l0ZW1Db250YWluZXInXG5pbXBvcnQgUmVhY3RDb21wb25lbnRIYW5kbGVyIGZyb20gJy4uL3V0aWxzL1JlYWN0Q29tcG9uZW50SGFuZGxlcidcbmltcG9ydCAkIGZyb20gJ2pxdWVyeSdcbi8qKlxuICogQHBhcmFtIHtbdHlwZV19IGxheW91dE1hbmFnZXIgW2Rlc2NyaXB0aW9uXVxuICogQHBhcmFtIHtbdHlwZV19IGNvbmZpZyAgICAgIFtkZXNjcmlwdGlvbl1cbiAqIEBwYXJhbSB7W3R5cGVdfSBwYXJlbnQgICAgICAgIFtkZXNjcmlwdGlvbl1cbiAqL1xuXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIENvbXBvbmVudCBleHRlbmRzIEFic3RyYWN0Q29udGVudEl0ZW0ge1xuICAgIGNvbnN0cnVjdG9yKGxheW91dE1hbmFnZXIsIGNvbmZpZywgcGFyZW50KSB7XG5cbiAgICAgICAgc3VwZXIobGF5b3V0TWFuYWdlciwgY29uZmlnLCBwYXJlbnQpO1xuXG4gICAgICAgIHZhciBDb21wb25lbnRDb25zdHJ1Y3RvciA9IGxheW91dE1hbmFnZXIuaXNSZWFjdENvbmZpZyhjb25maWcpID8gUmVhY3RDb21wb25lbnRIYW5kbGVyIDogbGF5b3V0TWFuYWdlci5nZXRDb21wb25lbnQoY29uZmlnKSxcbiAgICAgICAgICAgIGNvbXBvbmVudENvbmZpZyA9ICQuZXh0ZW5kKHRydWUsIHt9LCB0aGlzLmNvbmZpZy5jb21wb25lbnRTdGF0ZSB8fCB7fSk7XG5cbiAgICAgICAgY29tcG9uZW50Q29uZmlnLmNvbXBvbmVudE5hbWUgPSB0aGlzLmNvbmZpZy5jb21wb25lbnROYW1lO1xuICAgICAgICB0aGlzLmNvbXBvbmVudE5hbWUgPSB0aGlzLmNvbmZpZy5jb21wb25lbnROYW1lO1xuXG4gICAgICAgIGlmICh0aGlzLmNvbmZpZy50aXRsZSA9PT0gJycpIHtcbiAgICAgICAgICAgIHRoaXMuY29uZmlnLnRpdGxlID0gdGhpcy5jb25maWcuY29tcG9uZW50TmFtZTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuaXNDb21wb25lbnQgPSB0cnVlO1xuICAgICAgICB0aGlzLmNvbnRhaW5lciA9IG5ldyBJdGVtQ29udGFpbmVyKHRoaXMuY29uZmlnLCB0aGlzLCBsYXlvdXRNYW5hZ2VyKTtcbiAgICAgICAgdGhpcy5pbnN0YW5jZSA9IG5ldyBDb21wb25lbnRDb25zdHJ1Y3Rvcih0aGlzLmNvbnRhaW5lciwgY29tcG9uZW50Q29uZmlnKTtcbiAgICAgICAgdGhpcy5lbGVtZW50ID0gdGhpcy5jb250YWluZXIuX2VsZW1lbnQ7XG4gICAgfVxuXG4gICAgY2xvc2UoKSB7XG4gICAgICAgIHRoaXMucGFyZW50LnJlbW92ZUNoaWxkKHRoaXMpO1xuICAgIH1cblxuICAgIHNldFNpemUoKSB7XG4gICAgICAgIGlmICh0aGlzLmVsZW1lbnQuY3NzKCdkaXNwbGF5JykgIT09ICdub25lJykge1xuICAgICAgICAgICAgLy8gRG8gbm90IHVwZGF0ZSBzaXplIG9mIGhpZGRlbiBjb21wb25lbnRzIHRvIHByZXZlbnQgdW53YW50ZWQgcmVmbG93c1xuICAgICAgICAgICAgdGhpcy5jb250YWluZXIuXyRzZXRTaXplKHRoaXMuZWxlbWVudC53aWR0aCgpLCB0aGlzLmVsZW1lbnQuaGVpZ2h0KCkpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgXyRpbml0KCkge1xuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS5fJGluaXQuY2FsbCh0aGlzKTtcbiAgICAgICAgdGhpcy5jb250YWluZXIuZW1pdCgnb3BlbicpO1xuICAgIH1cblxuICAgIF8kaGlkZSgpIHtcbiAgICAgICAgdGhpcy5jb250YWluZXIuaGlkZSgpO1xuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS5fJGhpZGUuY2FsbCh0aGlzKTtcbiAgICB9XG5cbiAgICBfJHNob3coKSB7XG4gICAgICAgIHRoaXMuY29udGFpbmVyLnNob3coKTtcbiAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUuXyRzaG93LmNhbGwodGhpcyk7XG4gICAgfVxuXG4gICAgXyRzaG93bigpIHtcbiAgICAgICAgdGhpcy5jb250YWluZXIuc2hvd24oKTtcbiAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUuXyRzaG93bi5jYWxsKHRoaXMpO1xuICAgIH1cblxuICAgIF8kZGVzdHJveSgpIHtcbiAgICAgICAgdGhpcy5jb250YWluZXIuZW1pdCgnZGVzdHJveScsIHRoaXMpO1xuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS5fJGRlc3Ryb3kuY2FsbCh0aGlzKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBEcmFnZ2luZyBvbnRvIGEgY29tcG9uZW50IGRpcmVjdGx5IGlzIG5vdCBhbiBvcHRpb25cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIG51bGxcbiAgICAgKi9cbiAgICBfJGdldEFyZWEoKSB7XG4gICAgICAgIHJldHVybiBudWxsO1xuICAgIH1cbn1cbiIsImltcG9ydCBBYnN0cmFjdENvbnRlbnRJdGVtIGZyb20gJy4uL2l0ZW1zL0Fic3RyYWN0Q29udGVudEl0ZW0nXG5pbXBvcnQgUm93T3JDb2x1bW4gZnJvbSAnLi4vaXRlbXMvUm93T3JDb2x1bW4nXG5pbXBvcnQgJCBmcm9tICdqcXVlcnknXG5cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgUm9vdCBleHRlbmRzIEFic3RyYWN0Q29udGVudEl0ZW0ge1xuICAgIGNvbnN0cnVjdG9yKGxheW91dE1hbmFnZXIsIGNvbmZpZywgY29udGFpbmVyRWxlbWVudCkge1xuICAgICAgXG4gICAgICAgIHN1cGVyKGxheW91dE1hbmFnZXIsIGNvbmZpZywgbnVsbCk7XG5cbiAgICAgICAgdGhpcy5pc1Jvb3QgPSB0cnVlO1xuICAgICAgICB0aGlzLnR5cGUgPSAncm9vdCc7XG4gICAgICAgIHRoaXMuZWxlbWVudCA9ICQoJzxkaXYgY2xhc3M9XCJsbV9nb2xkZW5sYXlvdXQgbG1faXRlbSBsbV9yb290XCI+PC9kaXY+Jyk7XG4gICAgICAgIHRoaXMuY2hpbGRFbGVtZW50Q29udGFpbmVyID0gdGhpcy5lbGVtZW50O1xuICAgICAgICB0aGlzLl9jb250YWluZXJFbGVtZW50ID0gY29udGFpbmVyRWxlbWVudDtcbiAgICAgICAgdGhpcy5fY29udGFpbmVyRWxlbWVudC5hcHBlbmQodGhpcy5lbGVtZW50KTtcbiAgICB9XG5cbiAgICBhZGRDaGlsZChjb250ZW50SXRlbSkge1xuICAgICAgICBpZiAodGhpcy5jb250ZW50SXRlbXMubGVuZ3RoID4gMCkge1xuICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdSb290IG5vZGUgY2FuIG9ubHkgaGF2ZSBhIHNpbmdsZSBjaGlsZCcpO1xuICAgICAgICB9XG5cbiAgICAgICAgY29udGVudEl0ZW0gPSB0aGlzLmxheW91dE1hbmFnZXIuXyRub3JtYWxpemVDb250ZW50SXRlbShjb250ZW50SXRlbSwgdGhpcyk7XG4gICAgICAgIHRoaXMuY2hpbGRFbGVtZW50Q29udGFpbmVyLmFwcGVuZChjb250ZW50SXRlbS5lbGVtZW50KTtcbiAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUuYWRkQ2hpbGQuY2FsbCh0aGlzLCBjb250ZW50SXRlbSk7XG5cbiAgICAgICAgdGhpcy5jYWxsRG93bndhcmRzKCdzZXRTaXplJyk7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgIH1cblxuICAgIHNldFNpemUod2lkdGgsIGhlaWdodCkge1xuICAgICAgICB3aWR0aCA9ICh0eXBlb2Ygd2lkdGggPT09ICd1bmRlZmluZWQnKSA/IHRoaXMuX2NvbnRhaW5lckVsZW1lbnQud2lkdGgoKSA6IHdpZHRoO1xuICAgICAgICBoZWlnaHQgPSAodHlwZW9mIGhlaWdodCA9PT0gJ3VuZGVmaW5lZCcpID8gdGhpcy5fY29udGFpbmVyRWxlbWVudC5oZWlnaHQoKSA6IGhlaWdodDtcblxuICAgICAgICB0aGlzLmVsZW1lbnQud2lkdGgod2lkdGgpO1xuICAgICAgICB0aGlzLmVsZW1lbnQuaGVpZ2h0KGhlaWdodCk7XG5cbiAgICAgICAgLypcbiAgICAgICAgICogUm9vdCBjYW4gYmUgZW1wdHlcbiAgICAgICAgICovXG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtc1swXSkge1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbMF0uZWxlbWVudC53aWR0aCh3aWR0aCk7XG4gICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1swXS5lbGVtZW50LmhlaWdodChoZWlnaHQpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgXyRoaWdobGlnaHREcm9wWm9uZSh4LCB5LCBhcmVhKSB7XG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci50YWJEcm9wUGxhY2Vob2xkZXIucmVtb3ZlKCk7XG4gICAgICAgIEFic3RyYWN0Q29udGVudEl0ZW0ucHJvdG90eXBlLl8kaGlnaGxpZ2h0RHJvcFpvbmUuYXBwbHkodGhpcywgYXJndW1lbnRzKTtcbiAgICB9XG5cbiAgICBfJG9uRHJvcChjb250ZW50SXRlbSwgYXJlYSkge1xuICAgICAgICB2YXIgc3RhY2s7XG5cbiAgICAgICAgaWYgKGNvbnRlbnRJdGVtLmlzQ29tcG9uZW50KSB7XG4gICAgICAgICAgICBzdGFjayA9IHRoaXMubGF5b3V0TWFuYWdlci5jcmVhdGVDb250ZW50SXRlbSh7XG4gICAgICAgICAgICAgICAgdHlwZTogJ3N0YWNrJyxcbiAgICAgICAgICAgICAgICBoZWFkZXI6IGNvbnRlbnRJdGVtLmNvbmZpZy5oZWFkZXIgfHwge31cbiAgICAgICAgICAgIH0sIHRoaXMpO1xuICAgICAgICAgICAgc3RhY2suXyRpbml0KCk7XG4gICAgICAgICAgICBzdGFjay5hZGRDaGlsZChjb250ZW50SXRlbSk7XG4gICAgICAgICAgICBjb250ZW50SXRlbSA9IHN0YWNrO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKCF0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGgpIHtcbiAgICAgICAgICAgIHRoaXMuYWRkQ2hpbGQoY29udGVudEl0ZW0pO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgLypcbiAgICAgICAgICAgICAqIElmIHRoZSBjb250ZW50SXRlbSB0aGF0J3MgYmVpbmcgZHJvcHBlZCBpcyBub3QgZHJvcHBlZCBvbiBhIFN0YWNrIChjYXNlcyB3aGljaCBqdXN0IHBhc3NlZCBhYm92ZSBhbmQgXG4gICAgICAgICAgICAgKiB3aGljaCB3b3VsZCB3cmFwIHRoZSBjb250ZW50SXRlbSBpbiBhIFN0YWNrKSB3ZSBuZWVkIHRvIGNoZWNrIHdoZXRoZXIgY29udGVudEl0ZW0gaXMgYSBSb3dPckNvbHVtbi5cbiAgICAgICAgICAgICAqIElmIGl0IGlzLCB3ZSBuZWVkIHRvIHJlLXdyYXAgaXQgaW4gYSBTdGFjayBsaWtlIGl0IHdhcyB3aGVuIGl0IHdhcyBkcmFnZ2VkIGJ5IGl0cyBUYWIgKGl0IHdhcyBkcmFnZ2VkISkuXG4gICAgICAgICAgICAgKi9cbiAgICAgICAgICAgIGlmKGNvbnRlbnRJdGVtLmNvbmZpZy50eXBlID09PSAncm93JyB8fCBjb250ZW50SXRlbS5jb25maWcudHlwZSA9PT0gJ2NvbHVtbicpe1xuICAgICAgICAgICAgICAgIHN0YWNrID0gdGhpcy5sYXlvdXRNYW5hZ2VyLmNyZWF0ZUNvbnRlbnRJdGVtKHtcbiAgICAgICAgICAgICAgICAgICAgdHlwZTogJ3N0YWNrJ1xuICAgICAgICAgICAgICAgIH0sIHRoaXMpXG4gICAgICAgICAgICAgICAgc3RhY2suYWRkQ2hpbGQoY29udGVudEl0ZW0pXG4gICAgICAgICAgICAgICAgY29udGVudEl0ZW0gPSBzdGFja1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICB2YXIgdHlwZSA9IGFyZWEuc2lkZVswXSA9PSAneCcgPyAncm93JyA6ICdjb2x1bW4nO1xuICAgICAgICAgICAgdmFyIGRpbWVuc2lvbiA9IGFyZWEuc2lkZVswXSA9PSAneCcgPyAnd2lkdGgnIDogJ2hlaWdodCc7XG4gICAgICAgICAgICB2YXIgaW5zZXJ0QmVmb3JlID0gYXJlYS5zaWRlWzFdID09ICcyJztcbiAgICAgICAgICAgIHZhciBjb2x1bW4gPSB0aGlzLmNvbnRlbnRJdGVtc1swXTtcbiAgICAgICAgICAgIGlmICghKGNvbHVtbiBpbnN0YW5jZW9mIFJvd09yQ29sdW1uKSB8fCBjb2x1bW4udHlwZSAhPSB0eXBlKSB7XG4gICAgICAgICAgICAgICAgdmFyIHJvd09yQ29sdW1uID0gdGhpcy5sYXlvdXRNYW5hZ2VyLmNyZWF0ZUNvbnRlbnRJdGVtKHtcbiAgICAgICAgICAgICAgICAgICAgdHlwZTogdHlwZVxuICAgICAgICAgICAgICAgIH0sIHRoaXMpO1xuICAgICAgICAgICAgICAgIHRoaXMucmVwbGFjZUNoaWxkKGNvbHVtbiwgcm93T3JDb2x1bW4pO1xuICAgICAgICAgICAgICAgIHJvd09yQ29sdW1uLmFkZENoaWxkKGNvbnRlbnRJdGVtLCBpbnNlcnRCZWZvcmUgPyAwIDogdW5kZWZpbmVkLCB0cnVlKTtcbiAgICAgICAgICAgICAgICByb3dPckNvbHVtbi5hZGRDaGlsZChjb2x1bW4sIGluc2VydEJlZm9yZSA/IHVuZGVmaW5lZCA6IDAsIHRydWUpO1xuICAgICAgICAgICAgICAgIGNvbHVtbi5jb25maWdbZGltZW5zaW9uXSA9IDUwO1xuICAgICAgICAgICAgICAgIGNvbnRlbnRJdGVtLmNvbmZpZ1tkaW1lbnNpb25dID0gNTA7XG4gICAgICAgICAgICAgICAgcm93T3JDb2x1bW4uY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICB2YXIgc2liYmxpbmcgPSBjb2x1bW4uY29udGVudEl0ZW1zW2luc2VydEJlZm9yZSA/IDAgOiBjb2x1bW4uY29udGVudEl0ZW1zLmxlbmd0aCAtIDFdXG4gICAgICAgICAgICAgICAgY29sdW1uLmFkZENoaWxkKGNvbnRlbnRJdGVtLCBpbnNlcnRCZWZvcmUgPyAwIDogdW5kZWZpbmVkLCB0cnVlKTtcbiAgICAgICAgICAgICAgICBzaWJibGluZy5jb25maWdbZGltZW5zaW9uXSAqPSAwLjU7XG4gICAgICAgICAgICAgICAgY29udGVudEl0ZW0uY29uZmlnW2RpbWVuc2lvbl0gPSBzaWJibGluZy5jb25maWdbZGltZW5zaW9uXTtcbiAgICAgICAgICAgICAgICBjb2x1bW4uY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG4gICAgfVxufVxuIiwiaW1wb3J0IEFic3RyYWN0Q29udGVudEl0ZW0gZnJvbSAnLi4vaXRlbXMvQWJzdHJhY3RDb250ZW50SXRlbSdcbmltcG9ydCBTdGFjayBmcm9tICcuLi9pdGVtcy9TdGFjaydcbmltcG9ydCBTcGxpdHRlciBmcm9tICcuLi9jb250cm9scy9TcGxpdHRlcidcbmltcG9ydCB7XG4gICAgZm5CaW5kLFxuICAgIGFuaW1GcmFtZSxcbiAgICBpbmRleE9mXG59IGZyb20gJy4uL3V0aWxzL3V0aWxzJ1xuaW1wb3J0ICQgZnJvbSAnanF1ZXJ5J1xuXG5cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgUm93T3JDb2x1bW4gZXh0ZW5kcyBBYnN0cmFjdENvbnRlbnRJdGVtIHtcbiAgICBjb25zdHJ1Y3Rvcihpc0NvbHVtbiwgbGF5b3V0TWFuYWdlciwgY29uZmlnLCBwYXJlbnQpIHtcbiAgICAgIFxuICAgICAgICBzdXBlcihsYXlvdXRNYW5hZ2VyLCBjb25maWcsIHBhcmVudCk7XG5cbiAgICAgICAgdGhpcy5pc1JvdyA9ICFpc0NvbHVtbjtcbiAgICAgICAgdGhpcy5pc0NvbHVtbiA9IGlzQ29sdW1uO1xuXG4gICAgICAgIHRoaXMuZWxlbWVudCA9ICQoJzxkaXYgY2xhc3M9XCJsbV9pdGVtIGxtXycgKyAoaXNDb2x1bW4gPyAnY29sdW1uJyA6ICdyb3cnKSArICdcIj48L2Rpdj4nKTtcbiAgICAgICAgdGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIgPSB0aGlzLmVsZW1lbnQ7XG4gICAgICAgIHRoaXMuX3NwbGl0dGVyU2l6ZSA9IGxheW91dE1hbmFnZXIuY29uZmlnLmRpbWVuc2lvbnMuYm9yZGVyV2lkdGg7XG4gICAgICAgIHRoaXMuX3NwbGl0dGVyR3JhYlNpemUgPSBsYXlvdXRNYW5hZ2VyLmNvbmZpZy5kaW1lbnNpb25zLmJvcmRlckdyYWJXaWR0aDtcbiAgICAgICAgdGhpcy5faXNDb2x1bW4gPSBpc0NvbHVtbjtcbiAgICAgICAgdGhpcy5fZGltZW5zaW9uID0gaXNDb2x1bW4gPyAnaGVpZ2h0JyA6ICd3aWR0aCc7XG4gICAgICAgIHRoaXMuX3NwbGl0dGVyID0gW107XG4gICAgICAgIHRoaXMuX3NwbGl0dGVyUG9zaXRpb24gPSBudWxsO1xuICAgICAgICB0aGlzLl9zcGxpdHRlck1pblBvc2l0aW9uID0gbnVsbDtcbiAgICAgICAgdGhpcy5fc3BsaXR0ZXJNYXhQb3NpdGlvbiA9IG51bGw7XG4gICAgfVxuXG5cbiAgICAvKipcbiAgICAgKiBBZGQgYSBuZXcgY29udGVudEl0ZW0gdG8gdGhlIFJvdyBvciBDb2x1bW5cbiAgICAgKlxuICAgICAqIEBwYXJhbSB7QWJzdHJhY3RDb250ZW50SXRlbX0gY29udGVudEl0ZW1cbiAgICAgKiBAcGFyYW0ge1tpbnRdfSBpbmRleCBUaGUgcG9zaXRpb24gb2YgdGhlIG5ldyBpdGVtIHdpdGhpbiB0aGUgUm93IG9yIENvbHVtbi5cbiAgICAgKiAgICAgICAgICAgICAgICAgICAgICBJZiBubyBpbmRleCBpcyBwcm92aWRlZCB0aGUgaXRlbSB3aWxsIGJlIGFkZGVkIHRvIHRoZSBlbmRcbiAgICAgKiBAcGFyYW0ge1tib29sXX0gXyRzdXNwZW5kUmVzaXplIElmIHRydWUgdGhlIGl0ZW1zIHdvbid0IGJlIHJlc2l6ZWQuIFRoaXMgd2lsbCBsZWF2ZSB0aGUgaXRlbSBpblxuICAgICAqICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYW4gaW5jb25zaXN0ZW50IHN0YXRlIGFuZCBpcyBvbmx5IGludGVuZGVkIHRvIGJlIHVzZWQgaWYgbXVsdGlwbGVcbiAgICAgKiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGNoaWxkcmVuIG5lZWQgdG8gYmUgYWRkZWQgaW4gb25lIGdvIGFuZCByZXNpemUgaXMgY2FsbGVkIGFmdGVyd2FyZHNcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIGFkZENoaWxkKGNvbnRlbnRJdGVtLCBpbmRleCwgXyRzdXNwZW5kUmVzaXplKSB7XG5cbiAgICAgICAgdmFyIG5ld0l0ZW1TaXplLCBpdGVtU2l6ZSwgaSwgc3BsaXR0ZXJFbGVtZW50O1xuXG4gICAgICAgIGNvbnRlbnRJdGVtID0gdGhpcy5sYXlvdXRNYW5hZ2VyLl8kbm9ybWFsaXplQ29udGVudEl0ZW0oY29udGVudEl0ZW0sIHRoaXMpO1xuXG4gICAgICAgIGlmIChpbmRleCA9PT0gdW5kZWZpbmVkKSB7XG4gICAgICAgICAgICBpbmRleCA9IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aDtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggPiAwKSB7XG4gICAgICAgICAgICBzcGxpdHRlckVsZW1lbnQgPSB0aGlzLl9jcmVhdGVTcGxpdHRlcihNYXRoLm1heCgwLCBpbmRleCAtIDEpKS5lbGVtZW50O1xuXG4gICAgICAgICAgICBpZiAoaW5kZXggPiAwKSB7XG4gICAgICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbaW5kZXggLSAxXS5lbGVtZW50LmFmdGVyKHNwbGl0dGVyRWxlbWVudCk7XG4gICAgICAgICAgICAgICAgc3BsaXR0ZXJFbGVtZW50LmFmdGVyKGNvbnRlbnRJdGVtLmVsZW1lbnQpO1xuICAgICAgICAgICAgICAgIGlmICh0aGlzLl9pc0RvY2tlZChpbmRleCAtIDEpKSB7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMuX3NwbGl0dGVyW2luZGV4IC0gMV0uZWxlbWVudC5oaWRlKCk7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMuX3NwbGl0dGVyW2luZGV4XS5lbGVtZW50LnNob3coKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zWzBdLmVsZW1lbnQuYmVmb3JlKHNwbGl0dGVyRWxlbWVudCk7XG4gICAgICAgICAgICAgICAgc3BsaXR0ZXJFbGVtZW50LmJlZm9yZShjb250ZW50SXRlbS5lbGVtZW50KTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRoaXMuY2hpbGRFbGVtZW50Q29udGFpbmVyLmFwcGVuZChjb250ZW50SXRlbS5lbGVtZW50KTtcbiAgICAgICAgfVxuXG4gICAgICAgIEFic3RyYWN0Q29udGVudEl0ZW0ucHJvdG90eXBlLmFkZENoaWxkLmNhbGwodGhpcywgY29udGVudEl0ZW0sIGluZGV4KTtcblxuICAgICAgICBuZXdJdGVtU2l6ZSA9ICgxIC8gdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoKSAqIDEwMDtcblxuICAgICAgICBpZiAoXyRzdXNwZW5kUmVzaXplID09PSB0cnVlKSB7XG4gICAgICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIGZvciAoaSA9IDA7IGkgPCB0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zW2ldID09PSBjb250ZW50SXRlbSkge1xuICAgICAgICAgICAgICAgIGNvbnRlbnRJdGVtLmNvbmZpZ1t0aGlzLl9kaW1lbnNpb25dID0gbmV3SXRlbVNpemU7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIGl0ZW1TaXplID0gdGhpcy5jb250ZW50SXRlbXNbaV0uY29uZmlnW3RoaXMuX2RpbWVuc2lvbl0gKj0gKDEwMCAtIG5ld0l0ZW1TaXplKSAvIDEwMDtcbiAgICAgICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSA9IGl0ZW1TaXplO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5jYWxsRG93bndhcmRzKCdzZXRTaXplJyk7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgICAgICB0aGlzLl92YWxpZGF0ZURvY2tpbmcoKTtcbiAgICB9XG5cblxuICAgIC8qKlxuICAgICAqIFVuZGlzcGxheXMgYSBjaGlsZCBvZiB0aGlzIGVsZW1lbnRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBjb250ZW50SXRlbVxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgdW5kaXNwbGF5Q2hpbGQoY29udGVudEl0ZW0pIHtcbiAgICAgICAgdmFyIHVuZGlzcGxheWVkSXRlbVNpemUgPSBjb250ZW50SXRlbS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSxcbiAgICAgICAgICAgIGluZGV4ID0gaW5kZXhPZihjb250ZW50SXRlbSwgdGhpcy5jb250ZW50SXRlbXMpLFxuICAgICAgICAgICAgc3BsaXR0ZXJJbmRleCA9IE1hdGgubWF4KGluZGV4IC0gMSwgMCksXG4gICAgICAgICAgICBpLFxuICAgICAgICAgICAgY2hpbGRJdGVtO1xuXG4gICAgICAgIGlmIChpbmRleCA9PT0gLTEpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ2FuXFwndCB1bmRpc3BsYXkgY2hpbGQuIENvbnRlbnRJdGVtIGlzIG5vdCBjaGlsZCBvZiB0aGlzIFJvdyBvciBDb2x1bW4nKTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBIaWRlIHRoZSBzcGxpdHRlciBiZWZvcmUgdGhlIGl0ZW0gb3IgYWZ0ZXIgaWYgdGhlIGl0ZW0gaGFwcGVuc1xuICAgICAgICAgKiB0byBiZSB0aGUgZmlyc3QgaW4gdGhlIHJvdy9jb2x1bW5cbiAgICAgICAgICovXG4gICAgICAgIGlmICh0aGlzLl9zcGxpdHRlcltzcGxpdHRlckluZGV4XSkge1xuICAgICAgICAgICAgdGhpcy5fc3BsaXR0ZXJbc3BsaXR0ZXJJbmRleF0uZWxlbWVudC5oaWRlKCk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoc3BsaXR0ZXJJbmRleCA8IHRoaXMuX3NwbGl0dGVyLmxlbmd0aCkge1xuICAgICAgICAgICAgaWYgKHRoaXMuX2lzRG9ja2VkKHNwbGl0dGVySW5kZXgpKVxuICAgICAgICAgICAgICAgIHRoaXMuX3NwbGl0dGVyW3NwbGl0dGVySW5kZXhdLmVsZW1lbnQuaGlkZSgpO1xuICAgICAgICB9XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIEFsbG9jYXRlIHRoZSBzcGFjZSB0aGF0IHRoZSBoaWRkZW4gaXRlbSBvY2N1cGllZCB0byB0aGUgcmVtYWluaW5nIGl0ZW1zXG4gICAgICAgICAqL1xuICAgICAgICB2YXIgZG9ja2VkID0gdGhpcy5faXNEb2NrZWQoKTtcbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBpZiAodGhpcy5jb250ZW50SXRlbXNbaV0gIT09IGNvbnRlbnRJdGVtKSB7XG4gICAgICAgICAgICAgICAgaWYgKCF0aGlzLl9pc0RvY2tlZChpKSlcbiAgICAgICAgICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbaV0uY29uZmlnW3RoaXMuX2RpbWVuc2lvbl0gKz0gdW5kaXNwbGF5ZWRJdGVtU2l6ZSAvICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggLSAxIC0gZG9ja2VkKTsgICAgICAgICAgICAgICAgXG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSA9IDBcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgIGlmKHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA9PT0gMSl7XG4gICAgICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS51bmRpc3BsYXlDaGlsZC5jYWxsKHRoaXMsIGNvbnRlbnRJdGVtKTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICB9XG5cblxuICAgIC8qKlxuICAgICAqIFJlbW92ZXMgYSBjaGlsZCBvZiB0aGlzIGVsZW1lbnRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBjb250ZW50SXRlbVxuICAgICAqIEBwYXJhbSAgIHtib29sZWFufSBrZWVwQ2hpbGQgICBJZiB0cnVlIHRoZSBjaGlsZCB3aWxsIGJlIHJlbW92ZWQsIGJ1dCBub3QgZGVzdHJveWVkXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICByZW1vdmVDaGlsZChjb250ZW50SXRlbSwga2VlcENoaWxkKSB7XG4gICAgICAgIHZhciByZW1vdmVkSXRlbVNpemUgPSBjb250ZW50SXRlbS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSxcbiAgICAgICAgICAgIGluZGV4ID0gaW5kZXhPZihjb250ZW50SXRlbSwgdGhpcy5jb250ZW50SXRlbXMpLFxuICAgICAgICAgICAgc3BsaXR0ZXJJbmRleCA9IE1hdGgubWF4KGluZGV4IC0gMSwgMCksXG4gICAgICAgICAgICBpLFxuICAgICAgICAgICAgY2hpbGRJdGVtO1xuICAgICAgICBpZiAoaW5kZXggPT09IC0xKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0NhblxcJ3QgcmVtb3ZlIGNoaWxkLiBDb250ZW50SXRlbSBpcyBub3QgY2hpbGQgb2YgdGhpcyBSb3cgb3IgQ29sdW1uJyk7XG4gICAgICAgIH1cblxuICAgICAgICAvKipcbiAgICAgICAgICogUmVtb3ZlIHRoZSBzcGxpdHRlciBiZWZvcmUgdGhlIGl0ZW0gb3IgYWZ0ZXIgaWYgdGhlIGl0ZW0gaGFwcGVuc1xuICAgICAgICAgKiB0byBiZSB0aGUgZmlyc3QgaW4gdGhlIHJvdy9jb2x1bW5cbiAgICAgICAgICovXG4gICAgICAgIGlmICh0aGlzLl9zcGxpdHRlcltzcGxpdHRlckluZGV4XSkge1xuICAgICAgICAgICAgdGhpcy5fc3BsaXR0ZXJbc3BsaXR0ZXJJbmRleF0uXyRkZXN0cm95KCk7XG4gICAgICAgICAgICB0aGlzLl9zcGxpdHRlci5zcGxpY2Uoc3BsaXR0ZXJJbmRleCwgMSk7XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoc3BsaXR0ZXJJbmRleCA8IHRoaXMuX3NwbGl0dGVyLmxlbmd0aCkge1xuICAgICAgICAgICAgaWYgKHRoaXMuX2lzRG9ja2VkKHNwbGl0dGVySW5kZXgpKVxuICAgICAgICAgICAgICAgIHRoaXMuX3NwbGl0dGVyW3NwbGl0dGVySW5kZXhdLmVsZW1lbnQuaGlkZSgpO1xuICAgICAgICB9XG4gICAgICAgIC8qKlxuICAgICAgICAgKiBBbGxvY2F0ZSB0aGUgc3BhY2UgdGhhdCB0aGUgcmVtb3ZlZCBpdGVtIG9jY3VwaWVkIHRvIHRoZSByZW1haW5pbmcgaXRlbXNcbiAgICAgICAgICovXG4gICAgICAgIHZhciBkb2NrZWQgPSB0aGlzLl9pc0RvY2tlZCgpO1xuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtc1tpXSAhPT0gY29udGVudEl0ZW0pIHtcbiAgICAgICAgICAgICAgICBpZiAoIXRoaXMuX2lzRG9ja2VkKGkpKVxuICAgICAgICAgICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSArPSByZW1vdmVkSXRlbVNpemUgLyAodGhpcy5jb250ZW50SXRlbXMubGVuZ3RoIC0gMSAtIGRvY2tlZCk7XG5cbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgIEFic3RyYWN0Q29udGVudEl0ZW0ucHJvdG90eXBlLnJlbW92ZUNoaWxkLmNhbGwodGhpcywgY29udGVudEl0ZW0sIGtlZXBDaGlsZCk7XG5cbiAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA9PT0gMSAmJiB0aGlzLmNvbmZpZy5pc0Nsb3NhYmxlID09PSB0cnVlKSB7XG4gICAgICAgICAgICBjaGlsZEl0ZW0gPSB0aGlzLmNvbnRlbnRJdGVtc1swXTtcbiAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zID0gW107XG4gICAgICAgICAgICB0aGlzLnBhcmVudC5yZXBsYWNlQ2hpbGQodGhpcywgY2hpbGRJdGVtLCB0cnVlKTtcbiAgICAgICAgICAgIHRoaXMuX3ZhbGlkYXRlRG9ja2luZyh0aGlzLnBhcmVudCk7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICB0aGlzLmNhbGxEb3dud2FyZHMoJ3NldFNpemUnKTtcbiAgICAgICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgICAgICAgICAgdGhpcy5fdmFsaWRhdGVEb2NraW5nKCk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBSZXBsYWNlcyBhIGNoaWxkIG9mIHRoaXMgUm93IG9yIENvbHVtbiB3aXRoIGFub3RoZXIgY29udGVudEl0ZW1cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBvbGRDaGlsZFxuICAgICAqIEBwYXJhbSAgIHtBYnN0cmFjdENvbnRlbnRJdGVtfSBuZXdDaGlsZFxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgcmVwbGFjZUNoaWxkKG9sZENoaWxkLCBuZXdDaGlsZCkge1xuICAgICAgICB2YXIgc2l6ZSA9IG9sZENoaWxkLmNvbmZpZ1t0aGlzLl9kaW1lbnNpb25dO1xuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS5yZXBsYWNlQ2hpbGQuY2FsbCh0aGlzLCBvbGRDaGlsZCwgbmV3Q2hpbGQpO1xuICAgICAgICBuZXdDaGlsZC5jb25maWdbdGhpcy5fZGltZW5zaW9uXSA9IHNpemU7XG4gICAgICAgIHRoaXMuY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxsZWQgd2hlbmV2ZXIgdGhlIGRpbWVuc2lvbnMgb2YgdGhpcyBpdGVtIG9yIG9uZSBvZiBpdHMgcGFyZW50cyBjaGFuZ2VcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIHNldFNpemUoKSB7XG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggPiAwKSB7XG4gICAgICAgICAgICB0aGlzLl9jYWxjdWxhdGVSZWxhdGl2ZVNpemVzKCk7XG4gICAgICAgICAgICB0aGlzLl9zZXRBYnNvbHV0ZVNpemVzKCk7XG4gICAgICAgIH1cbiAgICAgICAgdGhpcy5lbWl0QnViYmxpbmdFdmVudCgnc3RhdGVDaGFuZ2VkJyk7XG4gICAgICAgIHRoaXMuZW1pdCgncmVzaXplJyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRG9jayBvciB1bmRvY2sgYSBjaGlsZCBpZiBpdCBwb3NpaWJsZVxuICAgICAqXG4gICAgICogQHBhcmFtICAge0Fic3RyYWN0Q29udGVudEl0ZW19IGNvbnRlbnRJdGVtXG4gICAgICogQHBhcmFtICAge0Jvb2xlYW59IG1vZGUgb3IgdG9nZ2xlIGlmIHVuZGVmaW5lZFxuICAgICAqIEBwYXJhbSAgIHtCb29sZWFufSBjb2xsYXBzZWQgYWZ0ZXIgZG9ja2luZ1xuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgZG9jayhjb250ZW50SXRlbSwgbW9kZSwgY29sbGFwc2VkKSB7XG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggPT09IDEpXG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0NhblxcJ3QgZG9jayBjaGlsZCB3aGVuIGl0IHNpbmdsZScpO1xuXG4gICAgICAgIHZhciByZW1vdmVkSXRlbVNpemUgPSBjb250ZW50SXRlbS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSxcbiAgICAgICAgICAgIGhlYWRlclNpemUgPSB0aGlzLmxheW91dE1hbmFnZXIuY29uZmlnLmRpbWVuc2lvbnMuaGVhZGVySGVpZ2h0LFxuICAgICAgICAgICAgaW5kZXggPSBpbmRleE9mKGNvbnRlbnRJdGVtLCB0aGlzLmNvbnRlbnRJdGVtcyksXG4gICAgICAgICAgICBzcGxpdHRlckluZGV4ID0gTWF0aC5tYXgoaW5kZXggLSAxLCAwKTtcblxuICAgICAgICBpZiAoaW5kZXggPT09IC0xKSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0NhblxcJ3QgZG9jayBjaGlsZC4gQ29udGVudEl0ZW0gaXMgbm90IGNoaWxkIG9mIHRoaXMgUm93IG9yIENvbHVtbicpO1xuICAgICAgICB9XG4gICAgICAgIHZhciBpc0RvY2tlZCA9IGNvbnRlbnRJdGVtLl9kb2NrZXIgJiYgY29udGVudEl0ZW0uX2RvY2tlci5kb2NrZWQ7XG4gICAgICAgIHZhciBpXG4gICAgICAgIGlmICh0eXBlb2YgbW9kZSAhPSAndW5kZWZpbmVkJylcbiAgICAgICAgICAgIGlmIChtb2RlID09IGlzRG9ja2VkKVxuICAgICAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgaWYgKGlzRG9ja2VkKSB7IC8vIHVuZG9jayBpdFxuICAgICAgICAgICAgdGhpcy5fc3BsaXR0ZXJbc3BsaXR0ZXJJbmRleF0uZWxlbWVudC5zaG93KCk7XG4gICAgICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgICAgICB2YXIgbmV3SXRlbVNpemUgPSBjb250ZW50SXRlbS5fZG9ja2VyLnNpemU7XG4gICAgICAgICAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zW2ldID09PSBjb250ZW50SXRlbSkge1xuICAgICAgICAgICAgICAgICAgICBjb250ZW50SXRlbS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSA9IG5ld0l0ZW1TaXplO1xuICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgIGl0ZW1TaXplID0gdGhpcy5jb250ZW50SXRlbXNbaV0uY29uZmlnW3RoaXMuX2RpbWVuc2lvbl0gKj0gKDEwMCAtIG5ld0l0ZW1TaXplKSAvIDEwMDtcbiAgICAgICAgICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbaV0uY29uZmlnW3RoaXMuX2RpbWVuc2lvbl0gPSBpdGVtU2l6ZTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICBjb250ZW50SXRlbS5fZG9ja2VyID0ge1xuICAgICAgICAgICAgICAgIGRvY2tlZDogZmFsc2VcbiAgICAgICAgICAgIH07XG4gICAgICAgIH0gZWxzZSB7IC8vIGRvY2tcbiAgICAgICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggLSB0aGlzLl9pc0RvY2tlZCgpIDwgMilcbiAgICAgICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0NhblxcJ3QgZG9jayBjaGlsZCB3aGVuIGl0IGlzIGxhc3QgaW4gJyArIHRoaXMuY29uZmlnLnR5cGUpO1xuICAgICAgICAgICAgdmFyIGF1dG9zaWRlID0ge1xuICAgICAgICAgICAgICAgIGNvbHVtbjoge1xuICAgICAgICAgICAgICAgICAgICBmaXJzdDogJ3RvcCcsXG4gICAgICAgICAgICAgICAgICAgIGxhc3Q6ICdib3R0b20nXG4gICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICByb3c6IHtcbiAgICAgICAgICAgICAgICAgICAgZmlyc3Q6ICdsZWZ0JyxcbiAgICAgICAgICAgICAgICAgICAgbGFzdDogJ3JpZ2h0J1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH07XG4gICAgICAgICAgICB2YXIgcmVxdWlyZWQgPSBhdXRvc2lkZVt0aGlzLmNvbmZpZy50eXBlXVtpbmRleCA/ICdsYXN0JyA6ICdmaXJzdCddO1xuICAgICAgICAgICAgaWYgKGNvbnRlbnRJdGVtLmhlYWRlci5wb3NpdGlvbigpICE9IHJlcXVpcmVkKVxuICAgICAgICAgICAgICAgIGNvbnRlbnRJdGVtLmhlYWRlci5wb3NpdGlvbihyZXF1aXJlZCk7XG5cbiAgICAgICAgICAgIGlmICh0aGlzLl9zcGxpdHRlcltzcGxpdHRlckluZGV4XSkge1xuICAgICAgICAgICAgICAgIHRoaXMuX3NwbGl0dGVyW3NwbGl0dGVySW5kZXhdLmVsZW1lbnQuaGlkZSgpO1xuICAgICAgICAgICAgfVxuICAgICAgICAgICAgdmFyIGRvY2tlZCA9IHRoaXMuX2lzRG9ja2VkKCk7XG4gICAgICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgICAgICBpZiAodGhpcy5jb250ZW50SXRlbXNbaV0gIT09IGNvbnRlbnRJdGVtKSB7XG4gICAgICAgICAgICAgICAgICAgIGlmICghdGhpcy5faXNEb2NrZWQoaSkpXG4gICAgICAgICAgICAgICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbdGhpcy5fZGltZW5zaW9uXSArPSByZW1vdmVkSXRlbVNpemUgLyAodGhpcy5jb250ZW50SXRlbXMubGVuZ3RoIC0gMSAtIGRvY2tlZCk7XG4gICAgICAgICAgICAgICAgfSBlbHNlXG4gICAgICAgICAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zW2ldLmNvbmZpZ1t0aGlzLl9kaW1lbnNpb25dID0gMDtcbiAgICAgICAgICAgIH1cbiAgICAgICAgICAgIGNvbnRlbnRJdGVtLl9kb2NrZXIgPSB7XG4gICAgICAgICAgICAgICAgZGltZW5zaW9uOiB0aGlzLl9kaW1lbnNpb24sXG4gICAgICAgICAgICAgICAgc2l6ZTogcmVtb3ZlZEl0ZW1TaXplLFxuICAgICAgICAgICAgICAgIHJlYWxTaXplOiBjb250ZW50SXRlbS5lbGVtZW50W3RoaXMuX2RpbWVuc2lvbl0oKSAtIGhlYWRlclNpemUsXG4gICAgICAgICAgICAgICAgZG9ja2VkOiB0cnVlLFxuICAgICAgICAgICAgfTtcbiAgICAgICAgICAgIGlmIChjb2xsYXBzZWQpXG4gICAgICAgICAgICAgICAgY29udGVudEl0ZW0uY2hpbGRFbGVtZW50Q29udGFpbmVyW3RoaXMuX2RpbWVuc2lvbl0oMCk7XG4gICAgICAgIH1cbiAgICAgICAgY29udGVudEl0ZW0uZWxlbWVudC50b2dnbGVDbGFzcygnbG1fZG9ja2VkJywgY29udGVudEl0ZW0uX2RvY2tlci5kb2NrZWQpO1xuICAgICAgICB0aGlzLmNhbGxEb3dud2FyZHMoJ3NldFNpemUnKTtcbiAgICAgICAgdGhpcy5lbWl0QnViYmxpbmdFdmVudCgnc3RhdGVDaGFuZ2VkJyk7XG4gICAgICAgIHRoaXMuX3ZhbGlkYXRlRG9ja2luZygpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEludm9rZWQgcmVjdXJzaXZlbHkgYnkgdGhlIGxheW91dCBtYW5hZ2VyLiBBYnN0cmFjdENvbnRlbnRJdGVtLmluaXQgYXBwZW5kc1xuICAgICAqIHRoZSBjb250ZW50SXRlbSdzIERPTSBlbGVtZW50cyB0byB0aGUgY29udGFpbmVyLCBSb3dPckNvbHVtbiBpbml0IGFkZHMgc3BsaXR0ZXJzXG4gICAgICogaW4gYmV0d2VlbiB0aGVtXG4gICAgICpcbiAgICAgKiBAcGFja2FnZSBwcml2YXRlXG4gICAgICogQG92ZXJyaWRlIEFic3RyYWN0Q29udGVudEl0ZW0uXyRpbml0XG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgXyRpbml0KCkge1xuICAgICAgICBpZiAodGhpcy5pc0luaXRpYWxpc2VkID09PSB0cnVlKSByZXR1cm47XG5cbiAgICAgICAgdmFyIGk7XG5cbiAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUuXyRpbml0LmNhbGwodGhpcyk7XG5cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCAtIDE7IGkrKykge1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbaV0uZWxlbWVudC5hZnRlcih0aGlzLl9jcmVhdGVTcGxpdHRlcihpKS5lbGVtZW50KTtcbiAgICAgICAgfVxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtc1tpXS5faGVhZGVyICYmIHRoaXMuY29udGVudEl0ZW1zW2ldLl9oZWFkZXIuZG9ja2VkKVxuICAgICAgICAgICAgICAgIHRoaXMuZG9jayh0aGlzLmNvbnRlbnRJdGVtc1tpXSwgdHJ1ZSwgdHJ1ZSk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBUdXJucyB0aGUgcmVsYXRpdmUgc2l6ZXMgY2FsY3VsYXRlZCBieSBfY2FsY3VsYXRlUmVsYXRpdmVTaXplcyBpbnRvXG4gICAgICogYWJzb2x1dGUgcGl4ZWwgdmFsdWVzIGFuZCBhcHBsaWVzIHRoZW0gdG8gdGhlIGNoaWxkcmVuJ3MgRE9NIGVsZW1lbnRzXG4gICAgICpcbiAgICAgKiBBc3NpZ25zIGFkZGl0aW9uYWwgcGl4ZWxzIHRvIGNvdW50ZXJhY3QgTWF0aC5mbG9vclxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfc2V0QWJzb2x1dGVTaXplcygpIHtcbiAgICAgICAgdmFyIGksXG4gICAgICAgICAgICBzaXplRGF0YSA9IHRoaXMuX2NhbGN1bGF0ZUFic29sdXRlU2l6ZXMoKTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIGlmIChzaXplRGF0YS5hZGRpdGlvbmFsUGl4ZWwgLSBpID4gMCkge1xuICAgICAgICAgICAgICAgIHNpemVEYXRhLml0ZW1TaXplc1tpXSsrO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICBpZiAodGhpcy5faXNDb2x1bW4pIHtcbiAgICAgICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5lbGVtZW50LndpZHRoKHNpemVEYXRhLnRvdGFsV2lkdGgpO1xuICAgICAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zW2ldLmVsZW1lbnQuaGVpZ2h0KHNpemVEYXRhLml0ZW1TaXplc1tpXSk7XG4gICAgICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zW2ldLmVsZW1lbnQud2lkdGgoc2l6ZURhdGEuaXRlbVNpemVzW2ldKTtcbiAgICAgICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5lbGVtZW50LmhlaWdodChzaXplRGF0YS50b3RhbEhlaWdodCk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxjdWxhdGVzIHRoZSBhYnNvbHV0ZSBzaXplcyBvZiBhbGwgb2YgdGhlIGNoaWxkcmVuIG9mIHRoaXMgSXRlbS5cbiAgICAgKiBAcmV0dXJucyB7b2JqZWN0fSAtIFNldCB3aXRoIGFic29sdXRlIHNpemVzIGFuZCBhZGRpdGlvbmFsIHBpeGVscy5cbiAgICAgKi9cbiAgICBfY2FsY3VsYXRlQWJzb2x1dGVTaXplcygpIHtcbiAgICAgICAgdmFyIGksXG4gICAgICAgICAgICB0b3RhbFNwbGl0dGVyU2l6ZSA9ICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggLSAxKSAqIHRoaXMuX3NwbGl0dGVyU2l6ZSxcbiAgICAgICAgICAgIGhlYWRlclNpemUgPSB0aGlzLmxheW91dE1hbmFnZXIuY29uZmlnLmRpbWVuc2lvbnMuaGVhZGVySGVpZ2h0LFxuICAgICAgICAgICAgdG90YWxXaWR0aCA9IHRoaXMuZWxlbWVudC53aWR0aCgpLFxuICAgICAgICAgICAgdG90YWxIZWlnaHQgPSB0aGlzLmVsZW1lbnQuaGVpZ2h0KCksXG4gICAgICAgICAgICB0b3RhbEFzc2lnbmVkID0gMCxcbiAgICAgICAgICAgIGFkZGl0aW9uYWxQaXhlbCxcbiAgICAgICAgICAgIGl0ZW1TaXplLFxuICAgICAgICAgICAgaXRlbVNpemVzID0gW107XG5cbiAgICAgICAgaWYgKHRoaXMuX2lzQ29sdW1uKSB7XG4gICAgICAgICAgICB0b3RhbEhlaWdodCAtPSB0b3RhbFNwbGl0dGVyU2l6ZTtcbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHRvdGFsV2lkdGggLT0gdG90YWxTcGxpdHRlclNpemU7XG4gICAgICAgIH1cbiAgICAgICAgZm9yIChpID0gMDsgaSA8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBpZiAodGhpcy5faXNEb2NrZWQoaSkpXG4gICAgICAgICAgICAgICAgaWYgKHRoaXMuX2lzQ29sdW1uKSB7XG4gICAgICAgICAgICAgICAgICAgIHRvdGFsSGVpZ2h0IC09IGhlYWRlclNpemUgLSB0aGlzLl9zcGxpdHRlclNpemU7XG4gICAgICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICAgICAgdG90YWxXaWR0aCAtPSBoZWFkZXJTaXplIC0gdGhpcy5fc3BsaXR0ZXJTaXplO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgfVxuXG4gICAgICAgIGZvciAoaSA9IDA7IGkgPCB0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMuX2lzQ29sdW1uKSB7XG4gICAgICAgICAgICAgICAgaXRlbVNpemUgPSBNYXRoLmZsb29yKHRvdGFsSGVpZ2h0ICogKHRoaXMuY29udGVudEl0ZW1zW2ldLmNvbmZpZy5oZWlnaHQgLyAxMDApKTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgaXRlbVNpemUgPSBNYXRoLmZsb29yKHRvdGFsV2lkdGggKiAodGhpcy5jb250ZW50SXRlbXNbaV0uY29uZmlnLndpZHRoIC8gMTAwKSk7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICBpZiAodGhpcy5faXNEb2NrZWQoaSkpXG4gICAgICAgICAgICAgICAgaXRlbVNpemUgPSBoZWFkZXJTaXplO1xuXG4gICAgICAgICAgICB0b3RhbEFzc2lnbmVkICs9IGl0ZW1TaXplO1xuICAgICAgICAgICAgaXRlbVNpemVzLnB1c2goaXRlbVNpemUpO1xuICAgICAgICB9XG5cbiAgICAgICAgYWRkaXRpb25hbFBpeGVsID0gTWF0aC5mbG9vcigodGhpcy5faXNDb2x1bW4gPyB0b3RhbEhlaWdodCA6IHRvdGFsV2lkdGgpIC0gdG90YWxBc3NpZ25lZCk7XG5cbiAgICAgICAgcmV0dXJuIHtcbiAgICAgICAgICAgIGl0ZW1TaXplczogaXRlbVNpemVzLFxuICAgICAgICAgICAgYWRkaXRpb25hbFBpeGVsOiBhZGRpdGlvbmFsUGl4ZWwsXG4gICAgICAgICAgICB0b3RhbFdpZHRoOiB0b3RhbFdpZHRoLFxuICAgICAgICAgICAgdG90YWxIZWlnaHQ6IHRvdGFsSGVpZ2h0XG4gICAgICAgIH07XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ2FsY3VsYXRlcyB0aGUgcmVsYXRpdmUgc2l6ZXMgb2YgYWxsIGNoaWxkcmVuIG9mIHRoaXMgSXRlbS4gVGhlIGxvZ2ljXG4gICAgICogaXMgYXMgZm9sbG93czpcbiAgICAgKlxuICAgICAqIC0gQWRkIHVwIHRoZSB0b3RhbCBzaXplIG9mIGFsbCBpdGVtcyB0aGF0IGhhdmUgYSBjb25maWd1cmVkIHNpemVcbiAgICAgKlxuICAgICAqIC0gSWYgdGhlIHRvdGFsID09IDEwMCAoY2hlY2sgZm9yIGZsb2F0aW5nIHBvaW50IGVycm9ycylcbiAgICAgKiAgICAgICAgRXhjZWxsZW50LCBqb2IgZG9uZVxuICAgICAqXG4gICAgICogLSBJZiB0aGUgdG90YWwgaXMgPiAxMDAsXG4gICAgICogICAgICAgIHNldCB0aGUgc2l6ZSBvZiBpdGVtcyB3aXRob3V0IHNldCBkaW1lbnNpb25zIHRvIDEvMyBhbmQgYWRkIHRoaXMgdG8gdGhlIHRvdGFsXG4gICAgICogICAgICAgIHNldCB0aGUgc2l6ZSBvZmYgYWxsIGl0ZW1zIHNvIHRoYXQgdGhlIHRvdGFsIGlzIGh1bmRyZWQgcmVsYXRpdmUgdG8gdGhlaXIgb3JpZ2luYWwgc2l6ZVxuICAgICAqXG4gICAgICogLSBJZiB0aGUgdG90YWwgaXMgPCAxMDBcbiAgICAgKiAgICAgICAgSWYgdGhlcmUgYXJlIGl0ZW1zIHdpdGhvdXQgc2V0IGRpbWVuc2lvbnMsIGRpc3RyaWJ1dGUgdGhlIHJlbWFpbmRlciB0byAxMDAgZXZlbmx5IGJldHdlZW4gdGhlbVxuICAgICAqICAgICAgICBJZiB0aGVyZSBhcmUgbm8gaXRlbXMgd2l0aG91dCBzZXQgZGltZW5zaW9ucywgaW5jcmVhc2UgYWxsIGl0ZW1zIHNpemVzIHJlbGF0aXZlIHRvXG4gICAgICogICAgICAgIHRoZWlyIG9yaWdpbmFsIHNpemUgc28gdGhhdCB0aGV5IGFkZCB1cCB0byAxMDBcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX2NhbGN1bGF0ZVJlbGF0aXZlU2l6ZXMoKSB7XG5cbiAgICAgICAgdmFyIGksXG4gICAgICAgICAgICB0b3RhbCA9IDAsXG4gICAgICAgICAgICBpdGVtc1dpdGhvdXRTZXREaW1lbnNpb24gPSBbXSxcbiAgICAgICAgICAgIGRpbWVuc2lvbiA9IHRoaXMuX2lzQ29sdW1uID8gJ2hlaWdodCcgOiAnd2lkdGgnO1xuXG4gICAgICAgIGZvciAoaSA9IDA7IGkgPCB0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zW2ldLmNvbmZpZ1tkaW1lbnNpb25dICE9PSB1bmRlZmluZWQpIHtcbiAgICAgICAgICAgICAgICB0b3RhbCArPSB0aGlzLmNvbnRlbnRJdGVtc1tpXS5jb25maWdbZGltZW5zaW9uXTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgaXRlbXNXaXRob3V0U2V0RGltZW5zaW9uLnB1c2godGhpcy5jb250ZW50SXRlbXNbaV0pO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIEV2ZXJ5dGhpbmcgYWRkcyB1cCB0byBodW5kcmVkLCBhbGwgZ29vZCA6LSlcbiAgICAgICAgICovXG4gICAgICAgIGlmIChNYXRoLnJvdW5kKHRvdGFsKSA9PT0gMTAwKSB7XG4gICAgICAgICAgICB0aGlzLl9yZXNwZWN0TWluSXRlbVdpZHRoKCk7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICAvKipcbiAgICAgICAgICogQWxsb2NhdGUgdGhlIHJlbWFpbmluZyBzaXplIHRvIHRoZSBpdGVtcyB3aXRob3V0IGEgc2V0IGRpbWVuc2lvblxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKE1hdGgucm91bmQodG90YWwpIDwgMTAwICYmIGl0ZW1zV2l0aG91dFNldERpbWVuc2lvbi5sZW5ndGggPiAwKSB7XG4gICAgICAgICAgICBmb3IgKGkgPSAwOyBpIDwgaXRlbXNXaXRob3V0U2V0RGltZW5zaW9uLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICAgICAgaXRlbXNXaXRob3V0U2V0RGltZW5zaW9uW2ldLmNvbmZpZ1tkaW1lbnNpb25dID0gKDEwMCAtIHRvdGFsKSAvIGl0ZW1zV2l0aG91dFNldERpbWVuc2lvbi5sZW5ndGg7XG4gICAgICAgICAgICB9XG4gICAgICAgICAgICB0aGlzLl9yZXNwZWN0TWluSXRlbVdpZHRoKCk7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICAvKipcbiAgICAgICAgICogSWYgdGhlIHRvdGFsIGlzID4gMTAwLCBidXQgdGhlcmUgYXJlIGFsc28gaXRlbXMgd2l0aG91dCBhIHNldCBkaW1lbnNpb24gbGVmdCwgYXNzaW5nIDUwXG4gICAgICAgICAqIGFzIHRoZWlyIGRpbWVuc2lvbiBhbmQgYWRkIGl0IHRvIHRoZSB0b3RhbFxuICAgICAgICAgKlxuICAgICAgICAgKiBUaGlzIHdpbGwgYmUgcmVzZXQgaW4gdGhlIG5leHQgc3RlcFxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKE1hdGgucm91bmQodG90YWwpID4gMTAwKSB7XG4gICAgICAgICAgICBmb3IgKGkgPSAwOyBpIDwgaXRlbXNXaXRob3V0U2V0RGltZW5zaW9uLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICAgICAgaXRlbXNXaXRob3V0U2V0RGltZW5zaW9uW2ldLmNvbmZpZ1tkaW1lbnNpb25dID0gNTA7XG4gICAgICAgICAgICAgICAgdG90YWwgKz0gNTA7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICAvKipcbiAgICAgICAgICogU2V0IGV2ZXJ5IGl0ZW1zIHNpemUgcmVsYXRpdmUgdG8gMTAwIHJlbGF0aXZlIHRvIGl0cyBzaXplIHRvIHRvdGFsXG4gICAgICAgICAqL1xuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIHRoaXMuY29udGVudEl0ZW1zW2ldLmNvbmZpZ1tkaW1lbnNpb25dID0gKHRoaXMuY29udGVudEl0ZW1zW2ldLmNvbmZpZ1tkaW1lbnNpb25dIC8gdG90YWwpICogMTAwO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fcmVzcGVjdE1pbkl0ZW1XaWR0aCgpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEFkanVzdHMgdGhlIGNvbHVtbiB3aWR0aHMgdG8gcmVzcGVjdCB0aGUgZGltZW5zaW9ucyBtaW5JdGVtV2lkdGggaWYgc2V0LlxuICAgICAqIEByZXR1cm5zIHt9XG4gICAgICovXG4gICAgX3Jlc3BlY3RNaW5JdGVtV2lkdGgoKSB7XG4gICAgICAgIHZhciBtaW5JdGVtV2lkdGggPSB0aGlzLmxheW91dE1hbmFnZXIuY29uZmlnLmRpbWVuc2lvbnMgPyAodGhpcy5sYXlvdXRNYW5hZ2VyLmNvbmZpZy5kaW1lbnNpb25zLm1pbkl0ZW1XaWR0aCB8fCAwKSA6IDAsXG4gICAgICAgICAgICBzaXplRGF0YSA9IG51bGwsXG4gICAgICAgICAgICBlbnRyaWVzT3Zlck1pbiA9IFtdLFxuICAgICAgICAgICAgdG90YWxPdmVyTWluID0gMCxcbiAgICAgICAgICAgIHRvdGFsVW5kZXJNaW4gPSAwLFxuICAgICAgICAgICAgcmVtYWluaW5nV2lkdGggPSAwLFxuICAgICAgICAgICAgaXRlbVNpemUgPSAwLFxuICAgICAgICAgICAgY29udGVudEl0ZW0gPSBudWxsLFxuICAgICAgICAgICAgcmVkdWNlUGVyY2VudCxcbiAgICAgICAgICAgIHJlZHVjZWRXaWR0aCxcbiAgICAgICAgICAgIGFsbEVudHJpZXMgPSBbXSxcbiAgICAgICAgICAgIGVudHJ5O1xuXG4gICAgICAgIGlmICh0aGlzLl9pc0NvbHVtbiB8fCAhbWluSXRlbVdpZHRoIHx8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA8PSAxKSB7XG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICBzaXplRGF0YSA9IHRoaXMuX2NhbGN1bGF0ZUFic29sdXRlU2l6ZXMoKTtcblxuICAgICAgICAvKipcbiAgICAgICAgICogRmlndXJlIG91dCBob3cgbXVjaCB3ZSBhcmUgdW5kZXIgdGhlIG1pbiBpdGVtIHNpemUgdG90YWwgYW5kIGhvdyBtdWNoIHJvb20gd2UgaGF2ZSB0byB1c2UuXG4gICAgICAgICAqL1xuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aDsgaSsrKSB7XG5cbiAgICAgICAgICAgIGNvbnRlbnRJdGVtID0gdGhpcy5jb250ZW50SXRlbXNbaV07XG4gICAgICAgICAgICBpdGVtU2l6ZSA9IHNpemVEYXRhLml0ZW1TaXplc1tpXTtcblxuICAgICAgICAgICAgaWYgKGl0ZW1TaXplIDwgbWluSXRlbVdpZHRoKSB7XG4gICAgICAgICAgICAgICAgdG90YWxVbmRlck1pbiArPSBtaW5JdGVtV2lkdGggLSBpdGVtU2l6ZTtcbiAgICAgICAgICAgICAgICBlbnRyeSA9IHtcbiAgICAgICAgICAgICAgICAgICAgd2lkdGg6IG1pbkl0ZW1XaWR0aFxuICAgICAgICAgICAgICAgIH07XG5cbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgdG90YWxPdmVyTWluICs9IGl0ZW1TaXplIC0gbWluSXRlbVdpZHRoO1xuICAgICAgICAgICAgICAgIGVudHJ5ID0ge1xuICAgICAgICAgICAgICAgICAgICB3aWR0aDogaXRlbVNpemVcbiAgICAgICAgICAgICAgICB9O1xuICAgICAgICAgICAgICAgIGVudHJpZXNPdmVyTWluLnB1c2goZW50cnkpO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICBhbGxFbnRyaWVzLnB1c2goZW50cnkpO1xuICAgICAgICB9XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIElmIHRoZXJlIGlzIG5vdGhpbmcgdW5kZXIgbWluLCBvciB0aGVyZSBpcyBub3QgZW5vdWdoIG92ZXIgdG8gbWFrZSB1cCB0aGUgZGlmZmVyZW5jZSwgZG8gbm90aGluZy5cbiAgICAgICAgICovXG4gICAgICAgIGlmICh0b3RhbFVuZGVyTWluID09PSAwIHx8IHRvdGFsVW5kZXJNaW4gPiB0b3RhbE92ZXJNaW4pIHtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBFdmVubHkgcmVkdWNlIGFsbCBjb2x1bW5zIHRoYXQgYXJlIG92ZXIgdGhlIG1pbiBpdGVtIHdpZHRoIHRvIG1ha2UgdXAgdGhlIGRpZmZlcmVuY2UuXG4gICAgICAgICAqL1xuICAgICAgICByZWR1Y2VQZXJjZW50ID0gdG90YWxVbmRlck1pbiAvIHRvdGFsT3Zlck1pbjtcbiAgICAgICAgcmVtYWluaW5nV2lkdGggPSB0b3RhbFVuZGVyTWluO1xuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgZW50cmllc092ZXJNaW4ubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIGVudHJ5ID0gZW50cmllc092ZXJNaW5baV07XG4gICAgICAgICAgICByZWR1Y2VkV2lkdGggPSBNYXRoLnJvdW5kKChlbnRyeS53aWR0aCAtIG1pbkl0ZW1XaWR0aCkgKiByZWR1Y2VQZXJjZW50KTtcbiAgICAgICAgICAgIHJlbWFpbmluZ1dpZHRoIC09IHJlZHVjZWRXaWR0aDtcbiAgICAgICAgICAgIGVudHJ5LndpZHRoIC09IHJlZHVjZWRXaWR0aDtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBUYWtlIGFueXRoaW5nIHJlbWFpbmluZyBmcm9tIHRoZSBsYXN0IGl0ZW0uXG4gICAgICAgICAqL1xuICAgICAgICBpZiAocmVtYWluaW5nV2lkdGggIT09IDApIHtcbiAgICAgICAgICAgIGFsbEVudHJpZXNbYWxsRW50cmllcy5sZW5ndGggLSAxXS53aWR0aCAtPSByZW1haW5pbmdXaWR0aDtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBTZXQgZXZlcnkgaXRlbXMgc2l6ZSByZWxhdGl2ZSB0byAxMDAgcmVsYXRpdmUgdG8gaXRzIHNpemUgdG8gdG90YWxcbiAgICAgICAgICovXG4gICAgICAgIGZvciAoaSA9IDA7IGkgPCB0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbaV0uY29uZmlnLndpZHRoID0gKGFsbEVudHJpZXNbaV0ud2lkdGggLyBzaXplRGF0YS50b3RhbFdpZHRoKSAqIDEwMDtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEluc3RhbnRpYXRlcyBhIG5ldyBTcGxpdHRlciwgYmluZHMgZXZlbnRzIHRvIGl0IGFuZCBhZGRzXG4gICAgICogaXQgdG8gdGhlIGFycmF5IG9mIHNwbGl0dGVycyBhdCB0aGUgcG9zaXRpb24gc3BlY2lmaWVkIGFzIHRoZSBpbmRleCBhcmd1bWVudFxuICAgICAqXG4gICAgICogV2hhdCBpdCBkb2Vzbid0IGRvIHRob3VnaCBpcyBhcHBlbmQgdGhlIHNwbGl0dGVyIHRvIHRoZSBET01cbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtJbnR9IGluZGV4IFRoZSBwb3NpdGlvbiBvZiB0aGUgc3BsaXR0ZXJcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtTcGxpdHRlcn1cbiAgICAgKi9cbiAgICBfY3JlYXRlU3BsaXR0ZXIoaW5kZXgpIHtcbiAgICAgICAgdmFyIHNwbGl0dGVyO1xuICAgICAgICBzcGxpdHRlciA9IG5ldyBTcGxpdHRlcih0aGlzLl9pc0NvbHVtbiwgdGhpcy5fc3BsaXR0ZXJTaXplLCB0aGlzLl9zcGxpdHRlckdyYWJTaXplKTtcbiAgICAgICAgc3BsaXR0ZXIub24oJ2RyYWcnLCBmbkJpbmQodGhpcy5fb25TcGxpdHRlckRyYWcsIHRoaXMsIFtzcGxpdHRlcl0pLCB0aGlzKTtcbiAgICAgICAgc3BsaXR0ZXIub24oJ2RyYWdTdG9wJywgZm5CaW5kKHRoaXMuX29uU3BsaXR0ZXJEcmFnU3RvcCwgdGhpcywgW3NwbGl0dGVyXSksIHRoaXMpO1xuICAgICAgICBzcGxpdHRlci5vbignZHJhZ1N0YXJ0JywgZm5CaW5kKHRoaXMuX29uU3BsaXR0ZXJEcmFnU3RhcnQsIHRoaXMsIFtzcGxpdHRlcl0pLCB0aGlzKTtcbiAgICAgICAgdGhpcy5fc3BsaXR0ZXIuc3BsaWNlKGluZGV4LCAwLCBzcGxpdHRlcik7XG4gICAgICAgIHJldHVybiBzcGxpdHRlcjtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBMb2NhdGVzIHRoZSBpbnN0YW5jZSBvZiBTcGxpdHRlciBpbiB0aGUgYXJyYXkgb2ZcbiAgICAgKiByZWdpc3RlcmVkIHNwbGl0dGVycyBhbmQgcmV0dXJucyBhIG1hcCBjb250YWluaW5nIHRoZSBjb250ZW50SXRlbVxuICAgICAqIGJlZm9yZSBhbmQgYWZ0ZXIgdGhlIHNwbGl0dGVycywgYm90aCBvZiB3aGljaCBhcmUgYWZmZWN0ZWQgaWYgdGhlXG4gICAgICogc3BsaXR0ZXIgaXMgbW92ZWRcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtTcGxpdHRlcn0gc3BsaXR0ZXJcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtPYmplY3R9IEEgbWFwIG9mIGNvbnRlbnRJdGVtcyB0aGF0IHRoZSBzcGxpdHRlciBhZmZlY3RzXG4gICAgICovXG4gICAgX2dldEl0ZW1zRm9yU3BsaXR0ZXIoc3BsaXR0ZXIpIHtcbiAgICAgICAgdmFyIGluZGV4ID0gaW5kZXhPZihzcGxpdHRlciwgdGhpcy5fc3BsaXR0ZXIpO1xuXG4gICAgICAgIHJldHVybiB7XG4gICAgICAgICAgICBiZWZvcmU6IHRoaXMuY29udGVudEl0ZW1zW2luZGV4XSxcbiAgICAgICAgICAgIGFmdGVyOiB0aGlzLmNvbnRlbnRJdGVtc1tpbmRleCArIDFdXG4gICAgICAgIH07XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogR2V0cyBkb2NraW5nIGluZm9ybWF0aW9uXG4gICAgICogQHByaXZhdGVcbiAgICAgKi9cbiAgICBfaXNEb2NrZWQoaW5kZXgpIHtcbiAgICAgICAgaWYgKHR5cGVvZiBpbmRleCA9PSAndW5kZWZpbmVkJykge1xuICAgICAgICAgICAgdmFyIGNvdW50ID0gMDtcbiAgICAgICAgICAgIGZvciAodmFyIGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyArK2kpXG4gICAgICAgICAgICAgICAgaWYgKHRoaXMuX2lzRG9ja2VkKGkpKVxuICAgICAgICAgICAgICAgICAgICBjb3VudCsrO1xuICAgICAgICAgICAgcmV0dXJuIGNvdW50O1xuICAgICAgICB9XG4gICAgICAgIGlmIChpbmRleCA8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aClcbiAgICAgICAgICAgIHJldHVybiB0aGlzLmNvbnRlbnRJdGVtc1tpbmRleF0uX2RvY2tlciAmJiB0aGlzLmNvbnRlbnRJdGVtc1tpbmRleF0uX2RvY2tlci5kb2NrZWQ7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVmFsaWRhdGUgaWYgcm93IG9yIGNvbHVtbiBoYXMgYWJpbGl0eSB0byBkb2NrXG4gICAgICogQHByaXZhdGVcbiAgICAgKi9cbiAgICBfdmFsaWRhdGVEb2NraW5nKHRoYXQpIHtcbiAgICAgICAgdGhhdCA9IHRoYXQgfHwgdGhpcztcbiAgICAgICAgdmFyIGNhbiA9IHRoYXQuY29udGVudEl0ZW1zLmxlbmd0aCAtIHRoYXQuX2lzRG9ja2VkKCkgPiAxO1xuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoYXQuY29udGVudEl0ZW1zLmxlbmd0aDsgKytpKVxuICAgICAgICAgICAgaWYgKHRoYXQuY29udGVudEl0ZW1zW2ldIGluc3RhbmNlb2YgU3RhY2spIHtcbiAgICAgICAgICAgICAgICB0aGF0LmNvbnRlbnRJdGVtc1tpXS5oZWFkZXIuX3NldERvY2thYmxlKHRoYXQuX2lzRG9ja2VkKGkpIHx8IGNhbik7XG4gICAgICAgICAgICAgICAgdGhhdC5jb250ZW50SXRlbXNbaV0uaGVhZGVyLl8kc2V0Q2xvc2FibGUoY2FuKTtcbiAgICAgICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBHZXRzIHRoZSBtaW5pbXVtIGRpbWVuc2lvbnMgZm9yIHRoZSBnaXZlbiBpdGVtIGNvbmZpZ3VyYXRpb24gYXJyYXlcbiAgICAgKiBAcGFyYW0gaXRlbVxuICAgICAqIEBwcml2YXRlXG4gICAgICovXG4gICAgX2dldE1pbmltdW1EaW1lbnNpb25zKGFycikge1xuICAgICAgICB2YXIgbWluV2lkdGggPSAwLFxuICAgICAgICAgICAgbWluSGVpZ2h0ID0gMDtcblxuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IGFyci5sZW5ndGg7ICsraSkge1xuICAgICAgICAgICAgbWluV2lkdGggPSBNYXRoLm1heChhcnJbaV0ubWluV2lkdGggfHwgMCwgbWluV2lkdGgpO1xuICAgICAgICAgICAgbWluSGVpZ2h0ID0gTWF0aC5tYXgoYXJyW2ldLm1pbkhlaWdodCB8fCAwLCBtaW5IZWlnaHQpO1xuICAgICAgICB9XG5cbiAgICAgICAgcmV0dXJuIHtcbiAgICAgICAgICAgIGhvcml6b250YWw6IG1pbldpZHRoLFxuICAgICAgICAgICAgdmVydGljYWw6IG1pbkhlaWdodFxuICAgICAgICB9O1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEludm9rZWQgd2hlbiBhIHNwbGl0dGVyJ3MgZHJhZ0xpc3RlbmVyIGZpcmVzIGRyYWdTdGFydC4gQ2FsY3VsYXRlcyB0aGUgc3BsaXR0ZXJzXG4gICAgICogbW92ZW1lbnQgYXJlYSBvbmNlIChzbyB0aGF0IGl0IGRvZXNuJ3QgbmVlZCBjYWxjdWxhdGluZyBvbiBldmVyeSBtb3VzZW1vdmUgZXZlbnQpXG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7U3BsaXR0ZXJ9IHNwbGl0dGVyXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfb25TcGxpdHRlckRyYWdTdGFydChzcGxpdHRlcikge1xuICAgICAgICB2YXIgaXRlbXMgPSB0aGlzLl9nZXRJdGVtc0ZvclNwbGl0dGVyKHNwbGl0dGVyKSxcbiAgICAgICAgICAgIG1pblNpemUgPSB0aGlzLmxheW91dE1hbmFnZXIuY29uZmlnLmRpbWVuc2lvbnNbdGhpcy5faXNDb2x1bW4gPyAnbWluSXRlbUhlaWdodCcgOiAnbWluSXRlbVdpZHRoJ107XG5cbiAgICAgICAgdmFyIGJlZm9yZU1pbkRpbSA9IHRoaXMuX2dldE1pbmltdW1EaW1lbnNpb25zKGl0ZW1zLmJlZm9yZS5jb25maWcuY29udGVudCk7XG4gICAgICAgIHZhciBiZWZvcmVNaW5TaXplID0gdGhpcy5faXNDb2x1bW4gPyBiZWZvcmVNaW5EaW0udmVydGljYWwgOiBiZWZvcmVNaW5EaW0uaG9yaXpvbnRhbDtcblxuICAgICAgICB2YXIgYWZ0ZXJNaW5EaW0gPSB0aGlzLl9nZXRNaW5pbXVtRGltZW5zaW9ucyhpdGVtcy5hZnRlci5jb25maWcuY29udGVudCk7XG4gICAgICAgIHZhciBhZnRlck1pblNpemUgPSB0aGlzLl9pc0NvbHVtbiA/IGFmdGVyTWluRGltLnZlcnRpY2FsIDogYWZ0ZXJNaW5EaW0uaG9yaXpvbnRhbDtcblxuICAgICAgICB0aGlzLl9zcGxpdHRlclBvc2l0aW9uID0gMDtcbiAgICAgICAgdGhpcy5fc3BsaXR0ZXJNaW5Qb3NpdGlvbiA9IC0xICogKGl0ZW1zLmJlZm9yZS5lbGVtZW50W3RoaXMuX2RpbWVuc2lvbl0oKSAtIChiZWZvcmVNaW5TaXplIHx8IG1pblNpemUpKTtcbiAgICAgICAgdGhpcy5fc3BsaXR0ZXJNYXhQb3NpdGlvbiA9IGl0ZW1zLmFmdGVyLmVsZW1lbnRbdGhpcy5fZGltZW5zaW9uXSgpIC0gKGFmdGVyTWluU2l6ZSB8fCBtaW5TaXplKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBJbnZva2VkIHdoZW4gYSBzcGxpdHRlcidzIERyYWdMaXN0ZW5lciBmaXJlcyBkcmFnLiBVcGRhdGVzIHRoZSBzcGxpdHRlcnMgRE9NIHBvc2l0aW9uLFxuICAgICAqIGJ1dCBub3QgdGhlIHNpemVzIG9mIHRoZSBlbGVtZW50cyB0aGUgc3BsaXR0ZXIgY29udHJvbHMgaW4gb3JkZXIgdG8gbWluaW1pemUgcmVzaXplIGV2ZW50c1xuICAgICAqXG4gICAgICogQHBhcmFtICAge1NwbGl0dGVyfSBzcGxpdHRlclxuICAgICAqIEBwYXJhbSAgIHtJbnR9IG9mZnNldFggIFJlbGF0aXZlIHBpeGVsIHZhbHVlcyB0byB0aGUgc3BsaXR0ZXJzIG9yaWdpbmFsIHBvc2l0aW9uLiBDYW4gYmUgbmVnYXRpdmVcbiAgICAgKiBAcGFyYW0gICB7SW50fSBvZmZzZXRZICBSZWxhdGl2ZSBwaXhlbCB2YWx1ZXMgdG8gdGhlIHNwbGl0dGVycyBvcmlnaW5hbCBwb3NpdGlvbi4gQ2FuIGJlIG5lZ2F0aXZlXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfb25TcGxpdHRlckRyYWcoc3BsaXR0ZXIsIG9mZnNldFgsIG9mZnNldFkpIHtcbiAgICAgICAgdmFyIG9mZnNldCA9IHRoaXMuX2lzQ29sdW1uID8gb2Zmc2V0WSA6IG9mZnNldFg7XG5cbiAgICAgICAgaWYgKG9mZnNldCA+IHRoaXMuX3NwbGl0dGVyTWluUG9zaXRpb24gJiYgb2Zmc2V0IDwgdGhpcy5fc3BsaXR0ZXJNYXhQb3NpdGlvbikge1xuICAgICAgICAgICAgdGhpcy5fc3BsaXR0ZXJQb3NpdGlvbiA9IG9mZnNldDtcbiAgICAgICAgICAgIHNwbGl0dGVyLmVsZW1lbnQuY3NzKHRoaXMuX2lzQ29sdW1uID8gJ3RvcCcgOiAnbGVmdCcsIG9mZnNldCk7XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBJbnZva2VkIHdoZW4gYSBzcGxpdHRlcidzIERyYWdMaXN0ZW5lciBmaXJlcyBkcmFnU3RvcC4gUmVzZXRzIHRoZSBzcGxpdHRlcnMgRE9NIHBvc2l0aW9uLFxuICAgICAqIGFuZCBhcHBsaWVzIHRoZSBuZXcgc2l6ZXMgdG8gdGhlIGVsZW1lbnRzIGJlZm9yZSBhbmQgYWZ0ZXIgdGhlIHNwbGl0dGVyIGFuZCB0aGVpciBjaGlsZHJlblxuICAgICAqIG9uIHRoZSBuZXh0IGFuaW1hdGlvbiBmcmFtZVxuICAgICAqXG4gICAgICogQHBhcmFtICAge1NwbGl0dGVyfSBzcGxpdHRlclxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX29uU3BsaXR0ZXJEcmFnU3RvcChzcGxpdHRlcikge1xuXG4gICAgICAgIHZhciBpdGVtcyA9IHRoaXMuX2dldEl0ZW1zRm9yU3BsaXR0ZXIoc3BsaXR0ZXIpLFxuICAgICAgICAgICAgc2l6ZUJlZm9yZSA9IGl0ZW1zLmJlZm9yZS5lbGVtZW50W3RoaXMuX2RpbWVuc2lvbl0oKSxcbiAgICAgICAgICAgIHNpemVBZnRlciA9IGl0ZW1zLmFmdGVyLmVsZW1lbnRbdGhpcy5fZGltZW5zaW9uXSgpLFxuICAgICAgICAgICAgc3BsaXR0ZXJQb3NpdGlvbkluUmFuZ2UgPSAodGhpcy5fc3BsaXR0ZXJQb3NpdGlvbiArIHNpemVCZWZvcmUpIC8gKHNpemVCZWZvcmUgKyBzaXplQWZ0ZXIpLFxuICAgICAgICAgICAgdG90YWxSZWxhdGl2ZVNpemUgPSBpdGVtcy5iZWZvcmUuY29uZmlnW3RoaXMuX2RpbWVuc2lvbl0gKyBpdGVtcy5hZnRlci5jb25maWdbdGhpcy5fZGltZW5zaW9uXTtcblxuICAgICAgICBpdGVtcy5iZWZvcmUuY29uZmlnW3RoaXMuX2RpbWVuc2lvbl0gPSBzcGxpdHRlclBvc2l0aW9uSW5SYW5nZSAqIHRvdGFsUmVsYXRpdmVTaXplO1xuICAgICAgICBpdGVtcy5hZnRlci5jb25maWdbdGhpcy5fZGltZW5zaW9uXSA9ICgxIC0gc3BsaXR0ZXJQb3NpdGlvbkluUmFuZ2UpICogdG90YWxSZWxhdGl2ZVNpemU7XG5cbiAgICAgICAgc3BsaXR0ZXIuZWxlbWVudC5jc3Moe1xuICAgICAgICAgICAgJ3RvcCc6IDAsXG4gICAgICAgICAgICAnbGVmdCc6IDBcbiAgICAgICAgfSk7XG5cbiAgICAgICAgYW5pbUZyYW1lKGZuQmluZCh0aGlzLmNhbGxEb3dud2FyZHMsIHRoaXMsIFsnc2V0U2l6ZSddKSk7XG4gICAgfVxufVxuIiwiaW1wb3J0IEFic3RyYWN0Q29udGVudEl0ZW0gZnJvbSAnLi4vaXRlbXMvQWJzdHJhY3RDb250ZW50SXRlbSdcbmltcG9ydCBSb3dPckNvbHVtbiBmcm9tICcuLi9pdGVtcy9Sb3dPckNvbHVtbidcbmltcG9ydCBIZWFkZXIgZnJvbSAnLi4vY29udHJvbHMvSGVhZGVyJ1xuXG5pbXBvcnQge1xuICAgIGZuQmluZCxcbiAgICBjb3B5LFxuICAgIGluZGV4T2Zcbn0gZnJvbSAnLi4vdXRpbHMvdXRpbHMnXG5pbXBvcnQgJCBmcm9tICdqcXVlcnknO1xuXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIFN0YWNrIGV4dGVuZHMgQWJzdHJhY3RDb250ZW50SXRlbSB7XG4gICAgY29uc3RydWN0b3IobGF5b3V0TWFuYWdlciwgY29uZmlnLCBwYXJlbnQpIHtcbiAgICAgICAgc3VwZXIobGF5b3V0TWFuYWdlciwgY29uZmlnLCBwYXJlbnQpXG5cbiAgICAgICAgdGhpcy5lbGVtZW50ID0gJCgnPGRpdiBjbGFzcz1cImxtX2l0ZW0gbG1fc3RhY2tcIj48L2Rpdj4nKTtcbiAgICAgICAgdGhpcy5fYWN0aXZlQ29udGVudEl0ZW0gPSBudWxsO1xuICAgICAgICB2YXIgY2ZnID0gbGF5b3V0TWFuYWdlci5jb25maWc7XG4gICAgICAgIHRoaXMuX2hlYWRlciA9IHsgLy8gZGVmYXVsdHMnIHJlY29uc3RydWN0aW9uIGZyb20gb2xkIGNvbmZpZ3VyYXRpb24gc3R5bGVcbiAgICAgICAgICAgIHNob3c6IGNmZy5zZXR0aW5ncy5oYXNIZWFkZXJzID09PSB0cnVlICYmIGNvbmZpZy5oYXNIZWFkZXJzICE9PSBmYWxzZSxcbiAgICAgICAgICAgIHBvcG91dDogY2ZnLnNldHRpbmdzLnNob3dQb3BvdXRJY29uICYmIGNmZy5sYWJlbHMucG9wb3V0LFxuICAgICAgICAgICAgbWF4aW1pc2U6IGNmZy5zZXR0aW5ncy5zaG93TWF4aW1pc2VJY29uICYmIGNmZy5sYWJlbHMubWF4aW1pc2UsXG4gICAgICAgICAgICBjbG9zZTogY2ZnLnNldHRpbmdzLnNob3dDbG9zZUljb24gJiYgY2ZnLmxhYmVscy5jbG9zZSxcbiAgICAgICAgICAgIG1pbmltaXNlOiBjZmcubGFiZWxzLm1pbmltaXNlLFxuICAgICAgICB9O1xuICAgICAgICBpZiAoY2ZnLmhlYWRlcikgLy8gbG9hZCBzaW1wbGlmaWVkIHZlcnNpb24gb2YgaGVhZGVyIGNvbmZpZ3VyYXRpb24gKGh0dHBzOi8vZ2l0aHViLmNvbS9kZWVwc3RyZWFtSU8vZ29sZGVuLWxheW91dC9wdWxsLzI0NSlcbiAgICAgICAgICAgIGNvcHkodGhpcy5faGVhZGVyLCBjZmcuaGVhZGVyKTtcbiAgICAgICAgaWYgKGNvbmZpZy5oZWFkZXIpIC8vIGxvYWQgZnJvbSBzdGFja1xuICAgICAgICAgICAgY29weSh0aGlzLl9oZWFkZXIsIGNvbmZpZy5oZWFkZXIpO1xuICAgICAgICBpZiAoY29uZmlnLmNvbnRlbnQgJiYgY29uZmlnLmNvbnRlbnRbMF0gJiYgY29uZmlnLmNvbnRlbnRbMF0uaGVhZGVyKSAvLyBsb2FkIGZyb20gY29tcG9uZW50IGlmIHN0YWNrIG9taXR0ZWRcbiAgICAgICAgICAgIGNvcHkodGhpcy5faGVhZGVyLCBjb25maWcuY29udGVudFswXS5oZWFkZXIpO1xuXG4gICAgICAgIHRoaXMuX2Ryb3Bab25lcyA9IHt9O1xuICAgICAgICB0aGlzLl9kcm9wU2VnbWVudCA9IG51bGw7XG4gICAgICAgIHRoaXMuX2NvbnRlbnRBcmVhRGltZW5zaW9ucyA9IG51bGw7XG4gICAgICAgIHRoaXMuX2Ryb3BJbmRleCA9IG51bGw7XG5cbiAgICAgICAgdGhpcy5pc1N0YWNrID0gdHJ1ZTtcblxuICAgICAgICB0aGlzLmNoaWxkRWxlbWVudENvbnRhaW5lciA9ICQoJzxkaXYgY2xhc3M9XCJsbV9pdGVtc1wiPjwvZGl2PicpO1xuICAgICAgICB0aGlzLmhlYWRlciA9IG5ldyBIZWFkZXIobGF5b3V0TWFuYWdlciwgdGhpcyk7XG5cbiAgICAgICAgdGhpcy5lbGVtZW50Lm9uKCdtb3VzZWxlYXZlIG1vdXNlZW50ZXInLCBmbkJpbmQoZnVuY3Rpb24oZXZlbnQpIHtcbiAgICAgICAgICAgIGlmICh0aGlzLl9kb2NrZXIgJiYgdGhpcy5fZG9ja2VyLmRvY2tlZClcbiAgICAgICAgICAgICAgICB0aGlzLmNoaWxkRWxlbWVudENvbnRhaW5lclt0aGlzLl9kb2NrZXIuZGltZW5zaW9uXShldmVudC50eXBlID09ICdtb3VzZWVudGVyJyA/IHRoaXMuX2RvY2tlci5yZWFsU2l6ZSA6IDApO1xuICAgICAgICB9LCB0aGlzKSk7XG4gICAgICAgIHRoaXMuZWxlbWVudC5hcHBlbmQodGhpcy5oZWFkZXIuZWxlbWVudCk7XG4gICAgICAgIHRoaXMuZWxlbWVudC5hcHBlbmQodGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIpO1xuICAgICAgICB0aGlzLl9zZXR1cEhlYWRlclBvc2l0aW9uKCk7XG4gICAgICAgIHRoaXMuXyR2YWxpZGF0ZUNsb3NhYmlsaXR5KCk7XG4gICAgfVxuXG4gICAgZG9jayhtb2RlKSB7XG4gICAgICAgIGlmICh0aGlzLl9oZWFkZXIuZG9jaylcbiAgICAgICAgICAgIGlmICh0aGlzLnBhcmVudCBpbnN0YW5jZW9mIFJvd09yQ29sdW1uKVxuICAgICAgICAgICAgICAgIHRoaXMucGFyZW50LmRvY2sodGhpcywgbW9kZSk7XG4gICAgfVxuXG4gICAgc2V0U2l6ZSgpIHtcbiAgICAgICAgaWYgKHRoaXMuZWxlbWVudC5jc3MoJ2Rpc3BsYXknKSA9PT0gJ25vbmUnKSByZXR1cm47XG4gICAgICAgIHZhciBpc0RvY2tlZCA9IHRoaXMuX2RvY2tlciAmJiB0aGlzLl9kb2NrZXIuZG9ja2VkLFxuICAgICAgICAgICAgY29udGVudCA9IHtcbiAgICAgICAgICAgICAgICB3aWR0aDogdGhpcy5lbGVtZW50LndpZHRoKCksXG4gICAgICAgICAgICAgICAgaGVpZ2h0OiB0aGlzLmVsZW1lbnQuaGVpZ2h0KClcbiAgICAgICAgICAgIH07XG5cbiAgICAgICAgaWYgKHRoaXMuX2hlYWRlci5zaG93KVxuICAgICAgICAgICAgY29udGVudFt0aGlzLl9zaWRlZCA/ICd3aWR0aCcgOiAnaGVpZ2h0J10gLT0gdGhpcy5sYXlvdXRNYW5hZ2VyLmNvbmZpZy5kaW1lbnNpb25zLmhlYWRlckhlaWdodDtcbiAgICAgICAgaWYgKGlzRG9ja2VkKVxuICAgICAgICAgICAgY29udGVudFt0aGlzLl9kb2NrZXIuZGltZW5zaW9uXSA9IHRoaXMuX2RvY2tlci5yZWFsU2l6ZTtcbiAgICAgICAgaWYgKCFpc0RvY2tlZCB8fCB0aGlzLl9kb2NrZXIuZGltZW5zaW9uID09ICdoZWlnaHQnKVxuICAgICAgICAgICAgdGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIud2lkdGgoY29udGVudC53aWR0aCk7XG4gICAgICAgIGlmICghaXNEb2NrZWQgfHwgdGhpcy5fZG9ja2VyLmRpbWVuc2lvbiA9PSAnd2lkdGgnKVxuICAgICAgICAgICAgdGhpcy5jaGlsZEVsZW1lbnRDb250YWluZXIuaGVpZ2h0KGNvbnRlbnQuaGVpZ2h0KTtcblxuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5lbGVtZW50LndpZHRoKGNvbnRlbnQud2lkdGgpO1xuICAgICAgICAgICAgdGhpcy5jb250ZW50SXRlbXNbaV0uZWxlbWVudC5oZWlnaHQoY29udGVudC5oZWlnaHQpO1xuICAgICAgICB9XG4gICAgICAgIHRoaXMuZW1pdCgncmVzaXplJyk7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgIH1cblxuICAgIF8kaW5pdCgpIHtcbiAgICAgICAgdmFyIGksIGluaXRpYWxJdGVtO1xuXG4gICAgICAgIGlmICh0aGlzLmlzSW5pdGlhbGlzZWQgPT09IHRydWUpIHJldHVybjtcblxuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS5fJGluaXQuY2FsbCh0aGlzKTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5jb250ZW50SXRlbXMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgICAgIHRoaXMuaGVhZGVyLmNyZWF0ZVRhYih0aGlzLmNvbnRlbnRJdGVtc1tpXSk7XG4gICAgICAgICAgICB0aGlzLmNvbnRlbnRJdGVtc1tpXS5fJGhpZGUoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIGlmICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggPiAwKSB7XG4gICAgICAgICAgICBpbml0aWFsSXRlbSA9IHRoaXMuY29udGVudEl0ZW1zW3RoaXMuY29uZmlnLmFjdGl2ZUl0ZW1JbmRleCB8fCAwXTtcblxuICAgICAgICAgICAgaWYgKCFpbml0aWFsSXRlbSkge1xuICAgICAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignQ29uZmlndXJlZCBhY3RpdmVJdGVtSW5kZXggb3V0IG9mIGJvdW5kcycpO1xuICAgICAgICAgICAgfVxuXG4gICAgICAgICAgICB0aGlzLnNldEFjdGl2ZUNvbnRlbnRJdGVtKGluaXRpYWxJdGVtKTtcbiAgICAgICAgfVxuICAgICAgICB0aGlzLl8kdmFsaWRhdGVDbG9zYWJpbGl0eSgpO1x0XHRcblx0XHRpZiAodGhpcy5wYXJlbnQgaW5zdGFuY2VvZiBSb3dPckNvbHVtbikge1xuXHRcdFx0dGhpcy5wYXJlbnQuX3ZhbGlkYXRlRG9ja2luZygpO1xuXHRcdH1cbiAgICB9XG5cbiAgICBzZXRBY3RpdmVDb250ZW50SXRlbShjb250ZW50SXRlbSkge1xuICAgICAgICBpZiAodGhpcy5fYWN0aXZlQ29udGVudEl0ZW0gPT09IGNvbnRlbnRJdGVtKSByZXR1cm47XG5cbiAgICAgICAgaWYgKGluZGV4T2YoY29udGVudEl0ZW0sIHRoaXMuY29udGVudEl0ZW1zKSA9PT0gLTEpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignY29udGVudEl0ZW0gaXMgbm90IGEgY2hpbGQgb2YgdGhpcyBzdGFjaycpO1xuICAgICAgICB9XG5cbiAgICAgICAgaWYgKHRoaXMuX2FjdGl2ZUNvbnRlbnRJdGVtICE9PSBudWxsKSB7XG4gICAgICAgICAgICB0aGlzLl9hY3RpdmVDb250ZW50SXRlbS5fJGhpZGUoKTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuX2FjdGl2ZUNvbnRlbnRJdGVtID0gY29udGVudEl0ZW07XG4gICAgICAgIHRoaXMuaGVhZGVyLnNldEFjdGl2ZUNvbnRlbnRJdGVtKGNvbnRlbnRJdGVtKTtcbiAgICAgICAgY29udGVudEl0ZW0uXyRzaG93KCk7XG4gICAgICAgIHRoaXMuZW1pdCgnYWN0aXZlQ29udGVudEl0ZW1DaGFuZ2VkJywgY29udGVudEl0ZW0pO1xuICAgICAgICB0aGlzLmxheW91dE1hbmFnZXIuZW1pdCgnYWN0aXZlQ29udGVudEl0ZW1DaGFuZ2VkJywgY29udGVudEl0ZW0pO1xuICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICB9XG5cbiAgICBnZXRBY3RpdmVDb250ZW50SXRlbSgpIHtcbiAgICAgICAgcmV0dXJuIHRoaXMuaGVhZGVyLmFjdGl2ZUNvbnRlbnRJdGVtO1xuICAgIH1cblxuICAgIGFkZENoaWxkKGNvbnRlbnRJdGVtLCBpbmRleCkge1xuICAgICAgICBpZihpbmRleCA+IHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCl7XG4gICAgICAgICAgICAvKiBcbiAgICAgICAgICAgICAqIFVHTFkgUEFUQ0g6IFBSICM0MjgsIGNvbW1pdCBhNGU4NGVjNSBmaXhlZCBhIGJ1ZyBhcHBlYXJpbmcgb24gdG91Y2hzY3JlZW5zIGR1cmluZyB0aGUgZHJhZyBvZiBhIHBhbmVsLiBcbiAgICAgICAgICAgICAqIFRoZSBidWcgd2FzIGNhdXNlZCBieSB0aGUgcGh5c2ljYWwgcmVtb3ZhbCBvZiB0aGUgZWxlbWVudCBvbiBkcmFnOiBwYXJ0aWFsIGRvY3VtZW50YXRpb24gaXMgYXQgaXNzdWUgIzQyNS4gXG4gICAgICAgICAgICAgKiBUaGUgZml4IGludHJvZHVjZWQgdGhlIGZ1bmN0aW9uIHVuZGlzcGxheUNoaWxkKCkgKGNhbGxlZCAndW5kaXNwbGF5JyB0byBkaWZmZXJlbnRpYXRlIGl0IGZyb20galF1ZXJ5LmhpZGUpLCBcbiAgICAgICAgICAgICAqIHdoaWNoIGRvZXNuJ3QgcmVtb3ZlIHRoZSBlbGVtZW50IGJ1dCBvbmx5IGhpZGVzIGl0OiB0aGF0J3Mgd2h5IHdoZW4gYSB0YWIgaXMgZHJhZ2dlZCAmIGRyb3BwZWQgaW50byBpdHMgXG4gICAgICAgICAgICAgKiBvcmlnaW5hbCBjb250YWluZXIgKGF0IHRoZSBlbmQpLCB0aGUgaW5kZXggaGVyZSBjb3VsZCBiZSBvZmYgYnkgb25lLlxuICAgICAgICAgICAgICovXG4gICAgICAgICAgICBpbmRleCAtPSAxXG4gICAgICAgIH0gICAgICAgIFxuICAgICAgICBjb250ZW50SXRlbSA9IHRoaXMubGF5b3V0TWFuYWdlci5fJG5vcm1hbGl6ZUNvbnRlbnRJdGVtKGNvbnRlbnRJdGVtLCB0aGlzKTtcbiAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUuYWRkQ2hpbGQuY2FsbCh0aGlzLCBjb250ZW50SXRlbSwgaW5kZXgpO1xuICAgICAgICB0aGlzLmNoaWxkRWxlbWVudENvbnRhaW5lci5hcHBlbmQoY29udGVudEl0ZW0uZWxlbWVudCk7XG4gICAgICAgIHRoaXMuaGVhZGVyLmNyZWF0ZVRhYihjb250ZW50SXRlbSwgaW5kZXgpO1xuICAgICAgICB0aGlzLnNldEFjdGl2ZUNvbnRlbnRJdGVtKGNvbnRlbnRJdGVtKTtcbiAgICAgICAgdGhpcy5jYWxsRG93bndhcmRzKCdzZXRTaXplJyk7XG4gICAgICAgIHRoaXMuXyR2YWxpZGF0ZUNsb3NhYmlsaXR5KCk7XG4gICAgICAgIGlmICh0aGlzLnBhcmVudCBpbnN0YW5jZW9mIFJvd09yQ29sdW1uKVxuICAgICAgICAgICAgdGhpcy5wYXJlbnQuX3ZhbGlkYXRlRG9ja2luZygpO1xuICAgICAgICB0aGlzLmVtaXRCdWJibGluZ0V2ZW50KCdzdGF0ZUNoYW5nZWQnKTtcbiAgICB9XG5cbiAgICByZW1vdmVDaGlsZChjb250ZW50SXRlbSwga2VlcENoaWxkKSB7XG4gICAgICAgIHZhciBpbmRleCA9IGluZGV4T2YoY29udGVudEl0ZW0sIHRoaXMuY29udGVudEl0ZW1zKTtcbiAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUucmVtb3ZlQ2hpbGQuY2FsbCh0aGlzLCBjb250ZW50SXRlbSwga2VlcENoaWxkKTtcbiAgICAgICAgdGhpcy5oZWFkZXIucmVtb3ZlVGFiKGNvbnRlbnRJdGVtKTtcbiAgICAgICAgaWYgKHRoaXMuaGVhZGVyLmFjdGl2ZUNvbnRlbnRJdGVtID09PSBjb250ZW50SXRlbSkge1xuICAgICAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA+IDApIHtcbiAgICAgICAgICAgICAgICB0aGlzLnNldEFjdGl2ZUNvbnRlbnRJdGVtKHRoaXMuY29udGVudEl0ZW1zW01hdGgubWF4KGluZGV4IC0gMSwgMCldKTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgdGhpcy5fYWN0aXZlQ29udGVudEl0ZW0gPSBudWxsO1xuICAgICAgICAgICAgfVxuICAgICAgICB9IGVsc2UgaWYgKHRoaXMuY29uZmlnLmFjdGl2ZUl0ZW1JbmRleCA+PSB0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGgpIHtcblx0XHRcdGlmICh0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGggPiAwKSB7XG5cdFx0XHRcdHZhciBhY3RpdmVJbmRleCA9IGluZGV4T2YodGhpcy5nZXRBY3RpdmVDb250ZW50SXRlbSgpLCB0aGlzLmNvbnRlbnRJdGVtcyk7XG5cdFx0XHRcdHRoaXMuY29uZmlnLmFjdGl2ZUl0ZW1JbmRleCA9IE1hdGgubWF4KGFjdGl2ZUluZGV4LCAwKTtcblx0XHRcdH1cblx0XHR9XG5cbiAgICAgICAgdGhpcy5fJHZhbGlkYXRlQ2xvc2FiaWxpdHkoKTtcbiAgICAgICAgaWYgKHRoaXMucGFyZW50IGluc3RhbmNlb2YgUm93T3JDb2x1bW4pXG4gICAgICAgICAgICB0aGlzLnBhcmVudC5fdmFsaWRhdGVEb2NraW5nKCk7XG4gICAgICAgIHRoaXMuZW1pdEJ1YmJsaW5nRXZlbnQoJ3N0YXRlQ2hhbmdlZCcpO1xuICAgIH1cblxuICAgIHVuZGlzcGxheUNoaWxkKGNvbnRlbnRJdGVtKSB7XG4gICAgICAgIGlmKHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA+IDEpe1xuICAgICAgICAgICAgdmFyIGluZGV4ID0gaW5kZXhPZihjb250ZW50SXRlbSwgdGhpcy5jb250ZW50SXRlbXMpXG4gICAgICAgICAgICBjb250ZW50SXRlbS5fJGhpZGUgJiYgY29udGVudEl0ZW0uXyRoaWRlKClcbiAgICAgICAgICAgIHRoaXMuc2V0QWN0aXZlQ29udGVudEl0ZW0odGhpcy5jb250ZW50SXRlbXNbaW5kZXggPT09IDAgPyBpbmRleCsxIDogaW5kZXgtMV0pXG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICB0aGlzLmhlYWRlci5oaWRlVGFiKGNvbnRlbnRJdGVtKTtcbiAgICAgICAgICAgIGNvbnRlbnRJdGVtLl8kaGlkZSAmJiBjb250ZW50SXRlbS5fJGhpZGUoKVxuICAgICAgICAgICAgQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUudW5kaXNwbGF5Q2hpbGQuY2FsbCh0aGlzLCBjb250ZW50SXRlbSk7XG4gICAgICAgICAgICBpZiAodGhpcy5wYXJlbnQgaW5zdGFuY2VvZiBSb3dPckNvbHVtbilcbiAgICAgICAgICAgICAgICB0aGlzLnBhcmVudC5fdmFsaWRhdGVEb2NraW5nKCk7XG4gICAgICAgIH1cbiAgICAgICAgdGhpcy5lbWl0QnViYmxpbmdFdmVudCgnc3RhdGVDaGFuZ2VkJyk7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVmFsaWRhdGVzIHRoYXQgdGhlIHN0YWNrIGlzIHN0aWxsIGNsb3NhYmxlIG9yIG5vdC4gSWYgYSBzdGFjayBpcyBhYmxlXG4gICAgICogdG8gY2xvc2UsIGJ1dCBoYXMgYSBub24gY2xvc2FibGUgY29tcG9uZW50IGFkZGVkIHRvIGl0LCB0aGUgc3RhY2sgaXMgbm9cbiAgICAgKiBsb25nZXIgY2xvc2FibGUgdW50aWwgYWxsIGNvbXBvbmVudHMgYXJlIGNsb3NhYmxlLlxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgXyR2YWxpZGF0ZUNsb3NhYmlsaXR5KCkge1xuICAgICAgICB2YXIgY29udGVudEl0ZW0sXG4gICAgICAgICAgICBpc0Nsb3NhYmxlLFxuICAgICAgICAgICAgbGVuLFxuICAgICAgICAgICAgaTtcblxuICAgICAgICBpc0Nsb3NhYmxlID0gdGhpcy5oZWFkZXIuX2lzQ2xvc2FibGUoKTtcblxuICAgICAgICBmb3IgKGkgPSAwLCBsZW4gPSB0aGlzLmNvbnRlbnRJdGVtcy5sZW5ndGg7IGkgPCBsZW47IGkrKykge1xuICAgICAgICAgICAgaWYgKCFpc0Nsb3NhYmxlKSB7XG4gICAgICAgICAgICAgICAgYnJlYWs7XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGlzQ2xvc2FibGUgPSB0aGlzLmNvbnRlbnRJdGVtc1tpXS5jb25maWcuaXNDbG9zYWJsZTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuaGVhZGVyLl8kc2V0Q2xvc2FibGUoaXNDbG9zYWJsZSk7XG4gICAgfVxuXG4gICAgXyRkZXN0cm95KCkge1xuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS5fJGRlc3Ryb3kuY2FsbCh0aGlzKTtcbiAgICAgICAgdGhpcy5oZWFkZXIuXyRkZXN0cm95KCk7XG4gICAgICAgIHRoaXMuZWxlbWVudC5vZmYoJ21vdXNlZW50ZXIgbW91c2VsZWF2ZScpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIE9rLCB0aGlzIG9uZSBpcyBnb2luZyB0byBiZSB0aGUgdHJpY2t5IG9uZTogVGhlIHVzZXIgaGFzIGRyb3BwZWQge2NvbnRlbnRJdGVtfSBvbnRvIHRoaXMgc3RhY2suXG4gICAgICpcbiAgICAgKiBJdCB3YXMgZHJvcHBlZCBvbiBlaXRoZXIgdGhlIHN0YWNrcyBoZWFkZXIgb3IgdGhlIHRvcCwgcmlnaHQsIGJvdHRvbSBvciBsZWZ0IGJpdCBvZiB0aGUgY29udGVudCBhcmVhXG4gICAgICogKHdoaWNoIG9uZSBvZiB0aG9zZSBpcyBzdG9yZWQgaW4gdGhpcy5fZHJvcFNlZ21lbnQpLiBOb3csIGlmIHRoZSB1c2VyIGhhcyBkcm9wcGVkIG9uIHRoZSBoZWFkZXIgdGhlIGNhc2VcbiAgICAgKiBpcyByZWxhdGl2ZWx5IGNsZWFyOiBXZSBhZGQgdGhlIGl0ZW0gdG8gdGhlIGV4aXN0aW5nIHN0YWNrLi4uIGpvYiBkb25lIChtaWdodCBiZSBnb29kIHRvIGhhdmVcbiAgICAgKiB0YWIgcmVvcmRlcmluZyBhdCBzb21lIHBvaW50LCBidXQgbGV0cyBub3Qgc3dlYXQgaXQgcmlnaHQgbm93KVxuICAgICAqXG4gICAgICogSWYgdGhlIGl0ZW0gd2FzIGRyb3BwZWQgb24gdGhlIGNvbnRlbnQgcGFydCB0aGluZ3MgYXJlIGEgYml0IG1vcmUgY29tcGxpY2F0ZWQuIElmIGl0IHdhcyBkcm9wcGVkIG9uIGVpdGhlciB0aGVcbiAgICAgKiB0b3Agb3IgYm90dG9tIHJlZ2lvbiB3ZSBuZWVkIHRvIGNyZWF0ZSBhIG5ldyBjb2x1bW4gYW5kIHBsYWNlIHRoZSBpdGVtcyBhY2NvcmRpbmdseS5cbiAgICAgKiBVbmxlc3MsIG9mIGNvdXJzZSBpZiB0aGUgc3RhY2sgaXMgYWxyZWFkeSB3aXRoaW4gYSBjb2x1bW4uLi4gaW4gd2hpY2ggY2FzZSB3ZSB3YW50XG4gICAgICogdG8gYWRkIHRoZSBuZXdseSBjcmVhdGVkIGl0ZW0gdG8gdGhlIGV4aXN0aW5nIGNvbHVtbi4uLlxuICAgICAqIGVpdGhlciBwcmVwZW5kIG9yIGFwcGVuZCBpdCwgZGVwZW5kaW5nIG9uIHdldGhlciBpdHMgdG9wIG9yIGJvdHRvbS5cbiAgICAgKlxuICAgICAqIFNhbWUgdGhpbmcgZm9yIHJvd3MgYW5kIGxlZnQgLyByaWdodCBkcm9wIHNlZ21lbnRzLi4uIHNvIGluIHRvdGFsIHRoZXJlIGFyZSA5IHRoaW5ncyB0aGF0IGNhbiBwb3RlbnRpYWxseSBoYXBwZW5cbiAgICAgKiAobGVmdCwgdG9wLCByaWdodCwgYm90dG9tKSAqIGlzIGNoaWxkIG9mIHRoZSByaWdodCBwYXJlbnQgKHJvdywgY29sdW1uKSArIGhlYWRlciBkcm9wXG4gICAgICpcbiAgICAgKiBAcGFyYW0gICAge2xtLml0ZW19IGNvbnRlbnRJdGVtXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfJG9uRHJvcChjb250ZW50SXRlbSkge1xuICAgICAgICAvKlxuICAgICAgICAgKiBUaGUgaXRlbSB3YXMgZHJvcHBlZCBvbiB0aGUgaGVhZGVyIGFyZWEuIEp1c3QgYWRkIGl0IGFzIGEgY2hpbGQgb2YgdGhpcyBzdGFjayBhbmRcbiAgICAgICAgICogZ2V0IHRoZSBoZWxsIG91dCBvZiB0aGlzIGxvZ2ljXG4gICAgICAgICAqL1xuICAgICAgICBpZiAodGhpcy5fZHJvcFNlZ21lbnQgPT09ICdoZWFkZXInKSB7XG4gICAgICAgICAgICB0aGlzLl9yZXNldEhlYWRlckRyb3Bab25lKCk7XG4gICAgICAgICAgICB0aGlzLmFkZENoaWxkKGNvbnRlbnRJdGVtLCB0aGlzLl9kcm9wSW5kZXgpO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG5cbiAgICAgICAgLypcbiAgICAgICAgICogVGhlIHN0YWNrIGlzIGVtcHR5LiBMZXQncyBqdXN0IGFkZCB0aGUgZWxlbWVudC5cbiAgICAgICAgICovXG4gICAgICAgIGlmICh0aGlzLl9kcm9wU2VnbWVudCA9PT0gJ2JvZHknKSB7XG4gICAgICAgICAgICB0aGlzLmFkZENoaWxkKGNvbnRlbnRJdGVtKTtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qXG4gICAgICAgICAqIFRoZSBpdGVtIHdhcyBkcm9wcGVkIG9uIHRoZSB0b3AtLCBsZWZ0LSwgYm90dG9tLSBvciByaWdodC0gcGFydCBvZiB0aGUgY29udGVudC4gTGV0J3NcbiAgICAgICAgICogYWdncmVnYXRlIHNvbWUgY29uZGl0aW9ucyB0byBtYWtlIHRoZSBpZiBzdGF0ZW1lbnRzIGxhdGVyIG9uIG1vcmUgcmVhZGFibGVcbiAgICAgICAgICovXG4gICAgICAgIHZhciBpc1ZlcnRpY2FsID0gdGhpcy5fZHJvcFNlZ21lbnQgPT09ICd0b3AnIHx8IHRoaXMuX2Ryb3BTZWdtZW50ID09PSAnYm90dG9tJyxcbiAgICAgICAgICAgIGlzSG9yaXpvbnRhbCA9IHRoaXMuX2Ryb3BTZWdtZW50ID09PSAnbGVmdCcgfHwgdGhpcy5fZHJvcFNlZ21lbnQgPT09ICdyaWdodCcsXG4gICAgICAgICAgICBpbnNlcnRCZWZvcmUgPSB0aGlzLl9kcm9wU2VnbWVudCA9PT0gJ3RvcCcgfHwgdGhpcy5fZHJvcFNlZ21lbnQgPT09ICdsZWZ0JyxcbiAgICAgICAgICAgIGhhc0NvcnJlY3RQYXJlbnQgPSAoaXNWZXJ0aWNhbCAmJiB0aGlzLnBhcmVudC5pc0NvbHVtbikgfHwgKGlzSG9yaXpvbnRhbCAmJiB0aGlzLnBhcmVudC5pc1JvdyksXG4gICAgICAgICAgICB0eXBlID0gaXNWZXJ0aWNhbCA/ICdjb2x1bW4nIDogJ3JvdycsXG4gICAgICAgICAgICBkaW1lbnNpb24gPSBpc1ZlcnRpY2FsID8gJ2hlaWdodCcgOiAnd2lkdGgnLFxuICAgICAgICAgICAgaW5kZXgsXG4gICAgICAgICAgICBzdGFjayxcbiAgICAgICAgICAgIHJvd09yQ29sdW1uO1xuXG4gICAgICAgIC8qXG4gICAgICAgICAqIFRoZSBjb250ZW50IGl0ZW0gY2FuIGJlIGVpdGhlciBhIGNvbXBvbmVudCBvciBhIHN0YWNrLiBJZiBpdCBpcyBhIGNvbXBvbmVudCwgd3JhcCBpdCBpbnRvIGEgc3RhY2tcbiAgICAgICAgICovXG4gICAgICAgIGlmIChjb250ZW50SXRlbS5pc0NvbXBvbmVudCkge1xuICAgICAgICAgICAgc3RhY2sgPSB0aGlzLmxheW91dE1hbmFnZXIuY3JlYXRlQ29udGVudEl0ZW0oe1xuICAgICAgICAgICAgICAgIHR5cGU6ICdzdGFjaycsXG4gICAgICAgICAgICAgICAgaGVhZGVyOiBjb250ZW50SXRlbS5jb25maWcuaGVhZGVyIHx8IHt9XG4gICAgICAgICAgICB9LCB0aGlzKTtcbiAgICAgICAgICAgIHN0YWNrLl8kaW5pdCgpO1xuICAgICAgICAgICAgc3RhY2suYWRkQ2hpbGQoY29udGVudEl0ZW0pO1xuICAgICAgICAgICAgY29udGVudEl0ZW0gPSBzdGFjaztcbiAgICAgICAgfVxuXG5cbiAgICAgICAgLypcbiAgICAgICAgICogSWYgdGhlIGNvbnRlbnRJdGVtIHRoYXQncyBiZWluZyBkcm9wcGVkIGlzIG5vdCBkcm9wcGVkIG9uIGEgU3RhY2sgKGNhc2VzIHdoaWNoIGp1c3QgcGFzc2VkIGFib3ZlIGFuZCBcbiAgICAgICAgICogd2hpY2ggd291bGQgd3JhcCB0aGUgY29udGVudEl0ZW0gaW4gYSBTdGFjaykgd2UgbmVlZCB0byBjaGVjayB3aGV0aGVyIGNvbnRlbnRJdGVtIGlzIGEgUm93T3JDb2x1bW4uXG4gICAgICAgICAqIElmIGl0IGlzLCB3ZSBuZWVkIHRvIHJlLXdyYXAgaXQgaW4gYSBTdGFjayBsaWtlIGl0IHdhcyB3aGVuIGl0IHdhcyBkcmFnZ2VkIGJ5IGl0cyBUYWIgKGl0IHdhcyBkcmFnZ2VkISkuXG4gICAgICAgICAqL1xuICAgICAgICBpZihjb250ZW50SXRlbS5jb25maWcudHlwZSA9PT0gJ3JvdycgfHwgY29udGVudEl0ZW0uY29uZmlnLnR5cGUgPT09ICdjb2x1bW4nKXtcbiAgICAgICAgICAgIHN0YWNrID0gdGhpcy5sYXlvdXRNYW5hZ2VyLmNyZWF0ZUNvbnRlbnRJdGVtKHtcbiAgICAgICAgICAgICAgICB0eXBlOiAnc3RhY2snXG4gICAgICAgICAgICB9LCB0aGlzKVxuICAgICAgICAgICAgc3RhY2suYWRkQ2hpbGQoY29udGVudEl0ZW0pXG4gICAgICAgICAgICBjb250ZW50SXRlbSA9IHN0YWNrXG4gICAgICAgIH1cblxuICAgICAgICAvKlxuICAgICAgICAgKiBJZiB0aGUgaXRlbSBpcyBkcm9wcGVkIG9uIHRvcCBvciBib3R0b20gb2YgYSBjb2x1bW4gb3IgbGVmdCBhbmQgcmlnaHQgb2YgYSByb3csIGl0J3MgYWxyZWFkeVxuICAgICAgICAgKiBsYXlkIG91dCBpbiB0aGUgY29ycmVjdCB3YXkuIEp1c3QgYWRkIGl0IGFzIGEgY2hpbGRcbiAgICAgICAgICovXG4gICAgICAgIGlmIChoYXNDb3JyZWN0UGFyZW50KSB7XG4gICAgICAgICAgICBpbmRleCA9IGluZGV4T2YodGhpcywgdGhpcy5wYXJlbnQuY29udGVudEl0ZW1zKTtcbiAgICAgICAgICAgIHRoaXMucGFyZW50LmFkZENoaWxkKGNvbnRlbnRJdGVtLCBpbnNlcnRCZWZvcmUgPyBpbmRleCA6IGluZGV4ICsgMSwgdHJ1ZSk7XG4gICAgICAgICAgICB0aGlzLmNvbmZpZ1tkaW1lbnNpb25dICo9IDAuNTtcbiAgICAgICAgICAgIGNvbnRlbnRJdGVtLmNvbmZpZ1tkaW1lbnNpb25dID0gdGhpcy5jb25maWdbZGltZW5zaW9uXTtcbiAgICAgICAgICAgIHRoaXMucGFyZW50LmNhbGxEb3dud2FyZHMoJ3NldFNpemUnKTtcbiAgICAgICAgICAgIC8qXG4gICAgICAgICAgICAgKiBUaGlzIGhhbmRsZXMgaXRlbXMgdGhhdCBhcmUgZHJvcHBlZCBvbiB0b3Agb3IgYm90dG9tIG9mIGEgcm93IG9yIGxlZnQgLyByaWdodCBvZiBhIGNvbHVtbi4gV2UgbmVlZFxuICAgICAgICAgICAgICogdG8gY3JlYXRlIHRoZSBhcHByb3ByaWF0ZSBjb250ZW50SXRlbSBmb3IgdGhlbSB0byBsaXZlIGluXG4gICAgICAgICAgICAgKi9cbiAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgIHR5cGUgPSBpc1ZlcnRpY2FsID8gJ2NvbHVtbicgOiAncm93JztcbiAgICAgICAgICAgIHJvd09yQ29sdW1uID0gdGhpcy5sYXlvdXRNYW5hZ2VyLmNyZWF0ZUNvbnRlbnRJdGVtKHtcbiAgICAgICAgICAgICAgICB0eXBlOiB0eXBlXG4gICAgICAgICAgICB9LCB0aGlzKTtcbiAgICAgICAgICAgIHRoaXMucGFyZW50LnJlcGxhY2VDaGlsZCh0aGlzLCByb3dPckNvbHVtbik7XG5cbiAgICAgICAgICAgIHJvd09yQ29sdW1uLmFkZENoaWxkKGNvbnRlbnRJdGVtLCBpbnNlcnRCZWZvcmUgPyAwIDogdW5kZWZpbmVkLCB0cnVlKTtcbiAgICAgICAgICAgIHJvd09yQ29sdW1uLmFkZENoaWxkKHRoaXMsIGluc2VydEJlZm9yZSA/IHVuZGVmaW5lZCA6IDAsIHRydWUpO1xuXG4gICAgICAgICAgICB0aGlzLmNvbmZpZ1tkaW1lbnNpb25dID0gNTA7XG4gICAgICAgICAgICBjb250ZW50SXRlbS5jb25maWdbZGltZW5zaW9uXSA9IDUwO1xuICAgICAgICAgICAgcm93T3JDb2x1bW4uY2FsbERvd253YXJkcygnc2V0U2l6ZScpO1xuICAgICAgICB9XG4gICAgICAgIHRoaXMucGFyZW50Ll92YWxpZGF0ZURvY2tpbmcoKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBJZiB0aGUgdXNlciBob3ZlcnMgYWJvdmUgdGhlIGhlYWRlciBwYXJ0IG9mIHRoZSBzdGFjaywgaW5kaWNhdGUgZHJvcCBwb3NpdGlvbnMgZm9yIHRhYnMuXG4gICAgICogb3RoZXJ3aXNlIGluZGljYXRlIHdoaWNoIHNlZ21lbnQgb2YgdGhlIGJvZHkgdGhlIGRyYWdnZWQgaXRlbSB3b3VsZCBiZSBkcm9wcGVkIG9uXG4gICAgICpcbiAgICAgKiBAcGFyYW0gICAge0ludH0geCBBYnNvbHV0ZSBTY3JlZW4gWFxuICAgICAqIEBwYXJhbSAgICB7SW50fSB5IEFic29sdXRlIFNjcmVlbiBZXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfJGhpZ2hsaWdodERyb3Bab25lKHgsIHkpIHtcbiAgICAgICAgdmFyIHNlZ21lbnQsIGFyZWE7XG5cbiAgICAgICAgZm9yIChzZWdtZW50IGluIHRoaXMuX2NvbnRlbnRBcmVhRGltZW5zaW9ucykge1xuICAgICAgICAgICAgYXJlYSA9IHRoaXMuX2NvbnRlbnRBcmVhRGltZW5zaW9uc1tzZWdtZW50XS5ob3ZlckFyZWE7XG5cbiAgICAgICAgICAgIGlmIChhcmVhLngxIDwgeCAmJiBhcmVhLngyID4geCAmJiBhcmVhLnkxIDwgeSAmJiBhcmVhLnkyID4geSkge1xuXG4gICAgICAgICAgICAgICAgaWYgKHNlZ21lbnQgPT09ICdoZWFkZXInKSB7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMuX2Ryb3BTZWdtZW50ID0gJ2hlYWRlcic7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMuX2hpZ2hsaWdodEhlYWRlckRyb3Bab25lKHRoaXMuX3NpZGVkID8geSA6IHgpO1xuICAgICAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgICAgIHRoaXMuX3Jlc2V0SGVhZGVyRHJvcFpvbmUoKTtcbiAgICAgICAgICAgICAgICAgICAgdGhpcy5faGlnaGxpZ2h0Qm9keURyb3Bab25lKHNlZ21lbnQpO1xuICAgICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH1cblxuICAgIF8kZ2V0QXJlYSgpIHtcbiAgICAgICAgaWYgKHRoaXMuZWxlbWVudC5jc3MoJ2Rpc3BsYXknKSA9PT0gJ25vbmUnKSB7XG4gICAgICAgICAgICByZXR1cm4gbnVsbDtcbiAgICAgICAgfVxuXG4gICAgICAgIHZhciBnZXRBcmVhID0gQWJzdHJhY3RDb250ZW50SXRlbS5wcm90b3R5cGUuXyRnZXRBcmVhLFxuICAgICAgICAgICAgaGVhZGVyQXJlYSA9IGdldEFyZWEuY2FsbCh0aGlzLCB0aGlzLmhlYWRlci5lbGVtZW50KSxcbiAgICAgICAgICAgIGNvbnRlbnRBcmVhID0gZ2V0QXJlYS5jYWxsKHRoaXMsIHRoaXMuY2hpbGRFbGVtZW50Q29udGFpbmVyKSxcbiAgICAgICAgICAgIGNvbnRlbnRXaWR0aCA9IGNvbnRlbnRBcmVhLngyIC0gY29udGVudEFyZWEueDEsXG4gICAgICAgICAgICBjb250ZW50SGVpZ2h0ID0gY29udGVudEFyZWEueTIgLSBjb250ZW50QXJlYS55MTtcblxuICAgICAgICB0aGlzLl9jb250ZW50QXJlYURpbWVuc2lvbnMgPSB7XG4gICAgICAgICAgICBoZWFkZXI6IHtcbiAgICAgICAgICAgICAgICBob3ZlckFyZWE6IHtcbiAgICAgICAgICAgICAgICAgICAgeDE6IGhlYWRlckFyZWEueDEsXG4gICAgICAgICAgICAgICAgICAgIHkxOiBoZWFkZXJBcmVhLnkxLFxuICAgICAgICAgICAgICAgICAgICB4MjogaGVhZGVyQXJlYS54MixcbiAgICAgICAgICAgICAgICAgICAgeTI6IGhlYWRlckFyZWEueTJcbiAgICAgICAgICAgICAgICB9LFxuICAgICAgICAgICAgICAgIGhpZ2hsaWdodEFyZWE6IHtcbiAgICAgICAgICAgICAgICAgICAgeDE6IGhlYWRlckFyZWEueDEsXG4gICAgICAgICAgICAgICAgICAgIHkxOiBoZWFkZXJBcmVhLnkxLFxuICAgICAgICAgICAgICAgICAgICB4MjogaGVhZGVyQXJlYS54MixcbiAgICAgICAgICAgICAgICAgICAgeTI6IGhlYWRlckFyZWEueTJcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG4gICAgICAgIH07XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIElmIHRoaXMgU3RhY2sgaXMgYSBwYXJlbnQgdG8gcm93cywgY29sdW1ucyBvciBvdGhlciBzdGFja3Mgb25seSBpdHNcbiAgICAgICAgICogaGVhZGVyIGlzIGEgdmFsaWQgZHJvcHpvbmUuXG4gICAgICAgICAqL1xuICAgICAgICBpZiAodGhpcy5fYWN0aXZlQ29udGVudEl0ZW0gJiYgdGhpcy5fYWN0aXZlQ29udGVudEl0ZW0uaXNDb21wb25lbnQgPT09IGZhbHNlKSB7XG4gICAgICAgICAgICByZXR1cm4gaGVhZGVyQXJlYTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBIaWdobGlnaHQgdGhlIGVudGlyZSBib2R5IGlmIHRoZSBzdGFjayBpcyBlbXB0eVxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHRoaXMuY29udGVudEl0ZW1zLmxlbmd0aCA9PT0gMCkge1xuXG4gICAgICAgICAgICB0aGlzLl9jb250ZW50QXJlYURpbWVuc2lvbnMuYm9keSA9IHtcbiAgICAgICAgICAgICAgICBob3ZlckFyZWE6IHtcbiAgICAgICAgICAgICAgICAgICAgeDE6IGNvbnRlbnRBcmVhLngxLFxuICAgICAgICAgICAgICAgICAgICB5MTogY29udGVudEFyZWEueTEsXG4gICAgICAgICAgICAgICAgICAgIHgyOiBjb250ZW50QXJlYS54MixcbiAgICAgICAgICAgICAgICAgICAgeTI6IGNvbnRlbnRBcmVhLnkyXG4gICAgICAgICAgICAgICAgfSxcbiAgICAgICAgICAgICAgICBoaWdobGlnaHRBcmVhOiB7XG4gICAgICAgICAgICAgICAgICAgIHgxOiBjb250ZW50QXJlYS54MSxcbiAgICAgICAgICAgICAgICAgICAgeTE6IGNvbnRlbnRBcmVhLnkxLFxuICAgICAgICAgICAgICAgICAgICB4MjogY29udGVudEFyZWEueDIsXG4gICAgICAgICAgICAgICAgICAgIHkyOiBjb250ZW50QXJlYS55MlxuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH07XG5cbiAgICAgICAgICAgIHJldHVybiBnZXRBcmVhLmNhbGwodGhpcywgdGhpcy5lbGVtZW50KTtcbiAgICAgICAgfVxuXG4gICAgICAgIHRoaXMuX2NvbnRlbnRBcmVhRGltZW5zaW9ucy5sZWZ0ID0ge1xuICAgICAgICAgICAgaG92ZXJBcmVhOiB7XG4gICAgICAgICAgICAgICAgeDE6IGNvbnRlbnRBcmVhLngxLFxuICAgICAgICAgICAgICAgIHkxOiBjb250ZW50QXJlYS55MSxcbiAgICAgICAgICAgICAgICB4MjogY29udGVudEFyZWEueDEgKyBjb250ZW50V2lkdGggKiAwLjI1LFxuICAgICAgICAgICAgICAgIHkyOiBjb250ZW50QXJlYS55MlxuICAgICAgICAgICAgfSxcbiAgICAgICAgICAgIGhpZ2hsaWdodEFyZWE6IHtcbiAgICAgICAgICAgICAgICB4MTogY29udGVudEFyZWEueDEsXG4gICAgICAgICAgICAgICAgeTE6IGNvbnRlbnRBcmVhLnkxLFxuICAgICAgICAgICAgICAgIHgyOiBjb250ZW50QXJlYS54MSArIGNvbnRlbnRXaWR0aCAqIDAuNSxcbiAgICAgICAgICAgICAgICB5MjogY29udGVudEFyZWEueTJcbiAgICAgICAgICAgIH1cbiAgICAgICAgfTtcblxuICAgICAgICB0aGlzLl9jb250ZW50QXJlYURpbWVuc2lvbnMudG9wID0ge1xuICAgICAgICAgICAgaG92ZXJBcmVhOiB7XG4gICAgICAgICAgICAgICAgeDE6IGNvbnRlbnRBcmVhLngxICsgY29udGVudFdpZHRoICogMC4yNSxcbiAgICAgICAgICAgICAgICB5MTogY29udGVudEFyZWEueTEsXG4gICAgICAgICAgICAgICAgeDI6IGNvbnRlbnRBcmVhLngxICsgY29udGVudFdpZHRoICogMC43NSxcbiAgICAgICAgICAgICAgICB5MjogY29udGVudEFyZWEueTEgKyBjb250ZW50SGVpZ2h0ICogMC41XG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgaGlnaGxpZ2h0QXJlYToge1xuICAgICAgICAgICAgICAgIHgxOiBjb250ZW50QXJlYS54MSxcbiAgICAgICAgICAgICAgICB5MTogY29udGVudEFyZWEueTEsXG4gICAgICAgICAgICAgICAgeDI6IGNvbnRlbnRBcmVhLngyLFxuICAgICAgICAgICAgICAgIHkyOiBjb250ZW50QXJlYS55MSArIGNvbnRlbnRIZWlnaHQgKiAwLjVcbiAgICAgICAgICAgIH1cbiAgICAgICAgfTtcblxuICAgICAgICB0aGlzLl9jb250ZW50QXJlYURpbWVuc2lvbnMucmlnaHQgPSB7XG4gICAgICAgICAgICBob3ZlckFyZWE6IHtcbiAgICAgICAgICAgICAgICB4MTogY29udGVudEFyZWEueDEgKyBjb250ZW50V2lkdGggKiAwLjc1LFxuICAgICAgICAgICAgICAgIHkxOiBjb250ZW50QXJlYS55MSxcbiAgICAgICAgICAgICAgICB4MjogY29udGVudEFyZWEueDIsXG4gICAgICAgICAgICAgICAgeTI6IGNvbnRlbnRBcmVhLnkyXG4gICAgICAgICAgICB9LFxuICAgICAgICAgICAgaGlnaGxpZ2h0QXJlYToge1xuICAgICAgICAgICAgICAgIHgxOiBjb250ZW50QXJlYS54MSArIGNvbnRlbnRXaWR0aCAqIDAuNSxcbiAgICAgICAgICAgICAgICB5MTogY29udGVudEFyZWEueTEsXG4gICAgICAgICAgICAgICAgeDI6IGNvbnRlbnRBcmVhLngyLFxuICAgICAgICAgICAgICAgIHkyOiBjb250ZW50QXJlYS55MlxuICAgICAgICAgICAgfVxuICAgICAgICB9O1xuXG4gICAgICAgIHRoaXMuX2NvbnRlbnRBcmVhRGltZW5zaW9ucy5ib3R0b20gPSB7XG4gICAgICAgICAgICBob3ZlckFyZWE6IHtcbiAgICAgICAgICAgICAgICB4MTogY29udGVudEFyZWEueDEgKyBjb250ZW50V2lkdGggKiAwLjI1LFxuICAgICAgICAgICAgICAgIHkxOiBjb250ZW50QXJlYS55MSArIGNvbnRlbnRIZWlnaHQgKiAwLjUsXG4gICAgICAgICAgICAgICAgeDI6IGNvbnRlbnRBcmVhLngxICsgY29udGVudFdpZHRoICogMC43NSxcbiAgICAgICAgICAgICAgICB5MjogY29udGVudEFyZWEueTJcbiAgICAgICAgICAgIH0sXG4gICAgICAgICAgICBoaWdobGlnaHRBcmVhOiB7XG4gICAgICAgICAgICAgICAgeDE6IGNvbnRlbnRBcmVhLngxLFxuICAgICAgICAgICAgICAgIHkxOiBjb250ZW50QXJlYS55MSArIGNvbnRlbnRIZWlnaHQgKiAwLjUsXG4gICAgICAgICAgICAgICAgeDI6IGNvbnRlbnRBcmVhLngyLFxuICAgICAgICAgICAgICAgIHkyOiBjb250ZW50QXJlYS55MlxuICAgICAgICAgICAgfVxuICAgICAgICB9O1xuXG4gICAgICAgIHJldHVybiBnZXRBcmVhLmNhbGwodGhpcywgdGhpcy5lbGVtZW50KTtcbiAgICB9XG5cbiAgICBfaGlnaGxpZ2h0SGVhZGVyRHJvcFpvbmUoeCkge1xuICAgICAgICB2YXIgaSxcbiAgICAgICAgICAgIHRhYkVsZW1lbnQsXG4gICAgICAgICAgICB0YWJzTGVuZ3RoID0gdGhpcy5oZWFkZXIudGFicy5sZW5ndGgsXG4gICAgICAgICAgICBpc0Fib3ZlVGFiID0gZmFsc2UsXG4gICAgICAgICAgICB0YWJUb3AsXG4gICAgICAgICAgICB0YWJMZWZ0LFxuICAgICAgICAgICAgb2Zmc2V0LFxuICAgICAgICAgICAgcGxhY2VIb2xkZXJMZWZ0LFxuICAgICAgICAgICAgaGVhZGVyT2Zmc2V0LFxuICAgICAgICAgICAgdGFiV2lkdGgsXG4gICAgICAgICAgICBoYWxmWDtcblxuICAgICAgICAvLyBFbXB0eSBzdGFja1xuICAgICAgICBpZiAodGFic0xlbmd0aCA9PT0gMCkge1xuICAgICAgICAgICAgaGVhZGVyT2Zmc2V0ID0gdGhpcy5oZWFkZXIuZWxlbWVudC5vZmZzZXQoKTtcblxuICAgICAgICAgICAgdGhpcy5sYXlvdXRNYW5hZ2VyLmRyb3BUYXJnZXRJbmRpY2F0b3IuaGlnaGxpZ2h0QXJlYSh7XG4gICAgICAgICAgICAgICAgeDE6IGhlYWRlck9mZnNldC5sZWZ0LFxuICAgICAgICAgICAgICAgIHgyOiBoZWFkZXJPZmZzZXQubGVmdCArIDEwMCxcbiAgICAgICAgICAgICAgICB5MTogaGVhZGVyT2Zmc2V0LnRvcCArIHRoaXMuaGVhZGVyLmVsZW1lbnQuaGVpZ2h0KCkgLSAyMCxcbiAgICAgICAgICAgICAgICB5MjogaGVhZGVyT2Zmc2V0LnRvcCArIHRoaXMuaGVhZGVyLmVsZW1lbnQuaGVpZ2h0KClcbiAgICAgICAgICAgIH0pO1xuXG4gICAgICAgICAgICByZXR1cm47XG4gICAgICAgIH1cblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGFic0xlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICB0YWJFbGVtZW50ID0gdGhpcy5oZWFkZXIudGFic1tpXS5lbGVtZW50O1xuICAgICAgICAgICAgb2Zmc2V0ID0gdGFiRWxlbWVudC5vZmZzZXQoKTtcbiAgICAgICAgICAgIGlmICh0aGlzLl9zaWRlZCkge1xuICAgICAgICAgICAgICAgIHRhYkxlZnQgPSBvZmZzZXQudG9wO1xuICAgICAgICAgICAgICAgIHRhYlRvcCA9IG9mZnNldC5sZWZ0O1xuICAgICAgICAgICAgICAgIHRhYldpZHRoID0gdGFiRWxlbWVudC5oZWlnaHQoKTtcbiAgICAgICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICAgICAgdGFiTGVmdCA9IG9mZnNldC5sZWZ0O1xuICAgICAgICAgICAgICAgIHRhYlRvcCA9IG9mZnNldC50b3A7XG4gICAgICAgICAgICAgICAgdGFiV2lkdGggPSB0YWJFbGVtZW50LndpZHRoKCk7XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGlmICh4ID4gdGFiTGVmdCAmJiB4IDwgdGFiTGVmdCArIHRhYldpZHRoKSB7XG4gICAgICAgICAgICAgICAgaXNBYm92ZVRhYiA9IHRydWU7XG4gICAgICAgICAgICAgICAgYnJlYWs7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cblxuICAgICAgICBpZiAoaXNBYm92ZVRhYiA9PT0gZmFsc2UgJiYgeCA8IHRhYkxlZnQpIHtcbiAgICAgICAgICAgIHJldHVybjtcbiAgICAgICAgfVxuXG4gICAgICAgIGhhbGZYID0gdGFiTGVmdCArIHRhYldpZHRoIC8gMjtcblxuICAgICAgICBpZiAoeCA8IGhhbGZYKSB7XG4gICAgICAgICAgICB0aGlzLl9kcm9wSW5kZXggPSBpO1xuICAgICAgICAgICAgdGFiRWxlbWVudC5iZWZvcmUodGhpcy5sYXlvdXRNYW5hZ2VyLnRhYkRyb3BQbGFjZWhvbGRlcik7XG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICB0aGlzLl9kcm9wSW5kZXggPSBNYXRoLm1pbihpICsgMSwgdGFic0xlbmd0aCk7XG4gICAgICAgICAgICB0YWJFbGVtZW50LmFmdGVyKHRoaXMubGF5b3V0TWFuYWdlci50YWJEcm9wUGxhY2Vob2xkZXIpO1xuICAgICAgICB9XG5cblxuICAgICAgICBpZiAodGhpcy5fc2lkZWQpIHtcbiAgICAgICAgICAgIHZhciBwbGFjZUhvbGRlclRvcCA9IHRoaXMubGF5b3V0TWFuYWdlci50YWJEcm9wUGxhY2Vob2xkZXIub2Zmc2V0KCkudG9wO1xuICAgICAgICAgICAgdGhpcy5sYXlvdXRNYW5hZ2VyLmRyb3BUYXJnZXRJbmRpY2F0b3IuaGlnaGxpZ2h0QXJlYSh7XG4gICAgICAgICAgICAgICAgeDE6IHRhYlRvcCxcbiAgICAgICAgICAgICAgICB4MjogdGFiVG9wICsgdGFiRWxlbWVudC5pbm5lckhlaWdodCgpLFxuICAgICAgICAgICAgICAgIHkxOiBwbGFjZUhvbGRlclRvcCxcbiAgICAgICAgICAgICAgICB5MjogcGxhY2VIb2xkZXJUb3AgKyB0aGlzLmxheW91dE1hbmFnZXIudGFiRHJvcFBsYWNlaG9sZGVyLndpZHRoKClcbiAgICAgICAgICAgIH0pO1xuICAgICAgICAgICAgcmV0dXJuO1xuICAgICAgICB9XG4gICAgICAgIHBsYWNlSG9sZGVyTGVmdCA9IHRoaXMubGF5b3V0TWFuYWdlci50YWJEcm9wUGxhY2Vob2xkZXIub2Zmc2V0KCkubGVmdDtcblxuICAgICAgICB0aGlzLmxheW91dE1hbmFnZXIuZHJvcFRhcmdldEluZGljYXRvci5oaWdobGlnaHRBcmVhKHtcbiAgICAgICAgICAgIHgxOiBwbGFjZUhvbGRlckxlZnQsXG4gICAgICAgICAgICB4MjogcGxhY2VIb2xkZXJMZWZ0ICsgdGhpcy5sYXlvdXRNYW5hZ2VyLnRhYkRyb3BQbGFjZWhvbGRlci53aWR0aCgpLFxuICAgICAgICAgICAgeTE6IHRhYlRvcCxcbiAgICAgICAgICAgIHkyOiB0YWJUb3AgKyB0YWJFbGVtZW50LmlubmVySGVpZ2h0KClcbiAgICAgICAgfSk7XG4gICAgfVxuXG4gICAgX3Jlc2V0SGVhZGVyRHJvcFpvbmUoKSB7XG4gICAgICAgIHRoaXMubGF5b3V0TWFuYWdlci50YWJEcm9wUGxhY2Vob2xkZXIucmVtb3ZlKCk7XG4gICAgfVxuXG4gICAgdG9nZ2xlTWF4aW1pc2UoZSkge1xuICAgICAgICBpZiAoIXRoaXMuaXNNYXhpbWlzZWQpXG4gICAgICAgICAgICB0aGlzLmRvY2soZmFsc2UpO1xuICAgICAgICBBYnN0cmFjdENvbnRlbnRJdGVtLnByb3RvdHlwZS50b2dnbGVNYXhpbWlzZS5jYWxsKHRoaXMsIGUpO1xuICAgIH1cblxuICAgIF9zZXR1cEhlYWRlclBvc2l0aW9uKCkge1xuICAgICAgICB2YXIgc2lkZSA9IFsncmlnaHQnLCAnbGVmdCcsICdib3R0b20nXS5pbmRleE9mKHRoaXMuX2hlYWRlci5zaG93KSA+PSAwICYmIHRoaXMuX2hlYWRlci5zaG93O1xuICAgICAgICB0aGlzLmhlYWRlci5lbGVtZW50LnRvZ2dsZSghIXRoaXMuX2hlYWRlci5zaG93KTtcbiAgICAgICAgdGhpcy5fc2lkZSA9IHNpZGU7XG4gICAgICAgIHRoaXMuX3NpZGVkID0gWydyaWdodCcsICdsZWZ0J10uaW5kZXhPZih0aGlzLl9zaWRlKSA+PSAwO1xuICAgICAgICB0aGlzLmVsZW1lbnQucmVtb3ZlQ2xhc3MoJ2xtX2xlZnQgbG1fcmlnaHQgbG1fYm90dG9tJyk7XG4gICAgICAgIGlmICh0aGlzLl9zaWRlKVxuICAgICAgICAgICAgdGhpcy5lbGVtZW50LmFkZENsYXNzKCdsbV8nICsgdGhpcy5fc2lkZSk7XG4gICAgICAgIGlmICh0aGlzLmVsZW1lbnQuZmluZCgnLmxtX2hlYWRlcicpLmxlbmd0aCAmJiB0aGlzLmNoaWxkRWxlbWVudENvbnRhaW5lcikge1xuICAgICAgICAgICAgdmFyIGhlYWRlclBvc2l0aW9uID0gWydyaWdodCcsICdib3R0b20nXS5pbmRleE9mKHRoaXMuX3NpZGUpID49IDAgPyAnYmVmb3JlJyA6ICdhZnRlcic7XG4gICAgICAgICAgICB0aGlzLmhlYWRlci5lbGVtZW50W2hlYWRlclBvc2l0aW9uXSh0aGlzLmNoaWxkRWxlbWVudENvbnRhaW5lcik7XG4gICAgICAgICAgICB0aGlzLmNhbGxEb3dud2FyZHMoJ3NldFNpemUnKTtcbiAgICAgICAgfVxuICAgIH1cblxuICAgIF9oaWdobGlnaHRCb2R5RHJvcFpvbmUoc2VnbWVudCkge1xuICAgICAgICB2YXIgaGlnaGxpZ2h0QXJlYSA9IHRoaXMuX2NvbnRlbnRBcmVhRGltZW5zaW9uc1tzZWdtZW50XS5oaWdobGlnaHRBcmVhO1xuICAgICAgICB0aGlzLmxheW91dE1hbmFnZXIuZHJvcFRhcmdldEluZGljYXRvci5oaWdobGlnaHRBcmVhKGhpZ2hsaWdodEFyZWEpO1xuICAgICAgICB0aGlzLl9kcm9wU2VnbWVudCA9IHNlZ21lbnQ7XG4gICAgfVxufVxuIiwiXG5cbmV4cG9ydCBkZWZhdWx0IGNsYXNzIEJ1YmJsaW5nRXZlbnQge1xuICAgIGNvbnN0cnVjdG9yKG5hbWUsIG9yaWdpbikge1xuICAgICAgICB0aGlzLm5hbWUgPSBuYW1lO1xuICAgICAgICB0aGlzLm9yaWdpbiA9IG9yaWdpbjtcbiAgICAgICAgdGhpcy5pc1Byb3BhZ2F0aW9uU3RvcHBlZCA9IGZhbHNlO1xuICAgIH1cblxuICAgIHN0b3BQcm9wYWdhdGlvbigpIHtcbiAgICAgICAgdGhpcy5pc1Byb3BhZ2F0aW9uU3RvcHBlZCA9IHRydWU7XG4gICAgfVxufVxuIiwiaW1wb3J0IHtcbiAgICBpbmRleE9mXG59IGZyb20gJy4uL3V0aWxzL3V0aWxzJ1xuXG4vKipcbiAqIE1pbmlmaWVzIGFuZCB1bm1pbmlmaWVzIGNvbmZpZ3MgYnkgcmVwbGFjaW5nIGZyZXF1ZW50IGtleXNcbiAqIGFuZCB2YWx1ZXMgd2l0aCBvbmUgbGV0dGVyIHN1YnN0aXR1dGVzLiBDb25maWcgb3B0aW9ucyBtdXN0XG4gKiByZXRhaW4gYXJyYXkgcG9zaXRpb24vaW5kZXgsIGFkZCBuZXcgb3B0aW9ucyBhdCB0aGUgZW5kLlxuICpcbiAqIEBjb25zdHJ1Y3RvclxuICovXG5cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgQ29uZmlnTWluaWZpZXIge1xuICAgIGNvbnN0cnVjdG9yKCkge1xuICAgICAgICB0aGlzLl9rZXlzID0gW1xuICAgICAgICAgICAgJ3NldHRpbmdzJyxcbiAgICAgICAgICAgICdoYXNIZWFkZXJzJyxcbiAgICAgICAgICAgICdjb25zdHJhaW5EcmFnVG9Db250YWluZXInLFxuICAgICAgICAgICAgJ3NlbGVjdGlvbkVuYWJsZWQnLFxuICAgICAgICAgICAgJ2RpbWVuc2lvbnMnLFxuICAgICAgICAgICAgJ2JvcmRlcldpZHRoJyxcbiAgICAgICAgICAgICdtaW5JdGVtSGVpZ2h0JyxcbiAgICAgICAgICAgICdtaW5JdGVtV2lkdGgnLFxuICAgICAgICAgICAgJ2hlYWRlckhlaWdodCcsXG4gICAgICAgICAgICAnZHJhZ1Byb3h5V2lkdGgnLFxuICAgICAgICAgICAgJ2RyYWdQcm94eUhlaWdodCcsXG4gICAgICAgICAgICAnbGFiZWxzJyxcbiAgICAgICAgICAgICdjbG9zZScsXG4gICAgICAgICAgICAnbWF4aW1pc2UnLFxuICAgICAgICAgICAgJ21pbmltaXNlJyxcbiAgICAgICAgICAgICdwb3BvdXQnLFxuICAgICAgICAgICAgJ2NvbnRlbnQnLFxuICAgICAgICAgICAgJ2NvbXBvbmVudE5hbWUnLFxuICAgICAgICAgICAgJ2NvbXBvbmVudFN0YXRlJyxcbiAgICAgICAgICAgICdpZCcsXG4gICAgICAgICAgICAnd2lkdGgnLFxuICAgICAgICAgICAgJ3R5cGUnLFxuICAgICAgICAgICAgJ2hlaWdodCcsXG4gICAgICAgICAgICAnaXNDbG9zYWJsZScsXG4gICAgICAgICAgICAndGl0bGUnLFxuICAgICAgICAgICAgJ3BvcG91dFdob2xlU3RhY2snLFxuICAgICAgICAgICAgJ29wZW5Qb3BvdXRzJyxcbiAgICAgICAgICAgICdwYXJlbnRJZCcsXG4gICAgICAgICAgICAnYWN0aXZlSXRlbUluZGV4JyxcbiAgICAgICAgICAgICdyZW9yZGVyRW5hYmxlZCcsXG4gICAgICAgICAgICAnYm9yZGVyR3JhYldpZHRoJyxcblxuXG5cblxuICAgICAgICAgICAgLy9NYXhpbXVtIDM2IGVudHJpZXMsIGRvIG5vdCBjcm9zcyB0aGlzIGxpbmUhXG4gICAgICAgIF07XG4gICAgICAgIGlmICh0aGlzLl9rZXlzLmxlbmd0aCA+IDM2KSB7XG4gICAgICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ1RvbyBtYW55IGtleXMgaW4gY29uZmlnIG1pbmlmaWVyIG1hcCcpO1xuICAgICAgICB9XG5cbiAgICAgICAgdGhpcy5fdmFsdWVzID0gW1xuICAgICAgICAgICAgdHJ1ZSxcbiAgICAgICAgICAgIGZhbHNlLFxuICAgICAgICAgICAgJ3JvdycsXG4gICAgICAgICAgICAnY29sdW1uJyxcbiAgICAgICAgICAgICdzdGFjaycsXG4gICAgICAgICAgICAnY29tcG9uZW50JyxcbiAgICAgICAgICAgICdjbG9zZScsXG4gICAgICAgICAgICAnbWF4aW1pc2UnLFxuICAgICAgICAgICAgJ21pbmltaXNlJyxcbiAgICAgICAgICAgICdvcGVuIGluIG5ldyB3aW5kb3cnXG4gICAgICAgIF07XG4gICAgfVxuXG5cbiAgICAvKipcbiAgICAgKiBUYWtlcyBhIEdvbGRlbkxheW91dCBjb25maWd1cmF0aW9uIG9iamVjdCBhbmRcbiAgICAgKiByZXBsYWNlcyBpdHMga2V5cyBhbmQgdmFsdWVzIHJlY3Vyc2l2ZWx5IHdpdGhcbiAgICAgKiBvbmUgbGV0dGVyIGNvdW50ZXJwYXJ0c1xuICAgICAqXG4gICAgICogQHBhcmFtICAge09iamVjdH0gY29uZmlnIEEgR29sZGVuTGF5b3V0IGNvbmZpZyBvYmplY3RcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHtPYmplY3R9IG1pbmlmaWVkIGNvbmZpZ1xuICAgICAqL1xuICAgIG1pbmlmeUNvbmZpZyhjb25maWcpIHtcbiAgICAgICAgdmFyIG1pbiA9IHt9O1xuICAgICAgICB0aGlzLl9uZXh0TGV2ZWwoY29uZmlnLCBtaW4sICdfbWluJyk7XG4gICAgICAgIHJldHVybiBtaW47XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogVGFrZXMgYSBjb25maWd1cmF0aW9uIE9iamVjdCB0aGF0IHdhcyBwcmV2aW91c2x5IG1pbmlmaWVkXG4gICAgICogdXNpbmcgbWluaWZ5Q29uZmlnIGFuZCByZXR1cm5zIGl0cyBvcmlnaW5hbCB2ZXJzaW9uXG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7T2JqZWN0fSBtaW5pZmllZENvbmZpZ1xuICAgICAqXG4gICAgICogQHJldHVybnMge09iamVjdH0gdGhlIG9yaWdpbmFsIGNvbmZpZ3VyYXRpb25cbiAgICAgKi9cbiAgICB1bm1pbmlmeUNvbmZpZyhtaW5pZmllZENvbmZpZykge1xuICAgICAgICB2YXIgb3JpZyA9IHt9O1xuICAgICAgICB0aGlzLl9uZXh0TGV2ZWwobWluaWZpZWRDb25maWcsIG9yaWcsICdfbWF4Jyk7XG4gICAgICAgIHJldHVybiBvcmlnO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJlY3Vyc2l2ZSBmdW5jdGlvbiwgY2FsbGVkIGZvciBldmVyeSBsZXZlbCBvZiB0aGUgY29uZmlnIHN0cnVjdHVyZVxuICAgICAqXG4gICAgICogQHBhcmFtICAge0FycmF5fE9iamVjdH0gb3JpZ1xuICAgICAqIEBwYXJhbSAgIHtBcnJheXxPYmplY3R9IG1pblxuICAgICAqIEBwYXJhbSAgICB7U3RyaW5nfSB0cmFuc2xhdGlvbkZuXG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfbmV4dExldmVsKGZyb20sIHRvLCB0cmFuc2xhdGlvbkZuKSB7XG4gICAgICAgIHZhciBrZXksIG1pbktleTtcblxuICAgICAgICBmb3IgKGtleSBpbiBmcm9tKSB7XG5cbiAgICAgICAgICAgIC8qKlxuICAgICAgICAgICAgICogRm9yIGluIHJldHVybnMgYXJyYXkgaW5kaWNlcyBhcyBrZXlzLCBzbyBsZXQncyBjYXN0IHRoZW0gdG8gbnVtYmVyc1xuICAgICAgICAgICAgICovXG4gICAgICAgICAgICBpZiAoZnJvbSBpbnN0YW5jZW9mIEFycmF5KSBrZXkgPSBwYXJzZUludChrZXksIDEwKTtcblxuICAgICAgICAgICAgLyoqXG4gICAgICAgICAgICAgKiBJbiBjYXNlIHNvbWV0aGluZyBoYXMgZXh0ZW5kZWQgT2JqZWN0IHByb3RvdHlwZXNcbiAgICAgICAgICAgICAqL1xuICAgICAgICAgICAgaWYgKCFmcm9tLmhhc093blByb3BlcnR5KGtleSkpIGNvbnRpbnVlO1xuXG4gICAgICAgICAgICAvKipcbiAgICAgICAgICAgICAqIFRyYW5zbGF0ZSB0aGUga2V5IHRvIGEgb25lIGxldHRlciBzdWJzdGl0dXRlXG4gICAgICAgICAgICAgKi9cbiAgICAgICAgICAgIG1pbktleSA9IHRoaXNbdHJhbnNsYXRpb25Gbl0oa2V5LCB0aGlzLl9rZXlzKTtcblxuICAgICAgICAgICAgLyoqXG4gICAgICAgICAgICAgKiBGb3IgQXJyYXlzIGFuZCBPYmplY3RzLCBjcmVhdGUgYSBuZXcgQXJyYXkvT2JqZWN0XG4gICAgICAgICAgICAgKiBvbiB0aGUgbWluaWZpZWQgb2JqZWN0IGFuZCByZWN1cnNlIGludG8gaXRcbiAgICAgICAgICAgICAqL1xuICAgICAgICAgICAgaWYgKHR5cGVvZiBmcm9tW2tleV0gPT09ICdvYmplY3QnKSB7XG4gICAgICAgICAgICAgICAgdG9bbWluS2V5XSA9IGZyb21ba2V5XSBpbnN0YW5jZW9mIEFycmF5ID8gW10gOiB7fTtcbiAgICAgICAgICAgICAgICB0aGlzLl9uZXh0TGV2ZWwoZnJvbVtrZXldLCB0b1ttaW5LZXldLCB0cmFuc2xhdGlvbkZuKTtcblxuICAgICAgICAgICAgICAgIC8qKlxuICAgICAgICAgICAgICAgICAqIEZvciBwcmltaXRpdmUgdmFsdWVzIChTdHJpbmdzLCBOdW1iZXJzLCBCb29sZWFuIGV0Yy4pXG4gICAgICAgICAgICAgICAgICogbWluaWZ5IHRoZSB2YWx1ZVxuICAgICAgICAgICAgICAgICAqL1xuICAgICAgICAgICAgfSBlbHNlIHtcbiAgICAgICAgICAgICAgICB0b1ttaW5LZXldID0gdGhpc1t0cmFuc2xhdGlvbkZuXShmcm9tW2tleV0sIHRoaXMuX3ZhbHVlcyk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBNaW5pZmllcyB2YWx1ZSBiYXNlZCBvbiBhIGRpY3Rpb25hcnlcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtTdHJpbmd8Qm9vbGVhbn0gdmFsdWVcbiAgICAgKiBAcGFyYW0gICB7QXJyYXk8U3RyaW5nfEJvb2xlYW4+fSBkaWN0aW9uYXJ5XG4gICAgICpcbiAgICAgKiBAcmV0dXJucyB7U3RyaW5nfSBUaGUgbWluaWZpZWQgdmVyc2lvblxuICAgICAqL1xuICAgIF9taW4odmFsdWUsIGRpY3Rpb25hcnkpIHtcbiAgICAgICAgLyoqXG4gICAgICAgICAqIElmIGEgdmFsdWUgYWN0dWFsbHkgaXMgYSBzaW5nbGUgY2hhcmFjdGVyLCBwcmVmaXggaXRcbiAgICAgICAgICogd2l0aCBfX18gdG8gYXZvaWQgbWlzdGFraW5nIGl0IGZvciBhIG1pbmlmaWNhdGlvbiBjb2RlXG4gICAgICAgICAqL1xuICAgICAgICBpZiAodHlwZW9mIHZhbHVlID09PSAnc3RyaW5nJyAmJiB2YWx1ZS5sZW5ndGggPT09IDEpIHtcbiAgICAgICAgICAgIHJldHVybiAnX19fJyArIHZhbHVlO1xuICAgICAgICB9XG5cbiAgICAgICAgdmFyIGluZGV4ID0gaW5kZXhPZih2YWx1ZSwgZGljdGlvbmFyeSk7XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIHZhbHVlIG5vdCBmb3VuZCBpbiB0aGUgZGljdGlvbmFyeSwgcmV0dXJuIGl0IHVubW9kaWZpZWRcbiAgICAgICAgICovXG4gICAgICAgIGlmIChpbmRleCA9PT0gLTEpIHtcbiAgICAgICAgICAgIHJldHVybiB2YWx1ZTtcblxuICAgICAgICAgICAgLyoqXG4gICAgICAgICAgICAgKiB2YWx1ZSBmb3VuZCBpbiBkaWN0aW9uYXJ5LCByZXR1cm4gaXRzIGJhc2UzNiBjb3VudGVycGFydFxuICAgICAgICAgICAgICovXG4gICAgICAgIH0gZWxzZSB7XG4gICAgICAgICAgICByZXR1cm4gaW5kZXgudG9TdHJpbmcoMzYpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgX21heCh2YWx1ZSwgZGljdGlvbmFyeSkge1xuICAgICAgICAvKipcbiAgICAgICAgICogdmFsdWUgaXMgYSBzaW5nbGUgY2hhcmFjdGVyLiBBc3N1bWUgdGhhdCBpdCdzIGEgdHJhbnNsYXRpb25cbiAgICAgICAgICogYW5kIHJldHVybiB0aGUgb3JpZ2luYWwgdmFsdWUgZnJvbSB0aGUgZGljdGlvbmFyeVxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHR5cGVvZiB2YWx1ZSA9PT0gJ3N0cmluZycgJiYgdmFsdWUubGVuZ3RoID09PSAxKSB7XG4gICAgICAgICAgICByZXR1cm4gZGljdGlvbmFyeVtwYXJzZUludCh2YWx1ZSwgMzYpXTtcbiAgICAgICAgfVxuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiB2YWx1ZSBvcmlnaW5hbGx5IHdhcyBhIHNpbmdsZSBjaGFyYWN0ZXIgYW5kIHdhcyBwcmVmaXhlZCB3aXRoIF9fX1xuICAgICAgICAgKiB0byBhdm9pZCBtaXN0YWtpbmcgaXQgZm9yIGEgdHJhbnNsYXRpb24uIFJlbW92ZSB0aGUgcHJlZml4XG4gICAgICAgICAqIGFuZCByZXR1cm4gdGhlIG9yaWdpbmFsIGNoYXJhY3RlclxuICAgICAgICAgKi9cbiAgICAgICAgaWYgKHR5cGVvZiB2YWx1ZSA9PT0gJ3N0cmluZycgJiYgdmFsdWUuc3Vic3RyKDAsIDMpID09PSAnX19fJykge1xuICAgICAgICAgICAgcmV0dXJuIHZhbHVlWzNdO1xuICAgICAgICB9XG4gICAgICAgIC8qKlxuICAgICAgICAgKiB2YWx1ZSB3YXMgbm90IG1pbmlmaWVkXG4gICAgICAgICAqL1xuICAgICAgICByZXR1cm4gdmFsdWU7XG4gICAgfVxufVxuXG4iLCJpbXBvcnQgRXZlbnRFbWl0dGVyIGZyb20gJy4uL3V0aWxzL0V2ZW50RW1pdHRlcidcbmltcG9ydCB7XG4gICAgZm5CaW5kLCBcbiAgICBnZXRUb3VjaEV2ZW50XG59IGZyb20gJy4uL3V0aWxzL3V0aWxzJ1xuaW1wb3J0ICQgZnJvbSAnanF1ZXJ5J1xuXG5leHBvcnQgZGVmYXVsdCBjbGFzcyBEcmFnTGlzdGVuZXIgZXh0ZW5kcyBFdmVudEVtaXR0ZXIge1xuICAgIGNvbnN0cnVjdG9yKGVFbGVtZW50LCBuQnV0dG9uQ29kZSkge1xuXG4gICAgICAgIHN1cGVyKCk7XG5cbiAgICAgICAgdGhpcy5fdGltZW91dCA9IG51bGxcblxuXG4gICAgICAgIHRoaXMuX2VFbGVtZW50ID0gJChlRWxlbWVudCk7XG4gICAgICAgIHRoaXMuX29Eb2N1bWVudCA9ICQoZG9jdW1lbnQpO1xuICAgICAgICB0aGlzLl9lQm9keSA9ICQoZG9jdW1lbnQuYm9keSk7XG4gICAgICAgIHRoaXMuX25CdXR0b25Db2RlID0gbkJ1dHRvbkNvZGUgfHwgMDtcblxuICAgICAgICAvKipcbiAgICAgICAgICogVGhlIGRlbGF5IGFmdGVyIHdoaWNoIHRvIHN0YXJ0IHRoZSBkcmFnIGluIG1pbGxpc2Vjb25kc1xuICAgICAgICAgKi9cbiAgICAgICAgdGhpcy5fbkRlbGF5ID0gMjAwO1xuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBUaGUgZGlzdGFuY2UgdGhlIG1vdXNlIG5lZWRzIHRvIGJlIG1vdmVkIHRvIHF1YWxpZnkgYXMgYSBkcmFnXG4gICAgICAgICAqL1xuICAgICAgICB0aGlzLl9uRGlzdGFuY2UgPSAxMDsgLy9UT0RPIC0gd29ya3MgYmV0dGVyIHdpdGggZGVsYXkgb25seVxuXG4gICAgICAgIHRoaXMuX25YID0gMDtcbiAgICAgICAgdGhpcy5fblkgPSAwO1xuXG4gICAgICAgIHRoaXMuX25PcmlnaW5hbFggPSAwO1xuICAgICAgICB0aGlzLl9uT3JpZ2luYWxZID0gMDtcblxuICAgICAgICB0aGlzLl9iRHJhZ2dpbmcgPSBmYWxzZTtcblxuICAgICAgICB0aGlzLl9mTW92ZSA9IGZuQmluZCh0aGlzLm9uTW91c2VNb3ZlLCB0aGlzKTtcbiAgICAgICAgdGhpcy5fZlVwID0gZm5CaW5kKHRoaXMub25Nb3VzZVVwLCB0aGlzKTtcbiAgICAgICAgdGhpcy5fZkRvd24gPSBmbkJpbmQodGhpcy5vbk1vdXNlRG93biwgdGhpcyk7XG5cblxuICAgICAgICB0aGlzLl9lRWxlbWVudC5vbignbW91c2Vkb3duIHRvdWNoc3RhcnQnLCB0aGlzLl9mRG93bik7XG4gICAgfVxuXG4gICAgZGVzdHJveSgpIHtcbiAgICAgICAgdGhpcy5fZUVsZW1lbnQudW5iaW5kKCdtb3VzZWRvd24gdG91Y2hzdGFydCcsIHRoaXMuX2ZEb3duKTtcbiAgICAgICAgdGhpcy5fb0RvY3VtZW50LnVuYmluZCgnbW91c2V1cCB0b3VjaGVuZCcsIHRoaXMuX2ZVcCk7XG4gICAgICAgIHRoaXMuX2VFbGVtZW50ID0gbnVsbDtcbiAgICAgICAgdGhpcy5fb0RvY3VtZW50ID0gbnVsbDtcbiAgICAgICAgdGhpcy5fZUJvZHkgPSBudWxsO1xuICAgIH1cblxuICAgIG9uTW91c2VEb3duKG9FdmVudCkge1xuICAgICAgICBvRXZlbnQucHJldmVudERlZmF1bHQoKTtcblxuICAgICAgICBpZiAob0V2ZW50LmJ1dHRvbiA9PSAwIHx8IG9FdmVudC50eXBlID09PSBcInRvdWNoc3RhcnRcIikge1xuICAgICAgICAgICAgdmFyIGNvb3JkaW5hdGVzID0gdGhpcy5fZ2V0Q29vcmRpbmF0ZXMob0V2ZW50KTtcblxuICAgICAgICAgICAgdGhpcy5fbk9yaWdpbmFsWCA9IGNvb3JkaW5hdGVzLng7XG4gICAgICAgICAgICB0aGlzLl9uT3JpZ2luYWxZID0gY29vcmRpbmF0ZXMueTtcblxuICAgICAgICAgICAgdGhpcy5fb0RvY3VtZW50Lm9uKCdtb3VzZW1vdmUgdG91Y2htb3ZlJywgdGhpcy5fZk1vdmUpO1xuICAgICAgICAgICAgdGhpcy5fb0RvY3VtZW50Lm9uZSgnbW91c2V1cCB0b3VjaGVuZCcsIHRoaXMuX2ZVcCk7XG5cbiAgICAgICAgICAgIHRoaXMuX3RpbWVvdXQgPSBzZXRUaW1lb3V0KGZuQmluZCh0aGlzLl9zdGFydERyYWcsIHRoaXMpLCB0aGlzLl9uRGVsYXkpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgb25Nb3VzZU1vdmUob0V2ZW50KSB7XG4gICAgICAgIGlmICh0aGlzLl90aW1lb3V0ICE9IG51bGwpIHtcbiAgICAgICAgICAgIG9FdmVudC5wcmV2ZW50RGVmYXVsdCgpO1xuXG4gICAgICAgICAgICB2YXIgY29vcmRpbmF0ZXMgPSB0aGlzLl9nZXRDb29yZGluYXRlcyhvRXZlbnQpO1xuXG4gICAgICAgICAgICB0aGlzLl9uWCA9IGNvb3JkaW5hdGVzLnggLSB0aGlzLl9uT3JpZ2luYWxYO1xuICAgICAgICAgICAgdGhpcy5fblkgPSBjb29yZGluYXRlcy55IC0gdGhpcy5fbk9yaWdpbmFsWTtcblxuICAgICAgICAgICAgaWYgKHRoaXMuX2JEcmFnZ2luZyA9PT0gZmFsc2UpIHtcbiAgICAgICAgICAgICAgICBpZiAoXG4gICAgICAgICAgICAgICAgICAgIE1hdGguYWJzKHRoaXMuX25YKSA+IHRoaXMuX25EaXN0YW5jZSB8fFxuICAgICAgICAgICAgICAgICAgICBNYXRoLmFicyh0aGlzLl9uWSkgPiB0aGlzLl9uRGlzdGFuY2VcbiAgICAgICAgICAgICAgICApIHtcbiAgICAgICAgICAgICAgICAgICAgY2xlYXJUaW1lb3V0KHRoaXMuX3RpbWVvdXQpO1xuICAgICAgICAgICAgICAgICAgICB0aGlzLl9zdGFydERyYWcoKTtcbiAgICAgICAgICAgICAgICB9XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGlmICh0aGlzLl9iRHJhZ2dpbmcpIHtcbiAgICAgICAgICAgICAgICB0aGlzLmVtaXQoJ2RyYWcnLCB0aGlzLl9uWCwgdGhpcy5fblksIG9FdmVudCk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICBvbk1vdXNlVXAob0V2ZW50KSB7XG4gICAgICAgIGlmICh0aGlzLl90aW1lb3V0ICE9IG51bGwpIHtcbiAgICAgICAgICAgIGNsZWFyVGltZW91dCh0aGlzLl90aW1lb3V0KTtcbiAgICAgICAgICAgIHRoaXMuX2VCb2R5LnJlbW92ZUNsYXNzKCdsbV9kcmFnZ2luZycpO1xuICAgICAgICAgICAgdGhpcy5fZUVsZW1lbnQucmVtb3ZlQ2xhc3MoJ2xtX2RyYWdnaW5nJyk7XG4gICAgICAgICAgICB0aGlzLl9vRG9jdW1lbnQuZmluZCgnaWZyYW1lJykuY3NzKCdwb2ludGVyLWV2ZW50cycsICcnKTtcbiAgICAgICAgICAgIHRoaXMuX29Eb2N1bWVudC51bmJpbmQoJ21vdXNlbW92ZSB0b3VjaG1vdmUnLCB0aGlzLl9mTW92ZSk7XG4gICAgICAgICAgICB0aGlzLl9vRG9jdW1lbnQudW5iaW5kKCdtb3VzZXVwIHRvdWNoZW5kJywgdGhpcy5fZlVwKTtcblxuICAgICAgICAgICAgaWYgKHRoaXMuX2JEcmFnZ2luZyA9PT0gdHJ1ZSkge1xuICAgICAgICAgICAgICAgIHRoaXMuX2JEcmFnZ2luZyA9IGZhbHNlO1xuICAgICAgICAgICAgICAgIHRoaXMuZW1pdCgnZHJhZ1N0b3AnLCBvRXZlbnQsIHRoaXMuX25PcmlnaW5hbFggKyB0aGlzLl9uWCk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH1cbiAgICB9XG5cbiAgICBfc3RhcnREcmFnKCkge1xuICAgICAgICB0aGlzLl9iRHJhZ2dpbmcgPSB0cnVlO1xuICAgICAgICB0aGlzLl9lQm9keS5hZGRDbGFzcygnbG1fZHJhZ2dpbmcnKTtcbiAgICAgICAgdGhpcy5fZUVsZW1lbnQuYWRkQ2xhc3MoJ2xtX2RyYWdnaW5nJyk7XG4gICAgICAgIHRoaXMuX29Eb2N1bWVudC5maW5kKCdpZnJhbWUnKS5jc3MoJ3BvaW50ZXItZXZlbnRzJywgJ25vbmUnKTtcbiAgICAgICAgdGhpcy5lbWl0KCdkcmFnU3RhcnQnLCB0aGlzLl9uT3JpZ2luYWxYLCB0aGlzLl9uT3JpZ2luYWxZKTtcbiAgICB9XG5cbiAgICBfZ2V0Q29vcmRpbmF0ZXMoZXZlbnQpIHtcbiAgICAgICAgZXZlbnQgPSBnZXRUb3VjaEV2ZW50KGV2ZW50KVxuICAgICAgICByZXR1cm4ge1xuICAgICAgICAgICAgeDogZXZlbnQucGFnZVgsXG4gICAgICAgICAgICB5OiBldmVudC5wYWdlWVxuICAgICAgICB9O1xuICAgIH1cbn1cbiIsImltcG9ydCB7XG4gICAgaXNGdW5jdGlvblxufSBmcm9tICcuLi91dGlscy91dGlscydcblxuLyoqXG4gKiBUaGUgbmFtZSBvZiB0aGUgZXZlbnQgdGhhdCdzIHRyaWdnZXJlZCBmb3IgZXZlcnkgb3RoZXIgZXZlbnRcbiAqXG4gKiB1c2FnZVxuICpcbiAqIG15RW1pdHRlci5vbiggRXZlbnRFbWl0dGVyLkFMTF9FVkVOVCwgZnVuY3Rpb24oIGV2ZW50TmFtZSwgYXJnc0FycmF5ICl7XG4gKiAgLy9kbyBzdHVmZlxuICogfSk7XG4gKlxuICogQHR5cGUge1N0cmluZ31cbiAqL1xuZXhwb3J0IGNvbnN0IEFMTF9FVkVOVCA9ICdfX2FsbCdcblxuXG4vKipcbiAqIEEgZ2VuZXJpYyBhbmQgdmVyeSBmYXN0IEV2ZW50RW1pdHRlclxuICogaW1wbGVtZW50YXRpb24uIE9uIHRvcCBvZiBlbWl0dGluZyB0aGVcbiAqIGFjdHVhbCBldmVudCBpdCBlbWl0cyBhblxuICpcbiAqIEV2ZW50RW1pdHRlci5BTExfRVZFTlRcbiAqXG4gKiBldmVudCBmb3IgZXZlcnkgZXZlbnQgdHJpZ2dlcmVkLiBUaGlzIGFsbG93c1xuICogdG8gaG9vayBpbnRvIGl0IGFuZCBwcm94eSBldmVudHMgZm9yd2FyZHNcbiAqXG4gKiBAY29uc3RydWN0b3JcbiAqL1xuZXhwb3J0IGRlZmF1bHQgY2xhc3MgRXZlbnRFbWl0dGVyIHtcblxuICAgIGNvbnN0cnVjdG9yKCkge1xuICAgICAgICB0aGlzLl9tU3Vic2NyaXB0aW9ucyA9IHt9O1xuICAgICAgICB0aGlzLl9tU3Vic2NyaXB0aW9uc1tBTExfRVZFTlRdID0gW107XG5cblxuICAgICAgICAvKipcbiAgICAgICAgICogTGlzdGVuIGZvciBldmVudHNcbiAgICAgICAgICpcbiAgICAgICAgICogQHBhcmFtICAge1N0cmluZ30gc0V2ZW50ICAgIFRoZSBuYW1lIG9mIHRoZSBldmVudCB0byBsaXN0ZW4gdG9cbiAgICAgICAgICogQHBhcmFtICAge0Z1bmN0aW9ufSBmQ2FsbGJhY2sgVGhlIGNhbGxiYWNrIHRvIGV4ZWN1dGUgd2hlbiB0aGUgZXZlbnQgb2NjdXJzXG4gICAgICAgICAqIEBwYXJhbSAgIHtbT2JqZWN0XX0gb0NvbnRleHQgVGhlIHZhbHVlIG9mIHRoZSB0aGlzIHBvaW50ZXIgd2l0aGluIHRoZSBjYWxsYmFjayBmdW5jdGlvblxuICAgICAgICAgKlxuICAgICAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgICAgICovXG4gICAgICAgIHRoaXMub24gPSBmdW5jdGlvbihzRXZlbnQsIGZDYWxsYmFjaywgb0NvbnRleHQpIHtcbiAgICAgICAgICAgIGlmICghaXNGdW5jdGlvbihmQ2FsbGJhY2spKSB7XG4gICAgICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdUcmllZCB0byBsaXN0ZW4gdG8gZXZlbnQgJyArIHNFdmVudCArICcgd2l0aCBub24tZnVuY3Rpb24gY2FsbGJhY2sgJyArIGZDYWxsYmFjayk7XG4gICAgICAgICAgICB9XG5cbiAgICAgICAgICAgIGlmICghdGhpcy5fbVN1YnNjcmlwdGlvbnNbc0V2ZW50XSkge1xuICAgICAgICAgICAgICAgIHRoaXMuX21TdWJzY3JpcHRpb25zW3NFdmVudF0gPSBbXTtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgdGhpcy5fbVN1YnNjcmlwdGlvbnNbc0V2ZW50XS5wdXNoKHtcbiAgICAgICAgICAgICAgICBmbjogZkNhbGxiYWNrLFxuICAgICAgICAgICAgICAgIGN0eDogb0NvbnRleHRcbiAgICAgICAgICAgIH0pO1xuICAgICAgICB9O1xuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBFbWl0IGFuIGV2ZW50IGFuZCBub3RpZnkgbGlzdGVuZXJzXG4gICAgICAgICAqXG4gICAgICAgICAqIEBwYXJhbSAgIHtTdHJpbmd9IHNFdmVudCBUaGUgbmFtZSBvZiB0aGUgZXZlbnRcbiAgICAgICAgICogQHBhcmFtICAgIHtNaXhlZH0gIHZhcmlvdXMgYWRkaXRpb25hbCBhcmd1bWVudHMgdGhhdCB3aWxsIGJlIHBhc3NlZCB0byB0aGUgbGlzdGVuZXJcbiAgICAgICAgICpcbiAgICAgICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICAgICAqL1xuICAgICAgICB0aGlzLmVtaXQgPSBmdW5jdGlvbihzRXZlbnQpIHtcbiAgICAgICAgICAgIHZhciBpLCBjdHgsIGFyZ3M7XG5cbiAgICAgICAgICAgIGFyZ3MgPSBBcnJheS5wcm90b3R5cGUuc2xpY2UuY2FsbChhcmd1bWVudHMsIDEpO1xuXG4gICAgICAgICAgICB2YXIgc3VicyA9IHRoaXMuX21TdWJzY3JpcHRpb25zW3NFdmVudF07XG5cbiAgICAgICAgICAgIGlmIChzdWJzKSB7XG4gICAgICAgICAgICAgICAgc3VicyA9IHN1YnMuc2xpY2UoKTtcbiAgICAgICAgICAgICAgICBmb3IgKGkgPSAwOyBpIDwgc3Vicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgICAgICAgICBjdHggPSBzdWJzW2ldLmN0eCB8fCB7fTtcbiAgICAgICAgICAgICAgICAgICAgc3Vic1tpXS5mbi5hcHBseShjdHgsIGFyZ3MpO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgYXJncy51bnNoaWZ0KHNFdmVudCk7XG5cbiAgICAgICAgICAgIHZhciBhbGxFdmVudFN1YnMgPSB0aGlzLl9tU3Vic2NyaXB0aW9uc1tBTExfRVZFTlRdLnNsaWNlKClcblxuICAgICAgICAgICAgZm9yIChpID0gMDsgaSA8IGFsbEV2ZW50U3Vicy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgICAgIGN0eCA9IGFsbEV2ZW50U3Vic1tpXS5jdHggfHwge307XG4gICAgICAgICAgICAgICAgYWxsRXZlbnRTdWJzW2ldLmZuLmFwcGx5KGN0eCwgYXJncyk7XG4gICAgICAgICAgICB9XG4gICAgICAgIH07XG5cbiAgICAgICAgLyoqXG4gICAgICAgICAqIFJlbW92ZXMgYSBsaXN0ZW5lciBmb3IgYW4gZXZlbnQsIG9yIGFsbCBsaXN0ZW5lcnMgaWYgbm8gY2FsbGJhY2sgYW5kIGNvbnRleHQgaXMgcHJvdmlkZWQuXG4gICAgICAgICAqXG4gICAgICAgICAqIEBwYXJhbSAgIHtTdHJpbmd9IHNFdmVudCAgICBUaGUgbmFtZSBvZiB0aGUgZXZlbnRcbiAgICAgICAgICogQHBhcmFtICAge0Z1bmN0aW9ufSBmQ2FsbGJhY2sgVGhlIHByZXZpb3VzbHkgcmVnaXN0ZXJlZCBjYWxsYmFjayBtZXRob2QgKG9wdGlvbmFsKVxuICAgICAgICAgKiBAcGFyYW0gICB7T2JqZWN0fSBvQ29udGV4dCAgVGhlIHByZXZpb3VzbHkgcmVnaXN0ZXJlZCBjb250ZXh0IChvcHRpb25hbClcbiAgICAgICAgICpcbiAgICAgICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICAgICAqL1xuICAgICAgICB0aGlzLnVuYmluZCA9IGZ1bmN0aW9uKHNFdmVudCwgZkNhbGxiYWNrLCBvQ29udGV4dCkge1xuICAgICAgICAgICAgaWYgKCF0aGlzLl9tU3Vic2NyaXB0aW9uc1tzRXZlbnRdKSB7XG4gICAgICAgICAgICAgICAgdGhyb3cgbmV3IEVycm9yKCdObyBzdWJzY3JpYnRpb25zIHRvIHVuc3Vic2NyaWJlIGZvciBldmVudCAnICsgc0V2ZW50KTtcbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgdmFyIGksIGJVbmJvdW5kID0gZmFsc2U7XG5cbiAgICAgICAgICAgIGZvciAoaSA9IDA7IGkgPCB0aGlzLl9tU3Vic2NyaXB0aW9uc1tzRXZlbnRdLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICAgICAgaWYgKFxuICAgICAgICAgICAgICAgICAgICAoIWZDYWxsYmFjayB8fCB0aGlzLl9tU3Vic2NyaXB0aW9uc1tzRXZlbnRdW2ldLmZuID09PSBmQ2FsbGJhY2spICYmXG4gICAgICAgICAgICAgICAgICAgICghb0NvbnRleHQgfHwgb0NvbnRleHQgPT09IHRoaXMuX21TdWJzY3JpcHRpb25zW3NFdmVudF1baV0uY3R4KVxuICAgICAgICAgICAgICAgICkge1xuICAgICAgICAgICAgICAgICAgICB0aGlzLl9tU3Vic2NyaXB0aW9uc1tzRXZlbnRdLnNwbGljZShpLCAxKTtcbiAgICAgICAgICAgICAgICAgICAgYlVuYm91bmQgPSB0cnVlO1xuICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgaWYgKGJVbmJvdW5kID09PSBmYWxzZSkge1xuICAgICAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignTm90aGluZyB0byB1bmJpbmQgZm9yICcgKyBzRXZlbnQpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9O1xuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBBbGlhcyBmb3IgdW5iaW5kXG4gICAgICAgICAqL1xuICAgICAgICB0aGlzLm9mZiA9IHRoaXMudW5iaW5kO1xuXG4gICAgICAgIC8qKlxuICAgICAgICAgKiBBbGlhcyBmb3IgZW1pdFxuICAgICAgICAgKi9cbiAgICAgICAgdGhpcy50cmlnZ2VyID0gdGhpcy5lbWl0O1xuICAgIH1cbn1cbiIsImltcG9ydCBFdmVudEVtaXR0ZXIgZnJvbSAnLi4vdXRpbHMvRXZlbnRFbWl0dGVyJ1xuaW1wb3J0IHsgXG4gIEFMTF9FVkVOVFxufSBmcm9tICcuLi91dGlscy9FdmVudEVtaXR0ZXInXG5pbXBvcnQge1xuICAgIGZuQmluZFxufSBmcm9tICcuLi91dGlscy91dGlscydcbmltcG9ydCAkIGZyb20gJ2pxdWVyeSdcblxuLyoqXG4gKiBBbiBFdmVudEVtaXR0ZXIgc2luZ2xldG9uIHRoYXQgcHJvcGFnYXRlcyBldmVudHNcbiAqIGFjcm9zcyBtdWx0aXBsZSB3aW5kb3dzLiBUaGlzIGlzIGEgbGl0dGxlIGJpdCB0cmlja2llciBzaW5jZVxuICogd2luZG93cyBhcmUgYWxsb3dlZCB0byBvcGVuIGNoaWxkV2luZG93cyBpbiB0aGVpciBvd24gcmlnaHRcbiAqXG4gKiBUaGlzIG1lYW5zIHRoYXQgd2UgZGVhbCB3aXRoIGEgdHJlZSBvZiB3aW5kb3dzLiBIZW5jZSB0aGUgcnVsZXMgZm9yIGV2ZW50IHByb3BhZ2F0aW9uIGFyZTpcbiAqXG4gKiAtIFByb3BhZ2F0ZSBldmVudHMgZnJvbSB0aGlzIGxheW91dCB0byBib3RoIHBhcmVudHMgYW5kIGNoaWxkcmVuXG4gKiAtIFByb3BhZ2F0ZSBldmVudHMgZnJvbSBwYXJlbnQgdG8gdGhpcyBhbmQgY2hpbGRyZW5cbiAqIC0gUHJvcGFnYXRlIGV2ZW50cyBmcm9tIGNoaWxkcmVuIHRvIHRoZSBvdGhlciBjaGlsZHJlbiAoYnV0IG5vdCB0aGUgZW1pdHRpbmcgb25lKSBhbmQgdGhlIHBhcmVudFxuICpcbiAqIEBjb25zdHJ1Y3RvclxuICpcbiAqIEBwYXJhbSB7bG0uTGF5b3V0TWFuYWdlcn0gbGF5b3V0TWFuYWdlclxuICovXG5cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgRXZlbnRIdWIgZXh0ZW5kcyBFdmVudEVtaXR0ZXIge1xuICAgIGNvbnN0cnVjdG9yKGxheW91dE1hbmFnZXIpIHtcbiAgICAgICAgXG4gICAgICAgIHN1cGVyKCk7XG5cbiAgICAgICAgdGhpcy5fbGF5b3V0TWFuYWdlciA9IGxheW91dE1hbmFnZXI7XG4gICAgICAgIHRoaXMuX2RvbnRQcm9wYWdhdGVUb1BhcmVudCA9IG51bGw7XG4gICAgICAgIHRoaXMuX2NoaWxkRXZlbnRTb3VyY2UgPSBudWxsO1xuICAgICAgICB0aGlzLm9uKEFMTF9FVkVOVCwgZm5CaW5kKHRoaXMuX29uRXZlbnRGcm9tVGhpcywgdGhpcykpO1xuICAgICAgICB0aGlzLl9ib3VuZE9uRXZlbnRGcm9tQ2hpbGQgPSBmbkJpbmQodGhpcy5fb25FdmVudEZyb21DaGlsZCwgdGhpcyk7XG4gICAgICAgICQod2luZG93KS5vbignZ2xfY2hpbGRfZXZlbnQnLCB0aGlzLl9ib3VuZE9uRXZlbnRGcm9tQ2hpbGQpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIENhbGxlZCBvbiBldmVyeSBldmVudCBlbWl0dGVkIG9uIHRoaXMgZXZlbnRIdWIsIHJlZ2FyZGxlcyBvZiBvcmlnaW4uXG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqXG4gICAgICogQHBhcmFtIHtNaXhlZH1cbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vbkV2ZW50RnJvbVRoaXMoKSB7XG4gICAgICAgIHZhciBhcmdzID0gQXJyYXkucHJvdG90eXBlLnNsaWNlLmNhbGwoYXJndW1lbnRzKTtcblxuICAgICAgICBpZiAodGhpcy5fbGF5b3V0TWFuYWdlci5pc1N1YldpbmRvdyAmJiBhcmdzWzBdICE9PSB0aGlzLl9kb250UHJvcGFnYXRlVG9QYXJlbnQpIHtcbiAgICAgICAgICAgIHRoaXMuX3Byb3BhZ2F0ZVRvUGFyZW50KGFyZ3MpO1xuICAgICAgICB9XG4gICAgICAgIHRoaXMuX3Byb3BhZ2F0ZVRvQ2hpbGRyZW4oYXJncyk7XG5cbiAgICAgICAgLy9SZXNldFxuICAgICAgICB0aGlzLl9kb250UHJvcGFnYXRlVG9QYXJlbnQgPSBudWxsO1xuICAgICAgICB0aGlzLl9jaGlsZEV2ZW50U291cmNlID0gbnVsbDtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxsZWQgYnkgdGhlIHBhcmVudCBsYXlvdXQuXG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7QXJyYXl9IGFyZ3MgRXZlbnQgbmFtZSArIGFyZ3VtZW50c1xuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgXyRvbkV2ZW50RnJvbVBhcmVudChhcmdzKSB7XG4gICAgICAgIHRoaXMuX2RvbnRQcm9wYWdhdGVUb1BhcmVudCA9IGFyZ3NbMF07XG4gICAgICAgIHRoaXMuZW1pdC5hcHBseSh0aGlzLCBhcmdzKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBDYWxsYmFjayBmb3IgY2hpbGQgZXZlbnRzIHJhaXNlZCBvbiB0aGUgd2luZG93XG4gICAgICpcbiAgICAgKiBAcGFyYW0gICB7RE9NRXZlbnR9IGV2ZW50XG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9vbkV2ZW50RnJvbUNoaWxkKGV2ZW50KSB7XG4gICAgICAgIHRoaXMuX2NoaWxkRXZlbnRTb3VyY2UgPSBldmVudC5vcmlnaW5hbEV2ZW50Ll9fZ2w7XG4gICAgICAgIHRoaXMuZW1pdC5hcHBseSh0aGlzLCBldmVudC5vcmlnaW5hbEV2ZW50Ll9fZ2xBcmdzKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBQcm9wYWdhdGVzIHRoZSBldmVudCB0byB0aGUgcGFyZW50IGJ5IGVtaXR0aW5nXG4gICAgICogaXQgb24gdGhlIHBhcmVudCdzIERPTSB3aW5kb3dcbiAgICAgKlxuICAgICAqIEBwYXJhbSAgIHtBcnJheX0gYXJncyBFdmVudCBuYW1lICsgYXJndW1lbnRzXG4gICAgICogQHByaXZhdGVcbiAgICAgKlxuICAgICAqIEByZXR1cm5zIHt2b2lkfVxuICAgICAqL1xuICAgIF9wcm9wYWdhdGVUb1BhcmVudChhcmdzKSB7XG4gICAgICAgIHZhciBldmVudCxcbiAgICAgICAgICAgIGV2ZW50TmFtZSA9ICdnbF9jaGlsZF9ldmVudCc7XG5cbiAgICAgICAgaWYgKGRvY3VtZW50LmNyZWF0ZUV2ZW50KSB7XG4gICAgICAgICAgICBldmVudCA9IHdpbmRvdy5vcGVuZXIuZG9jdW1lbnQuY3JlYXRlRXZlbnQoJ0hUTUxFdmVudHMnKTtcbiAgICAgICAgICAgIGV2ZW50LmluaXRFdmVudChldmVudE5hbWUsIHRydWUsIHRydWUpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgZXZlbnQgPSB3aW5kb3cub3BlbmVyLmRvY3VtZW50LmNyZWF0ZUV2ZW50T2JqZWN0KCk7XG4gICAgICAgICAgICBldmVudC5ldmVudFR5cGUgPSBldmVudE5hbWU7XG4gICAgICAgIH1cblxuICAgICAgICBldmVudC5ldmVudE5hbWUgPSBldmVudE5hbWU7XG4gICAgICAgIGV2ZW50Ll9fZ2xBcmdzID0gYXJncztcbiAgICAgICAgZXZlbnQuX19nbCA9IHRoaXMuX2xheW91dE1hbmFnZXI7XG5cbiAgICAgICAgaWYgKGRvY3VtZW50LmNyZWF0ZUV2ZW50KSB7XG4gICAgICAgICAgICB3aW5kb3cub3BlbmVyLmRpc3BhdGNoRXZlbnQoZXZlbnQpO1xuICAgICAgICB9IGVsc2Uge1xuICAgICAgICAgICAgd2luZG93Lm9wZW5lci5maXJlRXZlbnQoJ29uJyArIGV2ZW50LmV2ZW50VHlwZSwgZXZlbnQpO1xuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogUHJvcGFnYXRlIGV2ZW50cyB0byBjaGlsZHJlblxuICAgICAqXG4gICAgICogQHBhcmFtICAge0FycmF5fSBhcmdzIEV2ZW50IG5hbWUgKyBhcmd1bWVudHNcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX3Byb3BhZ2F0ZVRvQ2hpbGRyZW4oYXJncykge1xuICAgICAgICB2YXIgY2hpbGRHbCwgaTtcblxuICAgICAgICBmb3IgKGkgPSAwOyBpIDwgdGhpcy5fbGF5b3V0TWFuYWdlci5vcGVuUG9wb3V0cy5sZW5ndGg7IGkrKykge1xuICAgICAgICAgICAgY2hpbGRHbCA9IHRoaXMuX2xheW91dE1hbmFnZXIub3BlblBvcG91dHNbaV0uZ2V0R2xJbnN0YW5jZSgpO1xuXG4gICAgICAgICAgICBpZiAoY2hpbGRHbCAmJiBjaGlsZEdsICE9PSB0aGlzLl9jaGlsZEV2ZW50U291cmNlKSB7XG4gICAgICAgICAgICAgICAgY2hpbGRHbC5ldmVudEh1Yi5fJG9uRXZlbnRGcm9tUGFyZW50KGFyZ3MpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogRGVzdHJveXMgdGhlIEV2ZW50SHViXG4gICAgICpcbiAgICAgKiBAcHVibGljXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG5cbiAgICBkZXN0cm95KCkge1xuICAgICAgICAkKHdpbmRvdykub2ZmKCdnbF9jaGlsZF9ldmVudCcsIHRoaXMuX2JvdW5kT25FdmVudEZyb21DaGlsZCk7XG4gICAgfVxufVxuIiwiaW1wb3J0ICQgZnJvbSAnanF1ZXJ5J1xuLyoqXG4gKiBBIHNwZWNpYWxpc2VkIEdvbGRlbkxheW91dCBjb21wb25lbnQgdGhhdCBiaW5kcyBHb2xkZW5MYXlvdXQgY29udGFpbmVyXG4gKiBsaWZlY3ljbGUgZXZlbnRzIHRvIHJlYWN0IGNvbXBvbmVudHNcbiAqXG4gKiBAY29uc3RydWN0b3JcbiAqXG4gKiBAcGFyYW0ge0l0ZW1Db250YWluZXJ9IGNvbnRhaW5lclxuICogQHBhcmFtIHtPYmplY3R9IHN0YXRlIHN0YXRlIGlzIG5vdCByZXF1aXJlZCBmb3IgcmVhY3QgY29tcG9uZW50c1xuICovXG5cblxuZXhwb3J0IGRlZmF1bHQgY2xhc3MgUmVhY3RDb21wb25lbnRIYW5kbGVyIHtcbiAgICBjb25zdHJ1Y3Rvcihjb250YWluZXIsIHN0YXRlKSB7XG4gICAgICAgIHRoaXMuX3JlYWN0Q29tcG9uZW50ID0gbnVsbDtcbiAgICAgICAgdGhpcy5fb3JpZ2luYWxDb21wb25lbnRXaWxsVXBkYXRlID0gbnVsbDtcbiAgICAgICAgdGhpcy5fY29udGFpbmVyID0gY29udGFpbmVyO1xuICAgICAgICB0aGlzLl9pbml0aWFsU3RhdGUgPSBzdGF0ZTtcbiAgICAgICAgdGhpcy5fcmVhY3RDbGFzcyA9IHRoaXMuX2dldFJlYWN0Q2xhc3MoKTtcbiAgICAgICAgdGhpcy5fY29udGFpbmVyLm9uKCdvcGVuJywgdGhpcy5fcmVuZGVyLCB0aGlzKTtcbiAgICAgICAgdGhpcy5fY29udGFpbmVyLm9uKCdkZXN0cm95JywgdGhpcy5fZGVzdHJveSwgdGhpcyk7XG4gICAgfVxuXG5cblxuICAgIC8qKlxuICAgICAqIENyZWF0ZXMgdGhlIHJlYWN0IGNsYXNzIGFuZCBjb21wb25lbnQgYW5kIGh5ZHJhdGVzIGl0IHdpdGhcbiAgICAgKiB0aGUgaW5pdGlhbCBzdGF0ZSAtIGlmIG9uZSBpcyBwcmVzZW50XG4gICAgICpcbiAgICAgKiBCeSBkZWZhdWx0LCByZWFjdCdzIGdldEluaXRpYWxTdGF0ZSB3aWxsIGJlIHVzZWRcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX3JlbmRlcigpIHtcbiAgICAgICAgUmVhY3RET00ucmVuZGVyKHRoaXMuX2dldFJlYWN0Q29tcG9uZW50KCksIHRoaXMuX2NvbnRhaW5lci5nZXRFbGVtZW50KClbMF0pO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIEZpcmVkIGJ5IHJlYWN0IHdoZW4gdGhlIGNvbXBvbmVudCBpcyBjcmVhdGVkLiAgQWxzbyBmaXJlZCB1cG9uIGRlc3RydWN0aW9uICh3aGVyZSBjb21wb25lbnQgaXMgbnVsbCkuXG4gICAgICogPHA+XG4gICAgICogTm90ZTogVGhpcyBjYWxsYmFjayBpcyB1c2VkIGluc3RlYWQgb2YgdGhlIHJldHVybiBmcm9tIGBSZWFjdERPTS5yZW5kZXJgIGJlY2F1c2VcbiAgICAgKlx0ICAgb2YgaHR0cHM6Ly9naXRodWIuY29tL2ZhY2Vib29rL3JlYWN0L2lzc3Vlcy8xMDMwOS5cbiAgICAgKiA8L3A+XG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqIEBhcmcge1JlYWN0LlJlZn0gY29tcG9uZW50IFRoZSBjb21wb25lbnQgaW5zdGFuY2UgY3JlYXRlZCBieSB0aGUgYFJlYWN0RE9NLnJlbmRlcmAgY2FsbCBpbiB0aGUgYF9yZW5kZXJgIG1ldGhvZC5cbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfZ290UmVhY3RDb21wb25lbnQoY29tcG9uZW50KSB7XG4gICAgICAgIGlmIChjb21wb25lbnQgIT09IG51bGwpIHtcbiAgICAgICAgICAgIHRoaXMuX3JlYWN0Q29tcG9uZW50ID0gY29tcG9uZW50O1xuICAgICAgICAgICAgdGhpcy5fb3JpZ2luYWxDb21wb25lbnRXaWxsVXBkYXRlID0gdGhpcy5fcmVhY3RDb21wb25lbnQuY29tcG9uZW50V2lsbFVwZGF0ZSB8fCBmdW5jdGlvbigpIHt9O1xuICAgICAgICAgICAgdGhpcy5fcmVhY3RDb21wb25lbnQuY29tcG9uZW50V2lsbFVwZGF0ZSA9IHRoaXMuX29uVXBkYXRlLmJpbmQoIHRoaXMgKTtcbiAgICAgICAgICAgIGlmKCB0aGlzLl9jb250YWluZXIuZ2V0U3RhdGUoKSApIHtcbiAgICAgICAgICAgICAgICB0aGlzLl9yZWFjdENvbXBvbmVudC5zZXRTdGF0ZSggdGhpcy5fY29udGFpbmVyLmdldFN0YXRlKCkgKTtcbiAgICAgICAgICAgIH1cbiAgICAgICAgfVxuICAgIH1cbiAgICBcbiAgICAvKipcbiAgICAgKiBSZW1vdmVzIHRoZSBjb21wb25lbnQgZnJvbSB0aGUgRE9NIGFuZCB0aHVzIGludm9rZXMgUmVhY3QncyB1bm1vdW50IGxpZmVjeWNsZVxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7dm9pZH1cbiAgICAgKi9cbiAgICBfZGVzdHJveSgpIHtcbiAgICAgICAgUmVhY3RET00udW5tb3VudENvbXBvbmVudEF0Tm9kZSh0aGlzLl9jb250YWluZXIuZ2V0RWxlbWVudCgpWzBdKTtcbiAgICAgICAgdGhpcy5fY29udGFpbmVyLm9mZignb3BlbicsIHRoaXMuX3JlbmRlciwgdGhpcyk7XG4gICAgICAgIHRoaXMuX2NvbnRhaW5lci5vZmYoJ2Rlc3Ryb3knLCB0aGlzLl9kZXN0cm95LCB0aGlzKTtcbiAgICB9XG5cbiAgICAvKipcbiAgICAgKiBIb29rcyBpbnRvIFJlYWN0J3Mgc3RhdGUgbWFuYWdlbWVudCBhbmQgYXBwbGllcyB0aGUgY29tcG9uZW50c3RhdGVcbiAgICAgKiB0byBHb2xkZW5MYXlvdXRcbiAgICAgKlxuICAgICAqIEBwcml2YXRlXG4gICAgICogQHJldHVybnMge3ZvaWR9XG4gICAgICovXG4gICAgX29uVXBkYXRlKG5leHRQcm9wcywgbmV4dFN0YXRlKSB7XG4gICAgICAgIHRoaXMuX2NvbnRhaW5lci5zZXRTdGF0ZShuZXh0U3RhdGUpO1xuICAgICAgICB0aGlzLl9vcmlnaW5hbENvbXBvbmVudFdpbGxVcGRhdGUuY2FsbCh0aGlzLl9yZWFjdENvbXBvbmVudCwgbmV4dFByb3BzLCBuZXh0U3RhdGUpO1xuICAgIH1cblxuICAgIC8qKlxuICAgICAqIFJldHJpZXZlcyB0aGUgcmVhY3QgY2xhc3MgZnJvbSBHb2xkZW5MYXlvdXQncyByZWdpc3RyeVxuICAgICAqXG4gICAgICogQHByaXZhdGVcbiAgICAgKiBAcmV0dXJucyB7UmVhY3QuQ2xhc3N9XG4gICAgICovXG4gICAgX2dldFJlYWN0Q2xhc3MoKSB7XG4gICAgICAgIHZhciBjb21wb25lbnROYW1lID0gdGhpcy5fY29udGFpbmVyLl9jb25maWcuY29tcG9uZW50O1xuICAgICAgICB2YXIgcmVhY3RDbGFzcztcblxuICAgICAgICBpZiAoIWNvbXBvbmVudE5hbWUpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignTm8gcmVhY3QgY29tcG9uZW50IG5hbWUuIHR5cGU6IHJlYWN0LWNvbXBvbmVudCBuZWVkcyBhIGZpZWxkIGBjb21wb25lbnRgJyk7XG4gICAgICAgIH1cblxuICAgICAgICByZWFjdENsYXNzID0gdGhpcy5fY29udGFpbmVyLmxheW91dE1hbmFnZXIuZ2V0Q29tcG9uZW50KHRoaXMuX2NvbnRhaW5lci5fY29uZmlnKTtcblxuICAgICAgICBpZiAoIXJlYWN0Q2xhc3MpIHtcbiAgICAgICAgICAgIHRocm93IG5ldyBFcnJvcignUmVhY3QgY29tcG9uZW50IFwiJyArIGNvbXBvbmVudE5hbWUgKyAnXCIgbm90IGZvdW5kLiAnICtcbiAgICAgICAgICAgICAgICAnUGxlYXNlIHJlZ2lzdGVyIGFsbCBjb21wb25lbnRzIHdpdGggR29sZGVuTGF5b3V0IHVzaW5nIGByZWdpc3RlckNvbXBvbmVudChuYW1lLCBjb21wb25lbnQpYCcpO1xuICAgICAgICB9XG5cbiAgICAgICAgcmV0dXJuIHJlYWN0Q2xhc3M7XG4gICAgfVxuXG4gICAgLyoqXG4gICAgICogQ29waWVzIGFuZCBleHRlbmRzIHRoZSBwcm9wZXJ0aWVzIGFycmF5IGFuZCByZXR1cm5zIHRoZSBSZWFjdCBlbGVtZW50XG4gICAgICpcbiAgICAgKiBAcHJpdmF0ZVxuICAgICAqIEByZXR1cm5zIHtSZWFjdC5FbGVtZW50fVxuICAgICAqL1xuICAgIF9nZXRSZWFjdENvbXBvbmVudCgpIHtcbiAgICAgICAgdmFyIGRlZmF1bHRQcm9wcyA9IHtcbiAgICAgICAgICAgIGdsRXZlbnRIdWI6IHRoaXMuX2NvbnRhaW5lci5sYXlvdXRNYW5hZ2VyLmV2ZW50SHViLFxuICAgICAgICAgICAgZ2xDb250YWluZXI6IHRoaXMuX2NvbnRhaW5lcixcbiAgICAgICAgICAgIHJlZjogdGhpcy5fZ290UmVhY3RDb21wb25lbnQuYmluZCh0aGlzKSxcbiAgICAgICAgfTtcbiAgICAgICAgdmFyIHByb3BzID0gJC5leHRlbmQoZGVmYXVsdFByb3BzLCB0aGlzLl9jb250YWluZXIuX2NvbmZpZy5wcm9wcyk7XG4gICAgICAgIHJldHVybiBSZWFjdC5jcmVhdGVFbGVtZW50KHRoaXMuX3JlYWN0Q2xhc3MsIHByb3BzKTtcbiAgICB9XG59XG4iLCJpbXBvcnQgJCBmcm9tICdqcXVlcnknXG5cbmV4cG9ydCBmdW5jdGlvbiBGKCkge31cblxuZXhwb3J0IGZ1bmN0aW9uIGdldFRvdWNoRXZlbnQoZXZlbnQpe1xuICAgIGlmKCQuemVwdG8pe1xuICAgICAgICByZXR1cm4gZXZlbnQudG91Y2hlcyA/IGV2ZW50LnRhcmdldFRvdWNoZXNbMF0gOiBldmVudDtcbiAgICB9IGVsc2Uge1xuICAgICAgICByZXR1cm4gZXZlbnQub3JpZ2luYWxFdmVudCAmJiBldmVudC5vcmlnaW5hbEV2ZW50LnRvdWNoZXMgPyBldmVudC5vcmlnaW5hbEV2ZW50LnRvdWNoZXNbMF0gOiBldmVudDtcbiAgICB9XG59XG5cbmV4cG9ydCBmdW5jdGlvbiBleHRlbmQoc3ViQ2xhc3MsIHN1cGVyQ2xhc3MpIHtcbiAgICBzdWJDbGFzcy5wcm90b3R5cGUgPSBjcmVhdGVPYmplY3Qoc3VwZXJDbGFzcy5wcm90b3R5cGUpO1xuICAgIHN1YkNsYXNzLnByb3RvdHlwZS5jb250cnVjdG9yID0gc3ViQ2xhc3M7XG59XG5cbmV4cG9ydCBmdW5jdGlvbiBjcmVhdGVPYmplY3QocHJvdG90eXBlKSB7XG4gICAgaWYgKHR5cGVvZiBPYmplY3QuY3JlYXRlID09PSAnZnVuY3Rpb24nKSB7XG4gICAgICAgIHJldHVybiBPYmplY3QuY3JlYXRlKHByb3RvdHlwZSk7XG4gICAgfSBlbHNlIHtcbiAgICAgICAgRi5wcm90b3R5cGUgPSBwcm90b3R5cGU7XG4gICAgICAgIHJldHVybiBuZXcgRigpO1xuICAgIH1cbn1cblxuZXhwb3J0IGZ1bmN0aW9uIG9iamVjdEtleXMob2JqZWN0KSB7XG4gICAgdmFyIGtleXMsIGtleTtcblxuICAgIGlmICh0eXBlb2YgT2JqZWN0LmtleXMgPT09ICdmdW5jdGlvbicpIHtcbiAgICAgICAgcmV0dXJuIE9iamVjdC5rZXlzKG9iamVjdCk7XG4gICAgfSBlbHNlIHtcbiAgICAgICAga2V5cyA9IFtdO1xuICAgICAgICBmb3IgKGtleSBpbiBvYmplY3QpIHtcbiAgICAgICAgICAgIGtleXMucHVzaChrZXkpO1xuICAgICAgICB9XG4gICAgICAgIHJldHVybiBrZXlzO1xuICAgIH1cbn1cblxuZXhwb3J0IGZ1bmN0aW9uIGdldEhhc2hWYWx1ZShrZXkpIHtcbiAgICB2YXIgbWF0Y2hlcyA9IGxvY2F0aW9uLmhhc2gubWF0Y2gobmV3IFJlZ0V4cChrZXkgKyAnPShbXiZdKiknKSk7XG4gICAgcmV0dXJuIG1hdGNoZXMgPyBtYXRjaGVzWzFdIDogbnVsbDtcbn1cblxuZXhwb3J0IGZ1bmN0aW9uIGdldFF1ZXJ5U3RyaW5nUGFyYW0ocGFyYW0pIHtcbiAgICBpZiAod2luZG93LmxvY2F0aW9uLmhhc2gpIHtcbiAgICAgICAgcmV0dXJuIGdldEhhc2hWYWx1ZShwYXJhbSk7XG4gICAgfSBlbHNlIGlmICghd2luZG93LmxvY2F0aW9uLnNlYXJjaCkge1xuICAgICAgICByZXR1cm4gbnVsbDtcbiAgICB9XG5cbiAgICB2YXIga2V5VmFsdWVQYWlycyA9IHdpbmRvdy5sb2NhdGlvbi5zZWFyY2guc3Vic3RyKDEpLnNwbGl0KCcmJyksXG4gICAgICAgIHBhcmFtcyA9IHt9LFxuICAgICAgICBwYWlyLFxuICAgICAgICBpO1xuXG4gICAgZm9yIChpID0gMDsgaSA8IGtleVZhbHVlUGFpcnMubGVuZ3RoOyBpKyspIHtcbiAgICAgICAgcGFpciA9IGtleVZhbHVlUGFpcnNbaV0uc3BsaXQoJz0nKTtcbiAgICAgICAgcGFyYW1zW3BhaXJbMF1dID0gcGFpclsxXTtcbiAgICB9XG5cbiAgICByZXR1cm4gcGFyYW1zW3BhcmFtXSB8fCBudWxsO1xufVxuXG5leHBvcnQgZnVuY3Rpb24gY29weSh0YXJnZXQsIHNvdXJjZSkge1xuICAgIGZvciAodmFyIGtleSBpbiBzb3VyY2UpIHtcbiAgICAgICAgdGFyZ2V0W2tleV0gPSBzb3VyY2Vba2V5XTtcbiAgICB9XG4gICAgcmV0dXJuIHRhcmdldDtcbn1cblxuLyoqXG4gKiBUaGlzIGlzIGJhc2VkIG9uIFBhdWwgSXJpc2gncyBzaGltLCBidXQgbG9va3MgcXVpdGUgb2RkIGluIGNvbXBhcmlzb24uIFdoeT9cbiAqIEJlY2F1c2VcbiAqIGEpIGl0IHNob3VsZG4ndCBhZmZlY3QgdGhlIGdsb2JhbCByZXF1ZXN0QW5pbWF0aW9uRnJhbWUgZnVuY3Rpb25cbiAqIGIpIGl0IHNob3VsZG4ndCBwYXNzIG9uIHRoZSB0aW1lIHRoYXQgaGFzIHBhc3NlZFxuICpcbiAqIEBwYXJhbSAgIHtGdW5jdGlvbn0gZm5cbiAqXG4gKiBAcmV0dXJucyB7dm9pZH1cbiAqL1xuZXhwb3J0IGZ1bmN0aW9uIGFuaW1GcmFtZShmbikge1xuICAgIHJldHVybiAod2luZG93LnJlcXVlc3RBbmltYXRpb25GcmFtZSB8fFxuICAgICAgICB3aW5kb3cud2Via2l0UmVxdWVzdEFuaW1hdGlvbkZyYW1lIHx8XG4gICAgICAgIHdpbmRvdy5tb3pSZXF1ZXN0QW5pbWF0aW9uRnJhbWUgfHxcbiAgICAgICAgZnVuY3Rpb24oY2FsbGJhY2spIHtcbiAgICAgICAgICAgIHdpbmRvdy5zZXRUaW1lb3V0KGNhbGxiYWNrLCAxMDAwIC8gNjApO1xuICAgICAgICB9KShmdW5jdGlvbigpIHtcbiAgICAgICAgZm4oKTtcbiAgICB9KTtcbn1cblxuZXhwb3J0IGZ1bmN0aW9uIGluZGV4T2YobmVlZGxlLCBoYXlzdGFjaykge1xuICAgIGlmICghKGhheXN0YWNrIGluc3RhbmNlb2YgQXJyYXkpKSB7XG4gICAgICAgIHRocm93IG5ldyBFcnJvcignSGF5c3RhY2sgaXMgbm90IGFuIEFycmF5Jyk7XG4gICAgfVxuXG4gICAgaWYgKGhheXN0YWNrLmluZGV4T2YpIHtcbiAgICAgICAgcmV0dXJuIGhheXN0YWNrLmluZGV4T2YobmVlZGxlKTtcbiAgICB9IGVsc2Uge1xuICAgICAgICBmb3IgKHZhciBpID0gMDsgaSA8IGhheXN0YWNrLmxlbmd0aDsgaSsrKSB7XG4gICAgICAgICAgICBpZiAoaGF5c3RhY2tbaV0gPT09IG5lZWRsZSkge1xuICAgICAgICAgICAgICAgIHJldHVybiBpO1xuICAgICAgICAgICAgfVxuICAgICAgICB9XG4gICAgICAgIHJldHVybiAtMTtcbiAgICB9XG59XG5cblxuZXhwb3J0IHZhciBpc0Z1bmN0aW9uID0gKHR5cGVvZiAvLi8gIT0gJ2Z1bmN0aW9uJyAmJiB0eXBlb2YgSW50OEFycmF5ICE9ICdvYmplY3QnKSA/IFxuICAgIGZ1bmN0aW9uIGlzRnVuY3Rpb24ob2JqKSB7XG4gICAgICAgIHJldHVybiB0eXBlb2Ygb2JqID09ICdmdW5jdGlvbicgfHwgZmFsc2U7XG4gICAgfSA6IGZ1bmN0aW9uIGlzRnVuY3Rpb24ob2JqKSB7XG4gICAgICAgIHJldHVybiB0b1N0cmluZy5jYWxsKG9iaikgPT09ICdbb2JqZWN0IEZ1bmN0aW9uXSc7XG4gICAgfVxuXG5leHBvcnQgZnVuY3Rpb24gZm5CaW5kKGZuLCBjb250ZXh0LCBib3VuZEFyZ3MpIHtcblxuICAgIGlmIChGdW5jdGlvbi5wcm90b3R5cGUuYmluZCAhPT0gdW5kZWZpbmVkKSB7XG4gICAgICAgIHJldHVybiBGdW5jdGlvbi5wcm90b3R5cGUuYmluZC5hcHBseShmbiwgW2NvbnRleHRdLmNvbmNhdChib3VuZEFyZ3MgfHwgW10pKTtcbiAgICB9XG5cbiAgICB2YXIgYm91bmQgPSBmdW5jdGlvbigpIHtcblxuICAgICAgICAvLyBKb2luIHRoZSBhbHJlYWR5IGFwcGxpZWQgYXJndW1lbnRzIHRvIHRoZSBub3cgY2FsbGVkIG9uZXMgKGFmdGVyIGNvbnZlcnRpbmcgdG8gYW4gYXJyYXkgYWdhaW4pLlxuICAgICAgICB2YXIgYXJncyA9IChib3VuZEFyZ3MgfHwgW10pLmNvbmNhdChBcnJheS5wcm90b3R5cGUuc2xpY2UuY2FsbChhcmd1bWVudHMsIDApKTtcblxuICAgICAgICAvLyBJZiBub3QgYmVpbmcgY2FsbGVkIGFzIGEgY29uc3RydWN0b3JcbiAgICAgICAgaWYgKCEodGhpcyBpbnN0YW5jZW9mIGJvdW5kKSkge1xuICAgICAgICAgICAgLy8gcmV0dXJuIHRoZSByZXN1bHQgb2YgdGhlIGZ1bmN0aW9uIGNhbGxlZCBib3VuZCB0byB0YXJnZXQgYW5kIHBhcnRpYWxseSBhcHBsaWVkLlxuICAgICAgICAgICAgcmV0dXJuIGZuLmFwcGx5KGNvbnRleHQsIGFyZ3MpO1xuICAgICAgICB9XG4gICAgICAgIC8vIElmIGJlaW5nIGNhbGxlZCBhcyBhIGNvbnN0cnVjdG9yLCBhcHBseSB0aGUgZnVuY3Rpb24gYm91bmQgdG8gc2VsZi5cbiAgICAgICAgZm4uYXBwbHkodGhpcywgYXJncyk7XG4gICAgfTtcbiAgICAvLyBBdHRhY2ggdGhlIHByb3RvdHlwZSBvZiB0aGUgZnVuY3Rpb24gdG8gb3VyIG5ld2x5IGNyZWF0ZWQgZnVuY3Rpb24uXG4gICAgYm91bmQucHJvdG90eXBlID0gZm4ucHJvdG90eXBlO1xuICAgIHJldHVybiBib3VuZDtcbn1cblxuZXhwb3J0IGZ1bmN0aW9uIHJlbW92ZUZyb21BcnJheShpdGVtLCBhcnJheSkge1xuICAgIHZhciBpbmRleCA9IGluZGV4T2YoaXRlbSwgYXJyYXkpO1xuXG4gICAgaWYgKGluZGV4ID09PSAtMSkge1xuICAgICAgICB0aHJvdyBuZXcgRXJyb3IoJ0NhblxcJ3QgcmVtb3ZlIGl0ZW0gZnJvbSBhcnJheS4gSXRlbSBpcyBub3QgaW4gdGhlIGFycmF5Jyk7XG4gICAgfVxuXG4gICAgYXJyYXkuc3BsaWNlKGluZGV4LCAxKTtcbn1cblxuZXhwb3J0IGZ1bmN0aW9uIG5vdygpIHtcbiAgICBpZiAodHlwZW9mIERhdGUubm93ID09PSAnZnVuY3Rpb24nKSB7XG4gICAgICAgIHJldHVybiBEYXRlLm5vdygpO1xuICAgIH0gZWxzZSB7XG4gICAgICAgIHJldHVybiAobmV3IERhdGUoKSkuZ2V0VGltZSgpO1xuICAgIH1cbn1cblxuZXhwb3J0IGZ1bmN0aW9uIGdldFVuaXF1ZUlkKCkge1xuICAgIHJldHVybiAoTWF0aC5yYW5kb20oKSAqIDEwMDAwMDAwMDAwMDAwMDApXG4gICAgICAgIC50b1N0cmluZygzNilcbiAgICAgICAgLnJlcGxhY2UoJy4nLCAnJyk7XG59XG5cbi8qKlxuICogQSBiYXNpYyBYU1MgZmlsdGVyLiBJdCBpcyB1bHRpbWF0ZWx5IHVwIHRvIHRoZVxuICogaW1wbGVtZW50aW5nIGRldmVsb3BlciB0byBtYWtlIHN1cmUgdGhlaXIgcGFydGljdWxhclxuICogYXBwbGljYXRpb25zIGFuZCB1c2VjYXNlcyBhcmUgc2F2ZSBmcm9tIGNyb3NzIHNpdGUgc2NyaXB0aW5nIGF0dGFja3NcbiAqXG4gKiBAcGFyYW0gICB7U3RyaW5nfSBpbnB1dFxuICogQHBhcmFtICAgIHtCb29sZWFufSBrZWVwVGFnc1xuICpcbiAqIEByZXR1cm5zIHtTdHJpbmd9IGZpbHRlcmVkIGlucHV0XG4gKi9cbmV4cG9ydCBmdW5jdGlvbiBmaWx0ZXJYc3MoaW5wdXQsIGtlZXBUYWdzKSB7XG5cbiAgICB2YXIgb3V0cHV0ID0gaW5wdXRcbiAgICAgICAgLnJlcGxhY2UoL2phdmFzY3JpcHQvZ2ksICdqJiM5Nzt2YXNjcmlwdCcpXG4gICAgICAgIC5yZXBsYWNlKC9leHByZXNzaW9uL2dpLCAnZXhwciYjMTAxO3NzaW9uJylcbiAgICAgICAgLnJlcGxhY2UoL29ubG9hZC9naSwgJ29ubG8mIzk3O2QnKVxuICAgICAgICAucmVwbGFjZSgvc2NyaXB0L2dpLCAnJiMxMTU7Y3JpcHQnKVxuICAgICAgICAucmVwbGFjZSgvb25lcnJvci9naSwgJ29uJiMxMDE7cnJvcicpO1xuXG4gICAgaWYgKGtlZXBUYWdzID09PSB0cnVlKSB7XG4gICAgICAgIHJldHVybiBvdXRwdXQ7XG4gICAgfSBlbHNlIHtcbiAgICAgICAgcmV0dXJuIG91dHB1dFxuICAgICAgICAgICAgLnJlcGxhY2UoLz4vZywgJyZndDsnKVxuICAgICAgICAgICAgLnJlcGxhY2UoLzwvZywgJyZsdDsnKTtcbiAgICB9XG59XG5cbi8qKlxuICogUmVtb3ZlcyBodG1sIHRhZ3MgZnJvbSBhIHN0cmluZ1xuICpcbiAqIEBwYXJhbSAgIHtTdHJpbmd9IGlucHV0XG4gKlxuICogQHJldHVybnMge1N0cmluZ30gaW5wdXQgd2l0aG91dCB0YWdzXG4gKi9cbmV4cG9ydCBmdW5jdGlvbiBzdHJpcFRhZ3MoaW5wdXQpIHtcbiAgICByZXR1cm4gJC50cmltKGlucHV0LnJlcGxhY2UoLyg8KFtePl0rKT4pL2lnLCAnJykpO1xufVxuIiwibW9kdWxlLmV4cG9ydHMgPSBfX1dFQlBBQ0tfRVhURVJOQUxfTU9EVUxFX2pxdWVyeV9fOyJdLCJzb3VyY2VSb290IjoiIn0=