#include <d3d11.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <stdlib.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Flutter 3.47's Windows compositor passes a *sized* GL internal format
// (GL_RGBA8 and friends) to glTexImage2D while running on an OpenGL ES 2.0
// context. ANGLE on D3D11 feature level 10_0 only offers ES 2.0, so the call
// fails with GL_INVALID_VALUE and the engine never gets a complete
// framebuffer: the window stays black.
//
// The upstream fix (flutter/flutter#192917, issue #191978) is on master only
// and is not in any 3.47.x release. ANGLE can still create an ES 3.0 context
// on FL10_0 when this override is enabled, and the compositor's ES 3 call then
// succeeds.
//
// Only apply it when the GPU cannot do FL11_0: newer hardware gets ES 3.0 from
// ANGLE anyway and keeps the default path. An override the user set by hand
// always wins.
void EnableAngleEs3OnOldGpus() {
  // A one-byte buffer is enough: a non-empty value returns the required size,
  // an unset one returns 0.
  char existing[1] = {};
  if (::GetEnvironmentVariableA("ANGLE_FEATURE_OVERRIDES_ENABLED", existing,
                                ARRAYSIZE(existing)) > 0) {
    return;
  }

  ID3D11Device* device = nullptr;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_10_0;
  const HRESULT hr = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
      D3D11_SDK_VERSION, &device, &level, nullptr);
  const bool has_feature_level_11 =
      SUCCEEDED(hr) && level >= D3D_FEATURE_LEVEL_11_0;
  if (device != nullptr) device->Release();
  if (has_feature_level_11) return;

  _putenv_s("ANGLE_FEATURE_OVERRIDES_ENABLED", "allowES3OnFL100");
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Must run before the Flutter engine (and ANGLE) starts.
  EnableAngleEs3OnOldGpus();

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Set the minimum size before Create so the constraint also applies to the
  // initial WM_GETMINMAXINFO sent during window creation.
  window.SetMinimumSize(Win32Window::Size(900, 600));
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 800);
  if (!window.Create(L"PrivateLM", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
