import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/src/chat_templates.dart';

/// Parity tests for the Windows prompt formatter. The expected strings come
/// from the Kotlin ChatTemplates.kt implementation that Android uses.
void main() {
  final manager = ChatTemplateManager.instance;

  test('chatml wraps roles and starts the assistant turn', () {
    final out = manager.formatMessages(
      const [
        TemplateChatMessage('system', 'sys'),
        TemplateChatMessage('user', 'hi'),
      ],
      templateName: 'chatml',
    );

    expect(
      out,
      '<|im_start|>system\nsys<|im_end|>\n'
      '<|im_start|>user\nhi<|im_end|>\n'
      '<|im_start|>assistant\n',
    );
  });

  test('llama3 uses header blocks and trims message content', () {
    final out = manager.formatMessages(
      const [TemplateChatMessage('user', '  hi  ')],
      templateName: 'llama3',
    );

    expect(
      out,
      '<|begin_of_text|>'
      '<|start_header_id|>user<|end_header_id|>\n\nhi<|eot_id|>'
      '<|start_header_id|>assistant<|end_header_id|>\n\n',
    );
  });

  test('gemma2 prepends the system prompt to the first user turn', () {
    final out = manager.formatMessages(
      const [
        TemplateChatMessage('system', 'sys'),
        TemplateChatMessage('user', 'hi'),
      ],
      templateName: 'gemma2',
    );

    expect(
      out,
      '<bos><start_of_turn>user\nsys\n\nhi<end_of_turn>\n'
      '<start_of_turn>model\n',
    );
  });

  test('alpaca keeps the literal backslash-n sequences from Kotlin', () {
    final out = manager.formatMessages(
      const [TemplateChatMessage('user', 'hi')],
      templateName: 'alpaca',
    );

    expect(out, startsWith('Below is an instruction'));
    expect(out, contains(r'### Instruction:\n'));
    expect(out, contains('hi'), reason: 'message content is not escaped');
  });

  test('qwq strips thinking blocks from assistant history', () {
    final out = manager.formatMessages(
      const [
        TemplateChatMessage('user', 'q'),
        TemplateChatMessage('assistant', '<think>hidden</think> answer'),
      ],
      templateName: 'qwq',
    );

    expect(out, isNot(contains('hidden')));
    expect(out, contains('answer'));
    expect(out, endsWith('<|im_start|>assistant\n'));
  });

  test('detectTemplate recognises the same families as Android', () {
    expect(manager.detectTemplate(r'C:\models\gemma-4-9b.gguf').name, 'gemma4');
    expect(manager.detectTemplate(r'C:\models\gemma-3-4b.gguf').name, 'gemma3');
    expect(manager.detectTemplate(r'C:\models\Qwen2.5-7B.gguf').name, 'chatml');
    expect(manager.detectTemplate(r'C:\models\unknown.gguf').name, 'chatml');
    expect(
      manager.detectTemplate(r'C:\models\DeepSeek-R1-Q4.gguf').name,
      'deepseek-r1',
    );
  });

  test('custom templates are case-insensitive and override built-ins', () {
    manager.registerCustomTemplate('MyFormat', 'U:{user}');
    addTearDown(() => manager.unregisterCustomTemplate('MyFormat'));

    expect(
      manager.formatMessages(
        const [TemplateChatMessage('user', 'hi')],
        templateName: 'myformat',
      ),
      'U:hi',
    );
    expect(manager.getSupportedTemplates(), contains('myformat'));
  });
}
