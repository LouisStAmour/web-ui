// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * These are not quite unit tests, since we build on top of the analyzer and the
 * html5parser to build the input for each test.
 */
library emitter_test;

import 'package:html5lib/dom.dart';
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';
import 'package:web_ui/src/analyzer.dart';
import 'package:web_ui/src/code_printer.dart';
import 'package:web_ui/src/dart_parser.dart';
import 'package:web_ui/src/emitters.dart';
import 'package:web_ui/src/html5_utils.dart';
import 'package:web_ui/src/info.dart';
import 'package:web_ui/src/messages.dart';
import 'package:web_ui/src/paths.dart';
import 'testing.dart';

main() {
  useCompactVMConfiguration();
  group('emit element field', () {
    group('declaration', () {
      test('no data binding', () {
        var tree = '<div></div>';
        expect(_declarations(tree), equals(''));
      });

      test('id only, no data binding', () {
        var tree = '<div id="one"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __one;'));
        expect(_declarations(tree, isClass: false), equals('var __one;'));
      });

      test('action with no id', () {
        var tree = '<div on-foo="bar(\$event)"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __e0;'));
        expect(_declarations(tree, isClass: false), equals('var __e0;'));
      });

      test('action with id', () {
        var tree = '<div id="my-id" on-foo="bar(\$event)"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __myId;'));
        expect(_declarations(tree, isClass: false), equals('var __myId;'));
      });

      test('1 way binding with no id', () {
        var tree = '<div foo="{{bar}}"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __e0;'));
        expect(_declarations(tree, isClass: false), equals('var __e0;'));
      });

      test('1 way binding with id', () {
        var tree = '<div id="my-id" foo="{{bar}}"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __myId;'));
        expect(_declarations(tree, isClass: false), equals('var __myId;'));
      });

      test('1 way class binding with no id', () {
        var tree = '<div class="{{bar}}"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __e0;'));
        expect(_declarations(tree, isClass: false), equals('var __e0;'));
      });

      test('1 way class binding with id', () {
        var tree = '<div id="my-id" class="{{bar}}"></div>';
        expect(_declarations(tree), equals('autogenerated.DivElement __myId;'));
        expect(_declarations(tree, isClass: false), equals('var __myId;'));
      });

      test('2 way binding with no id', () {
        var tree = '<input bind-value="bar"></input>';
        expect(_declarations(tree),
            equals('autogenerated.InputElement __e0;'));
        expect(_declarations(tree, isClass: false), equals('var __e0;'));
      });

      test('2 way binding with id', () {
        var tree = '<input id="my-id" bind-value="bar"></input>';
        expect(_declarations(tree),
            equals('autogenerated.InputElement __myId;'));
        expect(_declarations(tree, isClass: false), equals('var __myId;'));
      });

      test('1 way binding in content with no id', () {
        var tree = '<div>{{bar}}</div>';
        expect(_declarations(tree), 'autogenerated.DivElement __e1;');
        expect(_declarations(tree, isClass: false), equals('var __e1;'));
      });

      test('1 way binding in content with id', () {
        var tree = '<div id="my-id">{{bar}}</div>';
        expect(_declarations(tree), 'autogenerated.DivElement __myId;');
        expect(_declarations(tree, isClass: false), equals('var __myId;'));
      });
    });

    group('init', () {
      test('no data binding', () {
        var elem = parseSubtree('<div></div>');
        expect(_created(elem), equals(''));
      });

      test('id only, no data binding', () {
        var elem = parseSubtree('<div id="one"></div>');
        expect(_init(elem), equals("__one = _root.query('#one');"));
      });

      test('action with no id', () {
        var elem = parseSubtree('<div on-foo="bar(\$event)"></div>');
        expect(_init(elem), equals("__e0 = _root.query('#__e-0');"));
      });

      test('action with id', () {
        var elem = parseSubtree('<div id="my-id" on-foo="bar(\$event)"></div>');
        expect(_init(elem), equals("__myId = _root.query('#my-id');"));
      });

      test('1 way binding with no id', () {
        var elem = parseSubtree('<div class="{{bar}}"></div>');
        expect(_init(elem), equals("__e0 = _root.query('#__e-0');"));
      });

      test('1 way binding with id', () {
        var elem = parseSubtree('<div id="my-id" class="{{bar}}"></div>');
        expect(_init(elem), equals("__myId = _root.query('#my-id');"));
      });

      test('2 way binding with no id', () {
        var elem = parseSubtree('<input bind-value="bar"></input>');
        expect(_init(elem), equals("__e0 = _root.query('#__e-0');"));
      });

      test('2 way binding with id', () {
        var elem = parseSubtree(
          '<input id="my-id" bind-value="bar"></input>');
        expect(_init(elem), equals("__myId = _root.query('#my-id');"));
      });

      test('sibling of a data-bound text node, with id and children', () {
        var elem = parseSubtree('<div id="a1">{{x}}<div id="a2">a</div></div>');
        expect(_init(elem, child: 1), "__a2 = __html0.clone(true);");
      });
    });

    group('type', () {
      htmlElementNames.forEach((tag, className) {
        // Skip script and body tags, we don't create fields for them.
        if (tag == 'script' || tag == 'body') return;

        test('$tag -> $className', () {
          var elem = new Element(tag)..attributes['class'] = "{{bar}}";
          expect(_declarationsForElem(elem),
              equals('autogenerated.$className __e0;'));
        });
      });
    });
  });

  group('emit text node field', () {
    test('declaration', () {
      var tree = '<div>{{bar}}</div>';
      expect(_declarations(tree, child: 0), '');
    });

    test('created', () {
      var elem = parseSubtree('<div>{{bar}}</div>');
      expect(_created(elem, child: 0),
          r"var __binding0 = __t.contentBind(() => bar, false);");
    });

    test('created - final', () {
      var elem = parseSubtree('<div>{{bar | final}}</div>');
      expect(_created(elem, child: 0),
          r"var __binding0 = __t.contentBind(() => bar, true);");
    });
  });

  group('emit event listeners', () {
    test('created', () {
      var elem = parseSubtree('<div on-foo="bar(\$event)"></div>');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          r'__t.listen(__e0.onFoo, ($event) { bar($event); });'));
    });

    test('created for input value data bind', () {
      var elem = parseSubtree('<input bind-value="bar"></input>');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          r'__t.listen(__e0.onInput, ($event) { bar = __e0.value; }); '
          '__t.oneWayBind(() => bar, (e) { __e0.value = e; }, false, false);'));
    });
  });

  group('emit data binding watchers for attributes', () {
    test('created', () {
      var elem = parseSubtree('<div foo="{{bar}}"></div>');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          "__t.oneWayBind(() => bar, (e) { "
              "__e0.attributes['foo'] = e; }, false, false);"));
    });

    test('created for 1-way binding with dom accessor', () {
      var elem = parseSubtree('<input value="{{bar}}">');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          "__t.oneWayBind(() => bar, (e) { __e0.value = e; }, false, false);"));
    });

    test('created for 2-way binding with dom accessor', () {
      var elem = parseSubtree('<input bind-value="bar">');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          r'__t.listen(__e0.onInput, ($event) { bar = __e0.value; }); '
          '__t.oneWayBind(() => bar, (e) { __e0.value = e; }, false, false);'));
    });

    test('created for data attribute', () {
      var elem = parseSubtree('<div data-foo="{{bar}}"></div>');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          "__t.oneWayBind(() => bar, (e) { "
          "__e0.attributes['data-foo'] = e; }, false, false);"));
    });

    test('created for class', () {
      var elem = parseSubtree('<div class="{{bar}} {{foo}}" />');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          "__t.bindClass(__e0, () => bar, false); "
          "__t.bindClass(__e0, () => foo, false);"));
    });

    test('created for style', () {
      var elem = parseSubtree('<div style="{{bar}}"></div>');
      expect(_created(elem), equalsIgnoringWhitespace(
          r"__e0 = _root.query('#__e-0'); "
          '__t.bindStyle(__e0, () => bar, false);'));
    });

    group('- with final field', () {
      test('created', () {
        var elem = parseSubtree('<div foo="{{bar | final}}"></div>');
        expect(_created(elem), equalsIgnoringWhitespace(
            r"__e0 = _root.query('#__e-0'); "
            "__t.oneWayBind(() => bar, (e) { "
                "__e0.attributes['foo'] = e; }, true, false);"));
      });

      test('created for 1-way binding with dom accessor', () {
        var elem = parseSubtree('<input value="{{bar | final}}">');
        expect(_created(elem), equalsIgnoringWhitespace(
            r"__e0 = _root.query('#__e-0'); "
            r"__t.oneWayBind(() => bar, "
            r"(e) { __e0.value = e; }, true, false);"));
      });

      test('created for 2-way binding with dom accessor', () {
        var elem = parseSubtree('<input bind-value="bar | final">');
        expect(_created(elem), equalsIgnoringWhitespace(
            r"__e0 = _root.query('#__e-0'); "
            r'__t.listen(__e0.onInput, ($event) { bar = __e0.value; }); '
            r'__t.oneWayBind(() => bar, '
            r'(e) { __e0.value = e; }, true, false); '));
      });

      test('created for data attribute', () {
        var elem = parseSubtree('<div data-foo="{{bar | final}}"></div>');
        expect(_created(elem), equalsIgnoringWhitespace(
            r"__e0 = _root.query('#__e-0'); "
            "__t.oneWayBind(() => bar, (e) { "
            "__e0.attributes['data-foo'] = e; }, true, false);"));
      });

      test('created for class', () {
        var elem = parseSubtree('<div class="{{a | final}}{{b | final}}"/>');
        expect(_created(elem), equalsIgnoringWhitespace(
            r"__e0 = _root.query('#__e-0'); "
            "__t.bindClass(__e0, () => a, true); "
            "__t.bindClass(__e0, () => b, true);"));
      });

      test('created for style', () {
        var elem = parseSubtree('<div style="{{bar | final}}"></div>');
        expect(_created(elem), equalsIgnoringWhitespace(
            r"__e0 = _root.query('#__e-0'); "
            '__t.bindStyle(__e0, () => bar, true);'));
      });
    });
  });

  group('emit data binding watchers for content', () {

    test('declaration', () {
      var tree = '<div>fo{{bar}}o</div>';
      expect(_declarations(tree, child: 1), '');
    });

    test('created', () {
      var elem = parseSubtree('<div>fo{{bar}}o</div>');
      expect(_created(elem, child: 1),
        r"var __binding0 = __t.contentBind(() => bar, false);");
    });

    test('created - final', () {
      var elem = parseSubtree('<div>fo{{bar | final}}o</div>');
      expect(_created(elem, child: 1),
        r"var __binding0 = __t.contentBind(() => bar, true);");
    });
  });

  group('emit main page class', () {
    var messages;
    setUp(() {
      messages = new Messages.silent();
    });

    test('external resource URLs', () {
      var html =
          '<html><head>'
          '<script src="http://ex.com/a.js" type="text/javascript"></script>'
          '<script src="foobar:a.js" type="text/javascript"></script>'
          '<script src="//example.com/a.js" type="text/javascript"></script>'
          '<script src="/a.js" type="text/javascript"></script>'
          '<link href="http://example.com/a.css" rel="stylesheet">'
          '<link href="foobar:a.css" rel="stylesheet">'
          '<link href="//example.com/a.css" rel="stylesheet">'
          '<link href="/a.css" rel="stylesheet">'
          '</head><body></body></html>';
      var doc = parseDocument(html);
      var fileInfo = analyzeNodeForTesting(doc, messages);
      fileInfo.inlinedCode = new DartCodeInfo('main', null, [], '', null);
      var paths = _newPathMapper('a', 'b', true);

      transformMainHtml(doc, fileInfo, paths, false, true, messages);
      expect(doc.outerHtml,
          '\n<!-- This file was auto-generated from ${fileInfo.inputPath}. -->'
          '\n<html><head>'
          '<style>template { display: none; }</style>'
          '<script src="http://ex.com/a.js" type="text/javascript"></script>'
          '<script src="foobar:a.js" type="text/javascript"></script>'
          '<script src="//example.com/a.js" type="text/javascript"></script>'
          '<script src="/a.js" type="text/javascript"></script>'
          '<link href="http://example.com/a.css" rel="stylesheet">'
          '<link href="foobar:a.css" rel="stylesheet">'
          '<link href="//example.com/a.css" rel="stylesheet">'
          '<link href="/a.css" rel="stylesheet">'
          '</head><body>'
          '<script type="text/javascript" src="packages/browser/dart.js">'
          '</script>\n</body></html>');
    });

    test('transform css urls', () {
      var html = '<html><head>'
          '<link rel="stylesheet" href="a.css">'
          '</head><body></body></html>';

      var doc = parseDocument(html);
      var fileInfo = analyzeNodeForTesting(doc, messages, filepath: 'a.html');
      fileInfo.inlinedCode = new DartCodeInfo('main', null, [], '', null);
      // Issue #207 happened because we used to mistakenly take the path of
      // the external file when transforming the urls in the html file.
      fileInfo.externalFile = 'dir/a.dart';
      var paths = _newPathMapper('', 'out', true);
      transformMainHtml(doc, fileInfo, paths, false, true, messages);
      var emitter = new EntryPointEmitter(fileInfo);
      emitter.run(paths, null, true);

      expect(doc.outerHtml,
          '\n<!-- This file was auto-generated from ${fileInfo.inputPath}. -->'
          '\n<html><head>'
          '<style>template { display: none; }</style>'
          '<link rel="stylesheet" href="../a.css">'
          '</head><body>'
          '<script type="text/javascript" src="packages/browser/dart.js">'
          '</script>\n'
          '</body></html>');
    });


    test('no css urls if no styles', () {
      var html = '<html><head></head><body></body></html>';
      var doc = parseDocument(html);
      var fileInfo = analyzeNodeForTesting(doc, messages, filepath: 'a.html');
      fileInfo.inlinedCode = new DartCodeInfo('main', null, [], '', null);
      fileInfo.externalFile = 'dir/a.dart';
      var paths = _newPathMapper('', 'out', true);
      // TODO(jmesserly): this test is not quite right because we're supplying
      // the hasCss property. We should probably convert this to be a compiler
      // test.
      transformMainHtml(doc, fileInfo, paths, false, true, messages);
      var emitter = new EntryPointEmitter(fileInfo);
      emitter.run(paths, null, true);

      expect(doc.outerHtml,
          '\n<!-- This file was auto-generated from ${fileInfo.inputPath}. -->'
          '\n<html><head>'
          '<style>template { display: none; }</style>'
          '</head><body>'
          '<script type="text/javascript" src="packages/browser/dart.js">'
          '</script>\n'
          '</body></html>');
    });
  });
}

_init(Element elem, {int child}) {
  var info = analyzeElement(elem, new Messages.silent());
  var printer = new CodePrinter(0);
  if (child != null) {
    info = info.children[child];
  }
  emitInitializations(info, new Context(printer: printer), new CodePrinter(0));
  printer.build(null);
  return printer.text.trim();
}

_created(Element elem, {int child}) {
  var printer = _recurse(elem, true, child).printer;
  printer.build(null);
  return printer.text.trim();
}

_declarations(String tree, {bool isClass: true, int child}) {
  return _recurse(parseSubtree(tree), isClass, child)
      .declarations.toString().trim();
}

_declarationsForElem(Element elem, {bool isClass: true, int child}) {
  return _recurse(elem, isClass, child).declarations.toString().trim();
}

Context _recurse(Element elem, bool isClass, int child) {
  var info = analyzeElement(elem, new Messages.silent());
  var context = new Context(isClass: isClass);
  if (child != null) {
    info = info.children[child];
  }
  new RecursiveEmitter(null, context).visit(info);
  return context;
}

_newPathMapper(String baseDir, String outDir, bool forceMangle) =>
    new PathMapper(baseDir, outDir, 'packages', forceMangle);
