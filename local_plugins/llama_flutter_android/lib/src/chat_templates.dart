// Chat prompt templates shared by the Windows FFI host.
//
// This is a faithful Dart port of
// android/src/main/kotlin/com/write4me/llama_flutter_android/ChatTemplates.kt.
// Android keeps using the Kotlin implementation through JNI/Pigeon; Windows
// formats prompts here and then calls plm_generate, so both platforms produce
// byte-identical prompts for the same messages. Keep the two files in sync —
// including the literal "\n" sequences in the Alpaca/Vicuna/Phi templates,
// which are a quirk of the Kotlin source and are reproduced bug-for-bug.
library;

/// Internal chat message for template formatting.
class TemplateChatMessage {
  const TemplateChatMessage(this.role, this.content);

  /// `system`, `user`, or `assistant`.
  final String role;
  final String content;
}

/// Interface for chat template formatters.
abstract class ChatTemplate {
  String get name;
  String format(List<TemplateChatMessage> messages);
}

/// ChatML format used by Qwen 2/2.5, Command-R, and others.
class ChatMLTemplate extends ChatTemplate {
  @override
  String get name => 'chatml';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    for (final message in messages) {
      builder.write('<|im_start|>${message.role}\n');
      builder.write('${message.content}<|im_end|>\n');
    }
    builder.write('<|im_start|>assistant\n');
    return builder.toString();
  }
}

/// Llama-3/3.1/3.3 format with header-based roles.
class Llama3Template extends ChatTemplate {
  @override
  String get name => 'llama3';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<|begin_of_text|>');
    for (final message in messages) {
      builder.write('<|start_header_id|>${message.role}<|end_header_id|>\n\n');
      builder.write('${message.content.trim()}<|eot_id|>');
    }
    builder.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    return builder.toString();
  }
}

/// Llama-2 format.
class Llama2Template extends ChatTemplate {
  @override
  String get name => 'llama2';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<s>');

    var isFirstUser = true;
    var hasSystem = false;
    var systemMessage = '';

    for (final message in messages) {
      if (message.role == 'system') {
        systemMessage = message.content.trim();
        hasSystem = true;
        break;
      }
    }

    for (final message in messages) {
      switch (message.role) {
        case 'system':
          // Already handled, skip.
          continue;
        case 'user':
          if (!isFirstUser) {
            builder.write('</s><s>');
          }
          builder.write('[INST] ');
          if (isFirstUser && hasSystem) {
            builder.write('<<SYS>>\n');
            builder.write('$systemMessage\n');
            builder.write('<</SYS>>\n\n');
          }
          builder.write('${message.content.trim()} [/INST]');
          isFirstUser = false;
        case 'assistant':
          builder.write(' ${message.content.trim()}');
      }
    }

    return builder.toString();
  }
}

/// Alpaca format.
class AlpacaTemplate extends ChatTemplate {
  @override
  String get name => 'alpaca';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    final systemMessage = _firstContent(messages, 'system') ??
        'Below is an instruction that describes a task. Write a response that '
            'appropriately completes the request.';

    // Bug-for-bug: the Kotlin source writes a literal backslash-n here.
    builder.write('$systemMessage\\n\\n');

    for (final message in messages) {
      switch (message.role) {
        case 'user':
          builder.write('### Instruction:\\n');
          builder.write('${message.content}\\n\\n');
        case 'assistant':
          builder.write('### Response:\\n');
          builder.write('${message.content}\\n\\n');
      }
    }

    builder.write('### Response:\\n');
    return builder.toString();
  }
}

/// Vicuna format.
class VicunaTemplate extends ChatTemplate {
  @override
  String get name => 'vicuna';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    final systemMessage = _firstContent(messages, 'system') ??
        'A chat between a curious user and an artificial intelligence '
            'assistant. The assistant gives helpful, detailed, and polite '
            "answers to the user's questions.";

