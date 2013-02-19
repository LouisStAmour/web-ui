// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/** Collects several code emitters for the template tool. */
library emitters;

import 'dart:json' as json;

import 'package:csslib/parser.dart' as css;
import 'package:csslib/visitor.dart';
import 'package:html5lib/dom.dart';
import 'package:html5lib/dom_parsing.dart';
import 'package:source_maps/span.dart' show Span, FileLocation;

import 'code_printer.dart';
import 'codegen.dart' as codegen;
import 'dart_parser.dart' show DartCodeInfo;
import 'html5_setters.g.dart';
import 'html5_utils.dart';
import 'info.dart';
import 'messages.dart';
import 'refactor.dart';
import 'utils.dart';

/**
 * Context used by an emitter. Typically representing where to generate code
 * and additional information, such as total number of generated identifiers.
 */
class Context {
  final Declarations declarations;
  final CodePrinter printer;
  final bool isClass;

  Context({Declarations declarations, CodePrinter printer,
           bool isClass: false, int indent: 0})
      : this.declarations = declarations != null
            ? declarations : new Declarations(!isClass, indent),
        this.isClass = isClass,
        this.printer = printer != null
             ? printer : new CodePrinter(isClass ? indent + 1 : indent);
}

/**
 * Generates a field for any element that has either event listeners or data
 * bindings.
 */
void emitDeclarations(ElementInfo info, Declarations declarations) {
  if (!info.isRoot) {
    var type = (info.node.namespace == 'http://www.w3.org/2000/svg')
        ? 'autogenerated_svg.SvgElement'
        : 'autogenerated.${typeForHtmlTag(info.node.tagName)}';
    declarations.add(type, info.identifier, info.node.sourceSpan);
  }
}

/** Initializes fields and variables pointing to a HTML element.  */
void emitInitializations(ElementInfo info,
    CodePrinter printer, CodePrinter childrenPrinter) {
  var id = info.identifier;
  if (info.createdInCode) {
    printer.addLine("$id = ${_emitCreateHtml(info.node)};",
        span: info.node.sourceSpan);
  } else if (!info.isRoot) {
    var parentId = '_root';
    for (var p = info.parent; p != null; p = p.parent) {
      if (p.identifier != null) {
        parentId = p.identifier;
        break;
      }
    }
    printer.addLine("$id = $parentId.query('#${info.node.id}');",
        span: info.node.sourceSpan);
  }

  printer.add(childrenPrinter);

  if (info.childrenCreatedInCode && !info.hasIterate && !info.hasIfCondition) {
    _emitAddNodes(printer, info.children, '$id.nodes');
  }
}

/**
 * Emit statements that add 1 or more HTML nodes directly as children of
 * [target] (which can be a template or another node.
 */
_emitAddNodes(CodePrinter printer, List<NodeInfo> nodes, String target) {
  if (nodes.length == 1) {
    printer.addLine("$target.add(${_createChildExpression(nodes.single)});");
  } else if (nodes.length > 0) {
    printer..insertIndent()
        ..add("$target.addAll([")
        ..indent += 2;
    for (int i = 0; i < nodes.length; i++) {
      var exp = _createChildExpression(nodes[i]);
      if (i > 0) printer.insertIndent();
      printer..add(exp, span: nodes[i].node.sourceSpan)
          ..add(i == nodes.length - 1 ? ']);\n' : ',\n');
    }
    printer.indent -= 2;
  }
}

/**
 * Generates event listeners attached to a node and code that attaches/detaches
 * the listener.
 */
void emitEventListeners(ElementInfo info, CodePrinter printer) {
  var id = info.identifier;
  info.events.forEach((name, events) {
    for (var event in events) {
      // Note: the name $event is from AngularJS and is essentially public
      // API. See issue #175.
      // TODO(sigmund): update when we track spans for each attribute separately
      printer.addLine('__t.listen($id.${event.streamName},'
          ' (\$event) { ${event.action(id)}; });', span: info.node.sourceSpan);
    }
  });
}

