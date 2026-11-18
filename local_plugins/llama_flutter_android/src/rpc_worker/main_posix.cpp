// Linux entry point and OS hooks for privatelm_rpc_worker.
//
// The worker is a plain POSIX process: it binds with BSD sockets, exits on
// SIGINT/SIGTERM, and dies with the app through PR_SET_PDEATHSIG (plus a
// getppid() re-check for the race where the app exits between fork and prctl).
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "platform.h"

namespace {

void onSignal(int /* signum */) {
    // ggml_backend_rpc_start_server has no stop path; leaving immediately is
    // the only way out and the status file goes stale, which the app reads as
    // "stopped".
    _exit(0);
}

} // namespace

std::string worker::systemError(int code) {
    return std::string(std::strerror(code)) + " (" + std::to_string(code) + ")";
}

std::string worker::hostName() {
    char buffer[256] = {};
    if (::gethostname(buffer, sizeof(buffer) - 1) != 0 || buffer[0] == '\0') {
        return "Linux PC";
    }
    return buffer;
}

void worker::silenceMissingStdio() {
    // A detached child keeps whatever descriptors it was given; writing to a
    // closed one returns EBADF instead of crashing, so there is nothing to
    // redirect.
}

bool worker::canBind(const std::string& host, int port, std::string& error) {
    const int fd = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        error = "Could not create a socket: " + systemError(errno);
        return false;
    }

    // SO_REUSEADDR so a worker restarted right after a stop is not blocked by
    // the previous socket's TIME_WAIT.
    const int one = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<uint16_t>(port));
    if (host.empty() || host == "0.0.0.0") {
        address.sin_addr.s_addr = INADDR_ANY;
    } else if (::inet_pton(AF_INET, host.c_str(), &address.sin_addr) != 1) {
        error = "Invalid worker host: " + host;
        ::close(fd);
        return false;
    }

    if (::bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        error = "Port " + std::to_string(port) + " is not available: " +
                systemError(errno);
        ::close(fd);
        return false;
    }
    if (::listen(fd, SOMAXCONN) != 0) {
        error = "Could not listen on port " + std::to_string(port) + ": " +
                systemError(errno);
        ::close(fd);
        return false;
    }

    ::close(fd);
    return true;
}

std::string worker::bindHint() {
    return "Allow the port through your firewall (for example "
           "`sudo ufw allow 50052/tcp` or "
           "`sudo firewall-cmd --add-port=50052/tcp`), close other PrivateLM "
           "windows, or choose another port.";
}

void worker::installShutdownHandlers() {
    struct sigaction action = {};
    action.sa_handler = onSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    ::sigaction(SIGINT, &action, nullptr);
    ::sigaction(SIGTERM, &action, nullptr);
    ::sigaction(SIGHUP, &action, nullptr);
    // The app may close stdin/stdout; a write from llama.cpp must not kill us.
    ::signal(SIGPIPE, SIG_IGN);
}

bool worker::watchParent(unsigned long long parent_pid, std::string& error) {
    const pid_t parent = static_cast<pid_t>(parent_pid);
    if (parent <= 0) return true;
    // kill(parent, 0) is the cheapest liveness probe for a process we do not
    // own. EPERM still means it exists; only ESRCH means it is gone.
    if (::kill(parent, 0) != 0 && errno == ESRCH) {
        error = "The app that started this worker is no longer running";
        return false;
    }
    // PR_SET_PDEATHSIG is deliberately not used: Dart starts detached children
    // from a helper thread, so the signal tracks that thread (not the app) and
    // can kill a healthy worker. Polling the app's pid is stable across a
    // reparent to init, which is what `ProcessStartMode.detached` does.
    std::thread([parent] {
        for (;;) {
            if (::kill(parent, 0) != 0 && errno == ESRCH) _exit(0);
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
    }).detach();
    return true;
}

int main(int argc, char** argv) {
    return worker::runWorker(argc, argv);
}