    // Bug-for-bug: the Kotlin source writes literal backslash-n sequences.
    builder.write('$systemMessage\\n\\n');

    for (final message in messages) {
      switch (message.role) {
        case 'user':
          builder.write('USER: ${message.content}\\n');
        case 'assistant':
          builder.write('ASSISTANT: ${message.content}\\n');
      }
    }

    builder.write('ASSISTANT:');
    return builder.toString();
  }
}

/// Phi-2/Phi-3 format (similar to ChatML but with different tokens).
class PhiTemplate extends ChatTemplate {
  @override
  String get name => 'phi';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    for (final message in messages) {
      switch (message.role) {
        case 'system':
          builder.write('<|system|>\\n${message.content}<|end|>\\n');
        case 'user':
          builder.write('<|user|>\\n${message.content}<|end|>\\n');
        case 'assistant':
          builder.write('<|assistant|>\\n${message.content}<|end|>\\n');
      }
    }
    builder.write('<|assistant|>\\n');
    return builder.toString();
  }
}

/// Gemma 2 format with BOS token and dual termination.
class Gemma2Template extends ChatTemplate {
  @override
  String get name => 'gemma2';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<bos>');

    String? systemContent;

    for (var index = 0; index < messages.length; index++) {
      final message = messages[index];
      switch (message.role) {
        case 'system':
          systemContent = message.content;
          continue;
        case 'user':
          builder.write('<start_of_turn>user\n');
          // Prepend the system prompt to the first user message if present.
          if (systemContent != null && index <= 1) {
            builder.write('$systemContent\n\n');
            systemContent = null;
          }
          builder.write('${message.content}<end_of_turn>\n');
        case 'assistant':
          builder.write('<start_of_turn>model\n');
          builder.write('${message.content}<end_of_turn>');
          // Gemma 2 dual termination (except the last message).
          if (index < messages.length - 1) {
            builder.write('<eos>');
          }
          builder.write('\n');
      }
    }

    builder.write('<start_of_turn>model\n');
    return builder.toString();
  }
}

/// Gemma 3 format (text-only, for GGUF conversions).
class Gemma3Template extends ChatTemplate {
  @override
  String get name => 'gemma3';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<bos>');

    String? systemContent;

    for (final message in messages) {
      switch (message.role) {
        case 'system':
          systemContent = message.content;
          continue;
        case 'user':
          builder.write('<start_of_turn>user\n');
          if (systemContent != null) {
            builder.write('$systemContent\n\n');
            systemContent = null;
          }
          builder.write('${message.content}<end_of_turn>\n');
        case 'assistant':
          builder.write('<start_of_turn>model\n');
          builder.write('${message.content}<end_of_turn>\n');
        // Gemma 3 uses single termination (no <eos>).
      }
    }

    builder.write('<start_of_turn>model\n');
    return builder.toString();
  }
}

/// Gemma 4 format: a real system turn and `<|turn>role … <turn|>` blocks.
/// BOS is added by the tokenizer, not here. Earlier model replies have their
/// `<|channel>…<channel|>` thinking removed.
class Gemma4Template extends ChatTemplate {
  @override
  String get name => 'gemma4';

  String _stripThinking(String text) {
    final out = StringBuffer();
    var rest = text;
    while (true) {
      final start = rest.indexOf('<|channel>');
      if (start < 0) {
        out.write(rest);
        break;
      }
      out.write(rest.substring(0, start));
      final end = rest.indexOf('<channel|>', start);
      if (end < 0) break;
      rest = rest.substring(end + '<channel|>'.length);
    }
    return out.toString().trim();
  }

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    for (final message in messages) {
      switch (message.role) {
        case 'system':
          builder
            ..write('<|turn>system\n')
            ..write(message.content.trim())
            ..write('<turn|>\n');
        case 'user':
          builder
            ..write('<|turn>user\n')
            ..write(message.content.trim())
            ..write('<turn|>\n');
        case 'assistant':
          builder
            ..write('<|turn>model\n')
            ..write(_stripThinking(message.content))
            ..write('<turn|>\n');
      }
    }
    builder.write('<|turn>model\n');
    return builder.toString();
  }
}