/** Emits attributes with some form of data-binding. */
void emitAttributeBindings(ElementInfo info, CodePrinter printer) {
  info.attributes.forEach((name, attr) {
    if (attr.isClass) {
      _emitClassAttributeBinding(info.identifier, attr, printer,
          info.node.sourceSpan);
    } else if (attr.isStyle) {
      _emitStyleAttributeBinding(info.identifier, attr, printer,
          info.node.sourceSpan);
    } else if (attr.isSimple) {
      _emitSimpleAttributeBinding(info, name, attr, printer);
    } else if (attr.isText) {
      _emitTextAttributeBinding(info, name, attr, printer);
    }
  });
}

// TODO(sigmund): extract the span from attr when it's available
void _emitClassAttributeBinding(
    String identifier, AttributeInfo attr, CodePrinter printer, Span span) {
  for (var binding in attr.bindings) {
    printer.addLine(
        '__t.bindClass($identifier, () => ${binding.exp}, ${binding.isFinal});',
        span: span);
  }
}

void _emitStyleAttributeBinding(
    String identifier, AttributeInfo attr, CodePrinter printer, Span span) {
  var exp = attr.boundValue;
  var isFinal = attr.isBindingFinal;
  printer.addLine('__t.bindStyle($identifier, () => $exp, $isFinal);',
      span: span);
}

void _emitSimpleAttributeBinding(ElementInfo info,
    String name, AttributeInfo attr, CodePrinter printer) {
  var binding = attr.boundValue;
  var isFinal = attr.isBindingFinal;
  var field = _findDomField(info, name);
  var isUrl = urlAttributes.contains(name);
  printer.addLine('__t.oneWayBind(() => $binding, '
        '(e) { ${info.identifier}.$field = e; }, $isFinal, $isUrl);',
      span: info.node.sourceSpan);
  if (attr.customTwoWayBinding) {
    printer.addLine('__t.oneWayBind(() => ${info.identifier}.$field, '
          '(__e) { $binding = __e; }, false);');
  }
}

void _emitTextAttributeBinding(ElementInfo info,
    String name, AttributeInfo attr, CodePrinter printer) {
  var textContent = attr.textContent.map(escapeDartString).toList();
  var setter = _findDomField(info, name);
  var content = new StringBuffer();
  var binding;
  var isFinal;
  if (attr.bindings.length == 0) {
    // Constant attribute passed to initialize a web component field. If the
    // attribute is a normal DOM attribute, we don't need to do anything.
    if (!setter.startsWith('xtag.')) return;
    assert(textContent.length == 1);
    content.write(textContent[0]);
    isFinal = true;
  } else if (attr.bindings.length == 1) {
    binding = attr.boundValue;
    isFinal = attr.isBindingFinal;
    content..write(textContent[0])
        ..write('\${__e.newValue}')
        ..write(textContent[1]);
  } else {
    // TODO(jmesserly): we could probably do something faster than a list
    // for watching on multiple bindings.
    binding = '[${attr.bindings.map((b) => b.exp).join(", ")}]';
    isFinal = attr.bindings.every((b) => b.isFinal);

    for (int i = 0; i < attr.bindings.length; i++) {
      content..write(textContent[i])..write("\${__e.newValue[$i]}");
    }
    content.write(textContent.last);
  }

  var exp = "'$content'";
  if (urlAttributes.contains(name)) {
    exp = 'autogenerated.sanitizeUri($exp)';
  }
  printer.addLine("__t.bind(() => $binding, "
      " (__e) { ${info.identifier}.$setter = $exp; }, $isFinal);",
      span: info.node.sourceSpan);

}

/** Generates watchers that listen on data changes and update text content. */
void emitContentDataBinding(TextInfo info, CodePrinter printer) {
  var exp = info.binding.exp;
  var isFinal = info.binding.isFinal;
  printer.addLine(
      'var ${info.identifier} = __t.contentBind(() => $exp, $isFinal);',
      span: info.node.sourceSpan);
}

/**
 * Emits code for web component instantiation. For example, if the source has:
 *
 *     <x-hello>John</x-hello>
 *
 * And the component has been defined as:
 *
 *    <element name="x-hello" extends="div" constructor="HelloComponent">
 *      <template>Hello, <content>!</template>
 *      <script type="application/dart"></script>
 *    </element>
 *
 * This will ensure that the Dart HelloComponent for `x-hello` is created and
 * attached to the appropriate DOM node.
 */
