// Per-OS pieces of privatelm_rpc_worker.
//
// main_common.cpp owns the argument contract, the status file and the RPC
// server setup; everything that touches winsock/winsvc versus POSIX sockets,
// signals and /proc lives behind this interface. Windows implements it in
// main_win.cpp, Linux in main_posix.cpp.
#pragma once

#include <string>

namespace worker {

/// Runs the worker. Called by each platform's main(). Returns the exit code.
int runWorker(int argc, char** argv);

/// An OS error message with its numeric code, for display in the app.
std::string systemError(int code);

/// This machine's display name (shown in a master's worker list).
std::string hostName();

/// Points stdio at the null device when the parent gave this process no
/// handles (detached start). A no-op on POSIX.
void silenceMissingStdio();

/// Binds and listens once to prove the port works, then releases it. ggml's
/// server returns silently on a bind failure, so this is the only way to
/// report "port already in use" to the app.
bool canBind(const std::string& host, int port, std::string& error);

/// Sentence appended to a bind failure naming this platform's firewall UI.
std::string bindHint();

/// Installs the shutdown handlers (console ctrl on Windows, SIGINT/SIGTERM on
/// POSIX) so the worker exits instead of lingering.
void installShutdownHandlers();

/// Exits this process when `parent_pid` dies. Returns false (with `error` set)
/// when the parent is already gone.
bool watchParent(unsigned long long parent_pid, std::string& error);

} // namespace worker