/// QwQ-32B reasoning model format. Uses ChatML but strips thinking history.
class QwQTemplate extends ChatTemplate {
  @override
  String get name => 'qwq';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    for (final message in messages) {
      final content = message.role == 'assistant'
          ? _stripReasoningBlocks(message.content)
          : message.content;

      if (content.trim().isNotEmpty || message.role != 'assistant') {
        builder.write('<|im_start|>${message.role}\n');
        builder.write('$content<|im_end|>\n');
      }
    }
    builder.write('<|im_start|>assistant\n');
    return builder.toString();
  }

  String _stripReasoningBlocks(String content) {
    return content
        .replaceAll(
          RegExp('<think>.*?</think>', dotAll: true, multiLine: true),
          '',
        )
        .trim();
  }
}

/// Mistral/Mixtral instruction format (v0.1, v0.2, v0.3).
class MistralTemplate extends ChatTemplate {
  @override
  String get name => 'mistral';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<s>');

    var isFirst = true;
    final systemMessage = _firstContent(messages, 'system')?.trim();

    for (final message in messages) {
      switch (message.role) {
        case 'system':
          continue; // Already handled.
        case 'user':
          if (!isFirst) {
            builder.write('</s>');
          }
          builder.write('[INST] ');
          if (isFirst && systemMessage != null) {
            builder.write('$systemMessage\n\n');
          }
          builder.write('${message.content.trim()} [/INST]');
          isFirst = false;
        case 'assistant':
          builder.write(message.content.trim());
      }
    }

    return builder.toString();
  }
}

/// Moonshot format (Moonlight, Kimi).
class MoonshotTemplate extends ChatTemplate {
  @override
  String get name => 'moonshot';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    if (messages.isEmpty || messages.first.role != 'system') {
      builder.write('<|im_system|>system<|im_middle|>You are a helpful '
          'assistant provided by Moonshot-AI.<|im_end|>');
    }
    for (final message in messages) {
      final tag = switch (message.role) {
        'system' => '<|im_system|>',
        'assistant' => '<|im_assistant|>',
        _ => '<|im_user|>',
      };
      builder.write(
          '$tag${message.role}<|im_middle|>${message.content}<|im_end|>');
    }
    builder.write('<|im_assistant|>assistant<|im_middle|>');
    return builder.toString();
  }
}

/// DeepSeek Coder v2/v3.1 format.
class DeepSeekCoderTemplate extends ChatTemplate {
  @override
  String get name => 'deepseek-coder';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<｜begin▁of▁sentence｜>');

    final systemMessage = _firstContent(messages, 'system')?.trim();
    if (systemMessage != null) {
      builder.write('$systemMessage ');
    }

    var isFirst = true;
    for (final message in messages) {
      switch (message.role) {
        case 'system':
          continue; // Already handled.
        case 'user':
          if (!isFirst) {
            builder.write('<｜end▁of▁sentence｜>');
          }
          builder.write('User: ${message.content.trim()}\n');
          isFirst = false;
        case 'assistant':
          builder.write('Assistant: ${message.content.trim()}\n');
      }
    }

    builder.write('Assistant: ');
    return builder.toString();
  }
}

/// DeepSeek R1/V3.1 reasoning format (non-thinking mode).
class DeepSeekR1Template extends ChatTemplate {
  @override
  String get name => 'deepseek-r1';

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    builder.write('<｜begin▁of▁sentence｜>');

    final systemMessage = _firstContent(messages, 'system')?.trim();
    if (systemMessage != null) {
      builder.write(systemMessage);
    }

    for (final message in messages) {
      switch (message.role) {
        case 'system':
          continue; // Already handled.
        case 'user':
          builder.write('<｜User｜>${message.content.trim()}');
        case 'assistant':
          builder.write('<｜Assistant｜></think>${message.content.trim()}');
      }
    }