void emitComponentCreation(ElementInfo info, CodePrinter printer) {
  var component = info.component;
  if (component == null) return;
  var id = info.identifier;
  printer..addLine('new ${component.constructor}.forElement($id);',
                   span: info.node.sourceSpan)
         ..addLine('__t.component($id);');
}

/**
 * Emits code for template conditionals like `<template instantiate="if test">`
 * or `<td template instantiate="if test">`.
 */
void emitConditional(TemplateInfo info, CodePrinter printer,
    Context childContext) {
  var cond = info.ifCondition;
  printer..addLine('__t.conditional(${info.identifier}, () => $cond, (__t) {',
                   span: info.node.sourceSpan)
      ..indent += 1
      ..add(childContext.declarations)
      ..add(childContext.printer)
      ..indent -= 1;
  _emitAddNodes(printer, info.children, '__t');
  printer..addLine('});\n');
}

/**
 * Emits code for template lists like `<template iterate='item in items'>` or
 * `<td template iterate='item in items'>`.
 */
void emitLoop(TemplateInfo info, CodePrinter printer, Context childContext) {
  var id = info.identifier;
  var items = info.loopItems;
  var loopVar = info.loopVariable;
  printer..addLine('__t.loop($id, () => $items, ($loopVar, __t) {',
                   span: info.node.sourceSpan)
      ..indent += 1
      ..add(childContext.declarations)
      ..add(childContext.printer)
      ..indent -= 1;
  _emitAddNodes(printer, info.children, '__t');
  printer..addLine(info.isTemplateElement
      ? '});' : '}, isTemplateElement: false);');
}


/**
 * An visitor that applies [NodeFieldEmitter], [EventListenerEmitter],
 * [DataValueEmitter], [ConditionalEmitter], and
 * [ListEmitter] recursively on a DOM tree.
 */
class RecursiveEmitter extends InfoVisitor {
  final FileInfo _fileInfo;
  Context _context;

  RecursiveEmitter(this._fileInfo, this._context);

  // TODO(jmesserly): currently visiting of components declared in a file is
  // handled separately. Consider refactoring so the base visitor works for us.
  visitFileInfo(FileInfo info) => visit(info.bodyInfo);

  void visitElementInfo(ElementInfo info) {
    if (info.identifier == null) {
      // No need to emit code for this node.
      super.visitElementInfo(info);
      return;
    }

    var indent = _context.printer.indent;
    var childPrinter = new CodePrinter(indent);
    emitDeclarations(info, _context.declarations);
    emitInitializations(info, _context.printer, childPrinter);
    emitEventListeners(info, _context.printer);
    emitAttributeBindings(info, _context.printer);
    emitComponentCreation(info, _context.printer);

    var childContext = null;
    if (info.hasIfCondition) {
      childContext = new Context(indent: indent + 1);
      emitConditional(info, _context.printer, childContext);
    } else if (info.hasIterate) {
      childContext = new Context(indent: indent + 1);
      emitLoop(info, _context.printer, childContext);
    } else {
      childContext = new Context(declarations: _context.declarations,
          printer: childPrinter, isClass: _context.isClass);
    }

    // Invoke super to visit children.
    var oldContext = _context;
    _context = childContext;
    super.visitElementInfo(info);
    _context = oldContext;
  }

  void visitTextInfo(TextInfo info) {
    if (info.identifier != null) {
      emitContentDataBinding(info, _context.printer);
    }
    super.visitTextInfo(info);
  }
}

/** Build list of every CSS class name in a stylesheet. */
class ClassVisitor extends Visitor {
  final Set<String> classes = new Set();

  void visitClassSelector(ClassSelector node) {
    classes.add(node.name);
  }
}

/**
 * Style sheet polyfill, each CSS class name referenced (selector) is prepended
 * with prefix_ (if prefix is non-null).
 */
class StyleSheetEmitter extends CssPrinter {
  final String _prefix;

