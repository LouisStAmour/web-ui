// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Parser for Dart code based on the experimental analyzer.
 */
library dart_parser;

import 'dart:utf';
import 'dart:math' as math;
import 'package:analyzer_experimental/src/generated/ast.dart';
import 'package:analyzer_experimental/src/generated/error.dart';
import 'package:analyzer_experimental/src/generated/java_core.dart';
import 'package:analyzer_experimental/src/generated/parser.dart';
import 'package:analyzer_experimental/src/generated/scanner.dart';
import 'package:source_maps/span.dart' show File, FileSpan;
import 'file_system/path.dart';
import 'info.dart';
import 'messages.dart';
import 'refactor.dart' show $CR, $LF;
import 'utils.dart';

/** Information extracted from a source Dart file. */
class DartCodeInfo {
  // TODO(jmesserly): VM hashCode performance workaround ...
  static int _nextHash = 0;
  final int hashCode = ++_nextHash;

  /** Library qualified identifier, if any. */
  final String libraryName;

  /** Library which the code is part-of, if any. */
  final String partOf;

  /** Declared imports, exports, and parts. */
  final List<Directive> directives;

  /** Source map information associated with this file. */
  final File sourceMapFile;

  /** The parsed code. */
  final CompilationUnit compilationUnit;

  /** The full source code. */
  final String code;

  DartCodeInfo(this.libraryName, this.partOf, this.directives, code, url,
      [compilationUnit])
      : this.code = code,
        this.compilationUnit = compilationUnit == null
          ? parseCompilationUnit(code) : compilationUnit,
        // TODO(sigmund): this works great for stand-alone dart files,
        // we need to fix this to handle inlined code (offsets need to be
        // adjusted based on the start of the html file)
        sourceMapFile = new File.text(url, code);

  int get directivesEnd {
    if (compilationUnit.directives.length == 0) return 0;
    return compilationUnit.directives.map((d) => d.end).max();
  }

  /** Gets the code after the [directives]. */
  String codeAfterDirectives() => code.substring(directivesEnd);

  ClassDeclaration findClass(String name) {
    for (var decl in compilationUnit.declarations) {
      if (decl is ClassDeclaration) {
        if (decl.name.name == name) return decl;
      }
    }
    return null;
  }
}

// TODO(jmesserly): I think Part and Import will have a common base class soon,
// which will make this easier.
SimpleStringLiteral getDirectiveUri(Directive directive) {
  if (directive is NamespaceDirective) {
    return (directive as NamespaceDirective).libraryUri;
  } else {
    return (directive as PartDirective).partUri;
  }
}

void setDirectiveUri(Directive directive, SimpleStringLiteral uri) {
  if (directive is NamespaceDirective) {
    (directive as NamespaceDirective).libraryUri2 = uri;
  } else {
    (directive as PartDirective).partUri2 = uri;
  }
}

SimpleStringLiteral createStringLiteral(String contents) {
  var lexeme = "'${escapeDartString(contents)}'";
  var token = new StringToken(TokenType.STRING, lexeme, null);
  return new SimpleStringLiteral(token, contents);
}


/**
 * Parse and extract top-level directives from [code].
 *
 * Adds emitted error/warning messages to [messages], if [messages] is
 * supplied.
 */
DartCodeInfo parseDartCode(Path path, String code, Messages messages) {
  var unit = parseCompilationUnit(code, path: path, messages: messages);

  // Extract some information from the compilation unit.
  String libraryName, partName;
  var directives = [];
  int directiveEnd = 0;
  for (var directive in unit.directives) {
    if (directive is LibraryDirective) {
      libraryName = directive.name.name;
    } else if (directive is PartOfDirective) {
      partName = directive.libraryName.name;
    } else {
      // Normalize the library URI.
      var uriNode = getDirectiveUri(directive);
      if (uriNode is! SimpleStringLiteral) {
        String uri = uriNode.accept(new ConstantEvaluator());
        setDirectiveUri(directive, createStringLiteral(uri));
      }
      directives.add(directive);
    }
  }

  return new DartCodeInfo(libraryName, partName, directives, code,
      path.toString(), unit);
}

CompilationUnit parseCompilationUnit(String code, {Path path,
    Messages messages}) {

  var errorListener = new _ErrorCollector();
  var scanner = new StringScanner(null, code, errorListener);
  var token = scanner.tokenize();
  var parser = new Parser(null, errorListener);
  var unit = parser.parseCompilationUnit(token);

  if (path == null || messages == null) return unit;

  // TODO(jmesserly): removed this for now because the analyzer doesn't format
  // messages properly, so you end up with things like "Unexpected token '%s'".
  // This used to convert parser messages into our messages. Enable this
  // once analyzer is fixed.
  if (false) {
    var file = new File.text(path.toString(), code);
    for (var e in errorListener.errors) {
      var span = new FileSpan(file, e.offset, e.offset + e.length);

      var severity = e.errorCode.errorSeverity;
      if (severity == ErrorSeverity.ERROR) {
        messages.error(e.message, span, file: path);
      } else {
        assert(severity == ErrorSeverity.WARNING);
        messages.warning(e.message, span, file: path);
      }
    }
  }

  return unit;
}

class _ErrorCollector extends AnalysisErrorListener {
  final errors = new List<AnalysisError>();
  onError(error) => errors.add(error);
}