// Shared prompt builders for the llama engine.
//
// These were extracted from inference_android.dart so the Windows and mobile
// paths cannot drift. The primary path is still generateChat(), where Android
// formats prompts in Kotlin (ChatTemplates.kt) and Windows formats them in Dart
// (llama_flutter_android's chat_templates.dart); these builders produce the
// fallback prompt used when generateChat() is unavailable.
library;

import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Builds the message list handed to `LlamaController.generateChat`.
List<ChatMessage> buildChatMessages(
  String prompt,
  List<Map<String, String>>? history,
  String systemPrompt, {
  String? imagePath,
}) {
  final messages = <ChatMessage>[
    ChatMessage(role: 'system', content: systemPrompt),
  ];

  if (history != null && history.isNotEmpty) {
    var recent = history.length > 16
        ? history.sublist(history.length - 16)
        : List<Map<String, String>>.of(history);
    if (recent.isNotEmpty &&
        recent.last['role'] == 'user' &&
        recent.last['content'] == prompt) {
      recent = recent.sublist(0, recent.length - 1);
    }
    for (final message in recent) {
      messages.add(ChatMessage(
        role: message['role'] ?? 'user',
        content: message['content'] ?? '',
      ));
    }
  }

  messages.add(ChatMessage(
    role: 'user',
    content: prompt,
    imagePath: imagePath,
  ));
  return messages;
}

/// Fallback prompt builder when `generateChat()` is unavailable, with a
/// simple name-based template choice.
String buildPrompt(
  String userMessage,
  List<Map<String, String>>? history,
  String systemPrompt,
  String modelName,
) {
  final name = modelName.toLowerCase();
  if (name.contains('gemma')) {
    return buildGemma(userMessage, history, systemPrompt);
  }
  if (name.contains('llama-3') || name.contains('llama3')) {
    return buildLlama3(userMessage, history, systemPrompt);
  }
  return buildChatML(userMessage, history, systemPrompt);
}

String buildChatML(
  String message,
  List<Map<String, String>>? history,
  String systemPrompt,
) {
  final buffer = StringBuffer()
    ..write('<|im_start|>system\n$systemPrompt<|im_end|>\n');
  if (history != null) {
    final recent =
        history.length > 8 ? history.sublist(history.length - 8) : history;
    for (final entry in recent) {
      final content = entry['content'] ?? '';
      final truncated =
          content.length > 300 ? '${content.substring(0, 300)}...' : content;
      buffer.write(
          '<|im_start|>${entry['role'] ?? 'user'}\n$truncated<|im_end|>\n');
    }
  }
  buffer.write('<|im_start|>user\n$message<|im_end|>\n<|im_start|>assistant\n');
  return buffer.toString();
}

String buildGemma(
  String message,
  List<Map<String, String>>? history,
  String systemPrompt,
) {
  final buffer = StringBuffer()
    ..write('<start_of_turn>user\n$systemPrompt<end_of_turn>\n'
        '<start_of_turn>model\nUnderstood.<end_of_turn>\n');
  if (history != null) {
    final recent =
        history.length > 4 ? history.sublist(history.length - 4) : history;
    for (final entry in recent) {
      final role = entry['role'] == 'assistant' ? 'model' : 'user';
      final content = entry['content'] ?? '';
      final truncated =
          content.length > 300 ? '${content.substring(0, 300)}...' : content;
      buffer.write('<start_of_turn>$role\n$truncated<end_of_turn>\n');
    }
  }
  buffer.write('<start_of_turn>user\n$message<end_of_turn>\n'
      '<start_of_turn>model\n');
  return buffer.toString();
}

String buildLlama3(
  String message,
  List<Map<String, String>>? history,
  String systemPrompt,
) {
  final buffer = StringBuffer()
    ..write('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
        '$systemPrompt<|eot_id|>');
  if (history != null) {
    final recent =
        history.length > 4 ? history.sublist(history.length - 4) : history;
    for (final entry in recent) {
      final content = entry['content'] ?? '';
      final truncated =
          content.length > 300 ? '${content.substring(0, 300)}...' : content;
      buffer.write('<|start_header_id|>${entry['role'] ?? 'user'}'
          '<|end_header_id|>\n\n$truncated<|eot_id|>');
    }
  }
  buffer.write('<|start_header_id|>user<|end_header_id|>\n\n$message<|eot_id|>'
      '<|start_header_id|>assistant<|end_header_id|>\n\n');
  return buffer.toString();
}