  StyleSheetEmitter(this._prefix);

  void visitClassSelector(ClassSelector node) {
    if (_prefix == null) {
      super.visitClassSelector(node);
    } else {
      emit('.${_prefix}_${node.name}');
    }
  }
}

Map computeCssClasses(ComponentInfo info, {scopedStyles: true}) {
  Map classNames = {};
  if (info.styleSheet != null) {
    var classes = (new ClassVisitor()..visitTree(info.styleSheet)).classes;
    for (var cssClass in classes) {
      classNames[cssClass] =
          scopedStyles ? '${info.tagName}_$cssClass' : cssClass;
    }
  }
  return classNames;
}

/** Helper function to emit the contents of the style tag. */
String emitStyleSheet(StyleSheet ss, [String prefix]) =>
  ((new StyleSheetEmitter(prefix))..visitTree(ss, pretty: true)).toString();

/** Generates the class corresponding to a single web component. */
class WebComponentEmitter extends RecursiveEmitter {
  final Messages messages;

  WebComponentEmitter(FileInfo info, this.messages)
      : super(info, new Context(isClass: true, indent: 1));

  CodePrinter run(ComponentInfo info, PathInfo pathInfo,
      TextEditTransaction transaction) {
    var elemInfo = info.elemInfo;

    // TODO(terry): Eliminate when polyfill is the default.
    var cssPolyfill = messages.options.processCss;

    // elemInfo is pointing at template tag (no attributes).
    assert(elemInfo.node.tagName == 'element');
    for (var childInfo in elemInfo.children) {
      var node = childInfo.node;
      if (node.tagName == 'template') {
        elemInfo = childInfo;
        break;
      }
    }
    _context.declarations.add('autogenerated.Template', '__t',
        elemInfo.node.sourceSpan);

    if (info.element.attributes['apply-author-styles'] != null) {
      _context.printer.addLine('if (_root is autogenerated.ShadowRoot) '
          '_root.applyAuthorStyles = true;');
      // TODO(jmesserly): warn at runtime if apply-author-styles was not set,
      // and we don't have Shadow DOM support? In that case, styles won't have
      // proper encapsulation.
    }
    if (info.template != null && !elemInfo.childrenCreatedInCode) {

      // TODO(terry): Should style tag be emitted with scoped attribute?
      //              Seems superfluous should we always polyfill?  How to tell
      //              if we need to polyfill?
      var styleSheet = '';
      if (info.styleSheet != null) {
        var tag = cssPolyfill ? info.tagName : null;
        styleSheet =
            '<style>\n'
            '${emitStyleSheet(info.styleSheet, tag)}'
            '\n</style>';
      }

      // TODO(jmesserly): we need to emit code to run the <content> distribution
      // algorithm for browsers without ShadowRoot support.
      _context.printer
          ..insertIndent()
          ..add("_root.innerHtml = '''")
          ..add(escapeDartString(elemInfo.node.innerHtml, triple: true))
          ..add("''';\n");
    }

    visit(elemInfo);

    bool hasExtends = info.extendsComponent != null;
    var codeInfo = info.userCode;
    if (codeInfo == null) {
      assert(transaction == null);
      var superclass = hasExtends ? info.extendsComponent.constructor
          : 'autogenerated.WebComponent';
      codeInfo = new DartCodeInfo(null, null, [],
          'class ${info.constructor} extends $superclass {\n}', null);
    }

    if (transaction == null) {
      transaction = new TextEditTransaction(codeInfo.code, codeInfo.sourceFile);
    }

    var code = codeInfo.code;
    var match = codeInfo.findClass(info.constructor);
    if (match != null) {
      // Expand the headers to include web_ui imports, unless they are already
      // present.
      var libraryName = (codeInfo.libraryName != null)
          ? codeInfo.libraryName
          : info.tagName.replaceAll(new RegExp('[-./]'), '_');
      var header = new CodePrinter(0);
      header.add(codegen.header(info.declaringFile.path, libraryName));
      emitImports(codeInfo, info, pathInfo, header);
      header.addLine('');
      transaction.edit(0, codeInfo.directivesEnd, header);

      // Add the injected code at the beginning of the class definition.
      var cssClasses = json.stringify(
          computeCssClasses(info, scopedStyles: cssPolyfill));
      var classBody = new CodePrinter(1)
          ..add('\n')
          ..addLine('/** Autogenerated from the template. */')
          ..addLine('')
          ..addLine('/** CSS class constants. */')
          ..addLine('static Map<String, String> _css = $cssClasses;')
          ..addLine('')
          ..addLine('/**')
          ..addLine(" * Shadow root for this component. We use 'var' to allow"
                    " simulating shadow DOM")
          ..addLine(" * on browsers that don't support this feature.")
          ..addLine(' */')
          // TODO(sigmund): omit [_root] if the user already defined it.
          ..addLine('var _root;')
          ..add(_context.declarations)
          ..addLine('')
          ..addLine('${info.constructor}.forElement(e) : super.forElement(e);')
          ..addLine('')
          ..addLine('void created_autogenerated() {')
          ..addLine(hasExtends ? '  super.created_autogenerated();' : null)
          ..addLine('  _root = createShadowRoot();')
          ..addLine('  __t = new autogenerated.Template(_root);')
          ..add(_context.printer)
          ..addLine('  __t.create();')
          ..addLine('}')
          ..addLine('')
          ..addLine('void inserted_autogenerated() {')
          ..addLine(hasExtends ? '  super.inserted_autogenerated();' : null)
          ..addLine('  __t.insert();')
          ..addLine('}')
          ..addLine('')
          ..addLine('void removed_autogenerated() {')
          ..addLine(hasExtends ? '  super.removed_autogenerated();' : null)
          ..addLine('  __t.remove();')
          ..add('  ')
          ..addLine(_clearFields(_context.declarations))
          ..addLine('}')
          ..addLine('')
          ..addLine('void composeChildren() {')
          ..addLine('  super.composeChildren();')
          ..addLine('  if (_root is! autogenerated.ShadowRoot) _root = this;')
          ..addLine('}')
          ..addLine('')
          ..addLine('/** Original code from the component. */');
      transaction.edit(match.leftBracket.end, match.leftBracket.end, classBody);

      // Emit all the code in a single printer, keeping track of source-maps.
      return transaction.commit();
    } else {
      messages.error('please provide a class definition '
          'for ${info.constructor}:\n $code', info.element.sourceSpan,
          file: info.inputPath);
      return null;
    }
  }
}

