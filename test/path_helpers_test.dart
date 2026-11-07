import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/core/path_helpers.dart';

void main() {
  group('modelFileName', () {
    test('handles Windows paths', () {
      expect(modelFileName(r'C:\Users\me\Models\Llama-3.2-3B.gguf'),
          'Llama-3.2-3B.gguf');
    });

    test('handles POSIX paths', () {
      expect(modelFileName('/data/user/0/app/files/model.gguf'), 'model.gguf');
    });

    test('handles forward slashes in a Windows path', () {
      expect(modelFileName('C:/models/model.gguf'), 'model.gguf');
    });

    test('returns a bare file name unchanged', () {
      expect(modelFileName('model.gguf'), 'model.gguf');
    });

    test('keeps trailing separators out of the name', () {
      expect(modelFileName('C:\\models\\'), '');
    });
  });

  group('modelExtension', () {
    test('is lowercased and includes the dot', () {
      expect(modelExtension(r'C:\models\Llama.GGUF'), '.gguf');
    });

    test('is empty without an extension', () {
      expect(modelExtension('/models/llama'), '');
    });

    test('does not treat a leading dot as an extension', () {
      expect(modelExtension('/models/.gguf'), '');
    });
  });

  group('modelDisplayName', () {
    test('strips the extension from either separator style', () {
      expect(modelDisplayName(r'C:\models\Llama-3.2-3B.gguf'), 'Llama-3.2-3B');
      expect(modelDisplayName('/models/Llama-3.2-3B.gguf'), 'Llama-3.2-3B');
    });

    test('leaves a name without an extension alone', () {
      expect(modelDisplayName('/models/llama'), 'llama');
    });
  });
}
