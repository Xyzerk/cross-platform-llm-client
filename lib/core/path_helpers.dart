// File-name helpers for model paths.
//
// Models move between devices: a path saved on Android
// (`/data/.../model.gguf`) or on Windows (`C:\models\model.gguf`) can reach
// either build, and users type paths by hand with either separator.
// `package:path` is context-aware and would leave a Windows-style path intact
// on Linux, so split on both separators here instead.
library;

/// The last segment of [path]: "model.gguf" for either separator style.
String modelFileName(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

/// The lowercased extension including the dot (".gguf"), or "" when there is
/// none. A leading dot (".gitignore") is a name, not an extension.
String modelExtension(String path) {
  final name = modelFileName(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

/// The file name without its extension: "Llama-3.2-3B" for
/// `C:\models\Llama-3.2-3B.GGUF`.
String modelDisplayName(String path) {
  final name = modelFileName(path);
  final extension = modelExtension(name);
  return extension.isEmpty ? name : name.substring(0, name.length - extension.length);
}