/** Generates the class corresponding to the main html page. */
class MainPageEmitter extends RecursiveEmitter {
  MainPageEmitter(FileInfo fileInfo) : super(fileInfo, new Context(indent: 1));

  CodePrinter run(Document document, PathInfo pathInfo,
      TextEditTransaction transaction) {
    visit(_fileInfo.bodyInfo);

    // fix up the URLs to content that is not modified by the compiler
    document.queryAll('script').forEach((tag) {
      var src = tag.attributes["src"];
      if (tag.attributes['type'] == 'application/dart') {
        tag.remove();
      } else if (src != null) {
        tag.attributes["src"] = pathInfo.transformUrl(_fileInfo.path, src);
      }
    });
    document.queryAll('link').forEach((tag) {
      var href = tag.attributes['href'];
      if (tag.attributes['rel'] == 'components') {
       tag.remove();
      } else if (href != null) {
       tag.attributes['href'] = pathInfo.transformUrl(_fileInfo.path, href);
      }
    });


    var codeInfo = _fileInfo.userCode;
    if (codeInfo == null) {
      assert(transaction == null);
      codeInfo = new DartCodeInfo(null, null, [], 'main(){\n}', null);
    }

    if (transaction == null) {
      transaction = new TextEditTransaction(codeInfo.code, codeInfo.sourceFile);
    }

    var libraryName = codeInfo.libraryName != null
        ? codeInfo.libraryName : _fileInfo.libraryName;
    var header = new CodePrinter(0);
    header.add(codegen.header(_fileInfo.path, libraryName));
    emitImports(codeInfo, _fileInfo, pathInfo, header);
    header..addLine('')
          ..addLine('')
          ..addLine('// Original code');
    transaction.edit(0, codeInfo.directivesEnd, header);

    return (transaction.commit())
        ..addLine('')
        ..addLine('// Additional generated code')
        ..addLine('void init_autogenerated() {')
        ..indent += 1
        ..addLine('var _root = autogenerated.document.body;')
        ..add(_context.declarations)
        ..addLine('var __t = new autogenerated.Template(_root);')
        ..add(_context.printer)
        ..addLine('__t.create();')
        ..addLine('__t..insert();')
        ..indent -= 1
        ..addLine('}');
  }
}