    builder.write('<｜Assistant｜></think>');
    return builder.toString();
  }
}

/// Raw template that uses user-provided string content with placeholders.
/// Supports basic substitution of `{system}`, `{user}`, and `{assistant}`.
class RawTemplate extends ChatTemplate {
  RawTemplate(this._rawName, this._content);

  final String _rawName;
  final String _content;

  @override
  String get name => _rawName;

  @override
  String format(List<TemplateChatMessage> messages) {
    final builder = StringBuffer();
    for (final message in messages) {
      final formatted = switch (message.role) {
        'system' => _content.replaceAll('{system}', message.content),
        'assistant' => _content.replaceAll('{assistant}', message.content),
        _ => _content.replaceAll('{user}', message.content),
      };
      builder.write(formatted);
    }
    return builder.toString();
  }
}

/// Manager for chat templates: selection, detection, and message formatting.
///
/// Mirrors the Kotlin `ChatTemplateManager` object. This host is a singleton
/// with mutable custom-template state, just like the Android one.
class ChatTemplateManager {
  ChatTemplateManager._();

  static final ChatTemplateManager instance = ChatTemplateManager._();

  // Built-in templates (immutable). Several names alias the same formatter,
  // matching the Kotlin registry.
  static final Map<String, ChatTemplate> _builtInTemplates = {
    // ChatML variants.
    'chatml': ChatMLTemplate(),
    'qwen': ChatMLTemplate(),
    'qwen2': ChatMLTemplate(),
    'qwen2.5': ChatMLTemplate(),
    'command-r': ChatMLTemplate(),

    // Llama family.
    'llama3': Llama3Template(),
    'llama-3': Llama3Template(),
    'llama3.1': Llama3Template(),
    'llama3.3': Llama3Template(),
    'llama2': Llama2Template(),
    'llama-2': Llama2Template(),

    // Reasoning models.
    'qwq': QwQTemplate(),
    'qwq-32b': QwQTemplate(),
    'deepseek-r1': DeepSeekR1Template(),
    'deepseek-v3': DeepSeekR1Template(),

    // Mistral family.
    'mistral': MistralTemplate(),
    'mixtral': MistralTemplate(),

    // DeepSeek Coder.
    'deepseek-coder': DeepSeekCoderTemplate(),

    // Moonshot (Moonlight, Kimi).
    'moonshot': MoonshotTemplate(),

    // Other models.
    'alpaca': AlpacaTemplate(),
    'vicuna': VicunaTemplate(),
    'phi': PhiTemplate(),
    'phi-3': PhiTemplate(),

    // Gemma family (separated by version).
    'gemma': Gemma2Template(), // Default to Gemma 2 for legacy.
    'gemma2': Gemma2Template(),
    'gemma-2': Gemma2Template(),
    'gemma3': Gemma3Template(),
    'gemma-3': Gemma3Template(),
    'gemma4': Gemma4Template(),
    'gemma-4': Gemma4Template(),
  };

  // Custom templates (mutable), registered dynamically at runtime.
  final Map<String, RawTemplate> _customTemplates = {};

  /// Registers a custom template with user-provided content.
  ///
  /// Template content should use `{system}`, `{user}`, and `{assistant}`
  /// placeholders. Names are case-insensitive.
  void registerCustomTemplate(String name, String content) {
    _customTemplates[name.toLowerCase()] = RawTemplate(name, content);
  }

  /// Removes a previously registered custom template.
  bool unregisterCustomTemplate(String name) {
    return _customTemplates.remove(name.toLowerCase()) != null;
  }

  /// Returns a template by name, checking custom templates first.
  ChatTemplate? getTemplate(String name) {
    final key = name.toLowerCase();
    return _customTemplates[key] ?? _builtInTemplates[key];
  }

  /// All template names, custom and built-in, sorted.
  List<String> getSupportedTemplates() {
    final all = <String>{..._customTemplates.keys, ..._builtInTemplates.keys};
    return all.toList()..sort();
  }

