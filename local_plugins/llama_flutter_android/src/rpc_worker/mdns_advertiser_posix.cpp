// Linux mDNS advertising, delegated to Avahi.
//
// Windows has DnsServiceRegister in the OS. Linux has no equivalent in the
// base system, so this uses `avahi-publish-service` (present wherever the
// avahi daemon is) and does nothing when it is missing. Discovery is a
// convenience: manual IP, QR codes and (later) Tailscale always work.
#include "mdns_advertiser.h"

#include <signal.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

pid_t g_pid = -1;

/// Absolute path of `name` on PATH, or empty.
std::string findOnPath(const std::string& name) {
    const char* path = std::getenv("PATH");
    if (!path) return {};
    const std::string text(path);
    size_t start = 0;
    while (start <= text.size()) {
        const size_t end = text.find(':', start);
        const std::string dir =
            text.substr(start, end == std::string::npos ? end : end - start);
        if (!dir.empty()) {
            const std::string candidate = dir + "/" + name;
            if (::access(candidate.c_str(), X_OK) == 0) return candidate;
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return {};
}

} // namespace

bool worker::startMdnsAdvertiser(const std::string& instance_name,
                                 const std::string& host_name, int port,
                                 long long ram_mb, double bandwidth,
                                 const std::string& id,
                                 const std::string& model,
                                 const std::string& ipv4) {
    // Avahi publishes every address of this host on its own; host_name and
    // ipv4 only matter for the Windows DNS-SD API.
    (void)host_name;
    (void)ipv4;
    if (g_pid > 0) return true;

    const std::string tool = findOnPath("avahi-publish-service");
    if (tool.empty()) return false;

    char bandwidth_text[32];
    std::snprintf(bandwidth_text, sizeof(bandwidth_text), "%.1f", bandwidth);

    // `-f` keeps the child quiet when the daemon is not running; discovery is
    // best effort and manual IP pairing always works.
    std::vector<std::string> args = {
        tool,
        "-f",
        instance_name,
        "_privatelm._tcp",
        std::to_string(port),
        "ram=" + std::to_string(ram_mb),
        "bw=" + std::string(bandwidth_text),
        "model=" + model,
        "v=rpc7",
        "id=" + id,
    };

    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (auto& arg : args) argv.push_back(arg.data());
    argv.push_back(nullptr);

    const pid_t self = ::getpid();
    const pid_t pid = ::fork();
    if (pid < 0) return false;
    if (pid == 0) {
        // The publisher must not outlive the worker: a killed worker exits
        // through _exit() and never reaches stopMdnsAdvertiser(), which would
        // leave a dead worker advertised on the LAN. The fork happens on the
        // worker's main thread, so PDEATHSIG tracks the process here.
        ::prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (::getppid() != self) _exit(0);
        // Detach from the worker's console: Avahi's output is noise.
        ::freopen("/dev/null", "w", stdout);
        ::freopen("/dev/null", "w", stderr);
        ::execv(argv[0], argv.data());
        _exit(127);
    }

    g_pid = pid;
    return true;
}

void worker::stopMdnsAdvertiser() {
    if (g_pid <= 0) return;
    ::kill(g_pid, SIGTERM);
    // Reap without blocking: the publisher is not on the exit path.
    ::waitpid(g_pid, nullptr, 0);
    g_pid = -1;
}
