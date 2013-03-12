// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/** End-to-end tests for the [Compiler] API. */
library compiler_test;

import 'dart:async';
import 'package:html5lib/dom.dart';
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';
import 'package:web_ui/src/compiler.dart';
import 'package:web_ui/src/file_system.dart';
import 'package:web_ui/src/options.dart';
import 'testing.dart';
import 'package:web_ui/src/messages.dart';

main() {
  useCompactVMConfiguration();

  var messages;
  setUp(() {
    messages = new Messages.silent();
  });

  Compiler createCompiler(Map files) {
    var options = CompilerOptions.parse([
        '--no-colors', '-o', 'out', 'index.html']);
    var fs = new MockFileSystem(files);
    return new Compiler(fs, options, messages);
  }

  test('recursive dependencies', () {
    var compiler = createCompiler({
      'index.html': '<head>'
                    '<link rel="components" href="foo.html">'
                    '<link rel="components" href="bar.html">'
                    '<body><x-foo></x-foo><x-bar></x-bar>'
                    '<script type="application/dart">main() {}</script>',
      'foo.html': '<head><link rel="components" href="bar.html">'
                  '<body><element name="x-foo" constructor="Foo">'
                  '<template><x-bar>',
      'bar.html': '<head><link rel="components" href="foo.html">'
                  '<body><element name="x-bar" constructor="Boo">'
                  '<template><x-foo>',
    });

    compiler.run().then(expectAsync1((e) {
      MockFileSystem fs = compiler.fileSystem;
      expect(fs.readCount, equals({
        'index.html': 1,
        'foo.html': 1,
        'bar.html': 1
      }), reason: 'Actual:\n  ${fs.readCount}');

      var outputs = compiler.output.map((o) => o.path);
      expect(outputs, equals([
        'out/index.html.dart',
        'out/index.html.dart.map',
        'out/index.html_bootstrap.dart',
        'out/index.html',
        'out/foo.html.dart',
        'out/foo.html.dart.map',
        'out/bar.html.dart',
        'out/bar.html.dart.map'
      ]));
    }));
  });
}

/**
 * Abstraction around file system access to work in a variety of different
 * environments.
 */
class MockFileSystem extends FileSystem {
  final Map _files;
  final Map readCount = {};

  MockFileSystem(this._files);

  Future readTextOrBytes(String filename) => readText(filename);

  Future<String> readText(String path) {
    readCount[path] = readCount.putIfAbsent(path, () => 0) + 1;
    return new Future.immediate(_files[path]);
  }

  // Compiler doesn't call these
  void writeString(String outfile, String text) {}
  Future flush() {}
}