  /// Whether a template exists (custom or built-in).
  bool hasTemplate(String name) {
    final key = name.toLowerCase();
    return _customTemplates.containsKey(key) ||
        _builtInTemplates.containsKey(key);
  }

  int get customTemplateCount => _customTemplates.length;

  /// Auto-detects a template from the model path.
  ///
  /// The order of these checks matters and matches the Kotlin implementation.
  ChatTemplate detectTemplate(String modelPath) {
    final lowerPath = modelPath.toLowerCase();

    ChatTemplate builtIn(String name) => _builtInTemplates[name]!;

    if (lowerPath.contains('qwq')) return builtIn('qwq');
    if (lowerPath.contains('deepseek-r1') || lowerPath.contains('deepseek_r1')) {
      return builtIn('deepseek-r1');
    }

    if (lowerPath.contains('moonlight') || lowerPath.contains('kimi')) {
      return builtIn('moonshot');
    }

    if (lowerPath.contains('deepseek-coder') ||
        lowerPath.contains('deepseek_coder')) {
      return builtIn('deepseek-coder');
    }
    if (lowerPath.contains('deepseek') &&
        (lowerPath.contains('v3') || lowerPath.contains('v3.1'))) {
      return builtIn('deepseek-r1');
    }

    if (lowerPath.contains('qwen2.5') || lowerPath.contains('qwen2_5')) {
      return builtIn('qwen2.5');
    }
    if (lowerPath.contains('qwen2')) return builtIn('qwen2');
    if (lowerPath.contains('qwen')) return builtIn('qwen');

    if (lowerPath.contains('llama-3') ||
        lowerPath.contains('llama3') ||
        lowerPath.contains('llama_3')) {
      return builtIn('llama3');
    }
    if (lowerPath.contains('llama-2') ||
        lowerPath.contains('llama2') ||
        lowerPath.contains('llama_2')) {
      return builtIn('llama2');
    }

    if (lowerPath.contains('mixtral')) return builtIn('mixtral');
    if (lowerPath.contains('mistral')) return builtIn('mistral');

    if (lowerPath.contains('command-r') || lowerPath.contains('command_r')) {
      return builtIn('command-r');
    }

    if (lowerPath.contains('phi-3') || lowerPath.contains('phi3')) {
      return builtIn('phi-3');
    }
    if (lowerPath.contains('phi')) return builtIn('phi');

    if (lowerPath.contains('gemma-4') ||
        lowerPath.contains('gemma4') ||
        lowerPath.contains('gemma_4')) {
      return builtIn('gemma4');
    }
    if (lowerPath.contains('gemma-3') ||
        lowerPath.contains('gemma3') ||
        lowerPath.contains('gemma_3')) {
      return builtIn('gemma3');
    }
    if (lowerPath.contains('gemma-2') ||
        lowerPath.contains('gemma2') ||
        lowerPath.contains('gemma_2')) {
      return builtIn('gemma2');
    }
    if (lowerPath.contains('gemma')) return builtIn('gemma2');

    if (lowerPath.contains('alpaca')) return builtIn('alpaca');
    if (lowerPath.contains('vicuna')) return builtIn('vicuna');

    // Default fallback to ChatML (most widely compatible).
    return builtIn('chatml');
  }

  /// Formats messages using an explicit template or auto-detection.
  String formatMessages(
    List<TemplateChatMessage> messages, {
    String? templateName,
    String? modelPath,
  }) {
    final template = templateName != null
        ? (getTemplate(templateName) ?? detectTemplate(modelPath ?? ''))
        : modelPath != null
            ? detectTemplate(modelPath)
            : ChatMLTemplate();

    return template.format(messages);
  }
}

String? _firstContent(List<TemplateChatMessage> messages, String role) {
  for (final message in messages) {
    if (message.role == role) return message.content;
  }
  return null;
}