void emitImports(DartCodeInfo codeInfo, LibraryInfo info, PathInfo pathInfo,
    CodePrinter printer) {
  var seenImports = new Set();
  addUnique(String importString, [location]) {
    if (!seenImports.contains(importString)) {
      printer.addLine(importString, location: location);
      seenImports.add(importString);
    }
  }

  // Add existing import, export, and part directives.
  var file = codeInfo.sourceFile;
  for (var d in codeInfo.directives) {
    addUnique(d.toString(), file != null ? file.location(d.offset) : null);
  }

  // Add imports only for those components used by this component.
  info.usedComponents.keys.forEach(
      (c) => addUnique("import '${pathInfo.relativePath(info, c)}';"));

  if (info is ComponentInfo) {
    // Inject an import to the base component.
    ComponentInfo component = info;
    var base = info.extendsComponent;
    if (base != null) {
      addUnique("import '${pathInfo.relativePath(info, base)}';");
    }
  }
}

/** Clears all fields in [declarations]. */
String _clearFields(Declarations declarations) {
  if (declarations.declarations.isEmpty) return '';
  var buff = new StringBuffer();
  for (var d in declarations.declarations) {
    buff.write('${d.name} = ');
  }
  buff.write('null;');
  return buff.toString();
}

String _createChildExpression(NodeInfo info) {
  if (info.identifier != null) return info.identifier;
  return _emitCreateHtml(info.node);
}

/**
 * An (runtime) expression to create the [node]. It always includes the node's
 * attributes, but only includes children nodes if [includeChildren] is true.
 */
String _emitCreateHtml(Node node) {
  if (node is Text) {
    return "new autogenerated.Text('${escapeDartString(node.value)}')";
  }

  // Namespace constants from:
  // http://dev.w3.org/html5/spec/namespaces.html#namespaces
  var isHtml = node.namespace == 'http://www.w3.org/1999/xhtml';
  var isSvg = node.namespace == 'http://www.w3.org/2000/svg';
  var isEmpty = node.attributes.length == 0 && node.nodes.length == 0;

  var constructor;
  // Generate precise types like "new ButtonElement()" if we can.
  if (isEmpty && isHtml) {
    constructor = htmlElementConstructors[node.tagName];
    if (constructor != null) {
      constructor = '$constructor()';
    } else {
      constructor = "Element.tag('${node.tagName}')";
    }
  } else if (isEmpty && isSvg) {
    constructor = "_svg.SvgElement.tag('${node.tagName}')";
  } else {
    // TODO(sigmund): does this work for the mathml namespace?
    var target = isSvg ? '_svg.SvgElement.svg' : 'Element.html';
    constructor = "$target('${escapeDartString(node.outerHtml)}')";
  }
  return 'new autogenerated.$constructor';
}

/**
 * Finds the correct expression to set an HTML attribute through the DOM.
 * It is important for correctness to use the DOM setter if it is available.
 * Otherwise changes will not be applied. This is most easily observed with
 * "InputElement.value", ".checked", etc.
 */
String _findDomField(ElementInfo info, String name) {
  var typeName = typeForHtmlTag(info.baseTagName);
  while (typeName != null) {
    var fields = htmlElementFields[typeName];
    if (fields != null) {
      var field = fields[name];
      if (field != null) return field;
    }
    typeName = htmlElementExtends[typeName];
  }
  // If we didn't find a DOM setter, and this is a component, set a property on
  // the component.
  if (info.component != null && !name.startsWith('data-')) {
    return 'xtag.${toCamelCase(name)}';
  }
  return "attributes['$name']";
}
