// privatelm_rpc_worker.exe — the Windows half of a phone/PC cluster.
//
// Runs llama.cpp's RPC server over this machine's CPU, the same protocol the
// Android ":cluster" process serves. It lives in its own executable because
// ggml_backend_rpc_start_server blocks forever and cannot be stopped in
// process; the app kills this process to stop sharing.
//
// The app polls the JSON status file written by status_writer.cpp, so this
// process never needs a Dart isolate or a method channel. Manual IP / QR
// pairing is the guaranteed path; mDNS is a best-effort convenience.
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "ggml-backend.h"
#include "llama.h"
#include "mdns_advertiser.h"
#include "plm_core.h"
#include "status_writer.h"

namespace {

struct Args {
    std::string host = "0.0.0.0";
    int port = 50052;
    int threads = 0;
    std::string cache_dir;
    std::string status_file;
    std::string id;
    std::string model = "Windows PC";
    std::string advertise_ip;
    DWORD parent_pid = 0;
};

std::string narrow(const std::wstring& text) {
    if (text.empty()) return {};
    const int len = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                        static_cast<int>(text.size()), nullptr, 0,
                                        nullptr, nullptr);
    if (len <= 0) return {};
    std::string out(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                        static_cast<int>(text.size()), out.data(), len, nullptr,
                        nullptr);
    return out;
}

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    const int len = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                        static_cast<int>(text.size()), nullptr, 0);
    if (len <= 0) return {};
    std::wstring out(static_cast<size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        out.data(), len);
    return out;
}

std::string systemError(DWORD code) {
    wchar_t* buffer = nullptr;
    const DWORD len = FormatMessageW(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, 0, reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
    std::string text = len && buffer ? narrow(buffer) : std::string("error");
    if (buffer) LocalFree(buffer);
    while (!text.empty() && (text.back() == '\r' || text.back() == '\n')) {
        text.pop_back();
    }
    return text + " (" + std::to_string(code) + ")";
}

std::string hostName() {
    wchar_t buffer[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
    if (!GetComputerNameW(buffer, &size)) return "Windows PC";
    return narrow(std::wstring(buffer, size));
}

void parseArgs(int argc, char** argv, Args& args) {
    for (int i = 1; i < argc; i++) {
        const std::string flag = argv[i] ? argv[i] : "";
        auto next = [&](const char* name) -> std::string {
            if (i + 1 >= argc || !argv[i + 1]) {
                std::fprintf(stderr, "Missing value for %s\n", name);
                std::exit(2);
            }
            return argv[++i];
        };
        if (flag == "--host") {
            args.host = next("--host");
        } else if (flag == "--port") {
            args.port = std::atoi(next("--port").c_str());
        } else if (flag == "--threads") {
            args.threads = std::atoi(next("--threads").c_str());
        } else if (flag == "--cache-dir") {
            args.cache_dir = next("--cache-dir");
        } else if (flag == "--status-file") {
            args.status_file = next("--status-file");
        } else if (flag == "--id") {
            args.id = next("--id");
        } else if (flag == "--model") {
            args.model = next("--model");
        } else if (flag == "--advertise-ip") {
            args.advertise_ip = next("--advertise-ip");
        } else if (flag == "--parent-pid") {
            args.parent_pid =
                static_cast<DWORD>(std::strtoul(next("--parent-pid").c_str(), nullptr, 10));
        }
    }
}

/// Detached children have no stdio handles. Point them at NUL so llama.cpp's
/// printf/fprintf calls never hit an invalid handle.
void silenceMissingStdio() {
    const HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out == nullptr || out == INVALID_HANDLE_VALUE) {
        std::freopen("NUL", "w", stdout);
    }
    const HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    if (err == nullptr || err == INVALID_HANDLE_VALUE) {
        std::freopen("NUL", "w", stderr);
    }
}

void stderrSink(ggml_log_level /* level */, const char* text) {
    if (!text) return;
    std::fputs(text, stderr);
}

/// Binds the port once before handing it to ggml. ggml_backend_rpc_start_server
/// returns silently on a bind failure, so this is how we surface the OS error
/// (firewall, another worker, port reserved).
bool canBind(const std::string& host, int port, std::string& error) {
    WSADATA wsa = {};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        error = "Winsock could not start";
        return false;
    }

    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) {
        error = "Could not create a socket: " + systemError(WSAGetLastError());
        WSACleanup();
        return false;
    }

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<u_short>(port));
    if (host.empty() || host == "0.0.0.0") {
        address.sin_addr.s_addr = INADDR_ANY;
    } else if (InetPtonA(AF_INET, host.c_str(), &address.sin_addr) != 1) {
        error = "Invalid worker host: " + host;
        closesocket(socket);
        WSACleanup();
        return false;
    }

    if (bind(socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) ==
        SOCKET_ERROR) {
        error = "Port " + std::to_string(port) + " is not available: " +
                systemError(WSAGetLastError());
        closesocket(socket);
        WSACleanup();
        return false;
    }
    if (listen(socket, SOMAXCONN) == SOCKET_ERROR) {
        error = "Could not listen on port " + std::to_string(port) + ": " +
                systemError(WSAGetLastError());
        closesocket(socket);
        WSACleanup();
        return false;
    }

    closesocket(socket);
    WSACleanup();
    return true;
}

BOOL WINAPI ctrlHandler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT ||
        type == CTRL_CLOSE_EVENT || type == CTRL_SHUTDOWN_EVENT) {
        ExitProcess(0);
    }
    return FALSE;
}

worker::Status makeStatus(const Args& args, long long ram_mb, double bandwidth) {
    worker::Status status;
    status.state = "error";
    status.id = args.id;
    status.ram_mb = ram_mb;
    status.bandwidth = bandwidth;
    return status;
}

} // namespace

int main(int argc, char** argv) {
    silenceMissingStdio();

    Args args;
    parseArgs(argc, argv, args);
    if (args.status_file.empty()) {
        std::fprintf(stderr, "--status-file is required\n");
        return 2;
    }

    if (args.threads <= 0) {
        const unsigned int cores = std::thread::hardware_concurrency();
        args.threads = static_cast<int>(std::clamp(cores == 0 ? 4u : cores, 2u, 16u));
    }

    // Keep the same peer/buffer/error scraping the Android worker uses.
    plm::setLogSink(stderrSink);
    plm::installLogHandler();

    const long long ram_mb = worker::availableRamMb();
    const double bandwidth = plm::memBandwidth(args.threads);

    worker::Status status = makeStatus(args, ram_mb, bandwidth);
    status.state = "starting";
    worker::writeStatusFile(args.status_file, status);

    // Every early exit leaves the reason where the app can read it, so the
    // UI can show the OS message instead of "did not start".
    auto fail = [&](const std::string& message, int code) {
        status.state = "error";
        status.error = message;
        worker::writeStatusFile(args.status_file, status);
        return code;
    };

    ggml_backend_dev_t cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (!cpu) {
        return fail("No CPU backend could be loaded", 2);
    }

    ggml_backend_reg_t rpc = ggml_backend_reg_by_name("RPC");
    if (!rpc) {
        return fail("This build has no cluster (RPC) support", 2);
    }
    using start_server_fn = void (*)(const char*, const char*, size_t, size_t,
                                     ggml_backend_dev_t*);
    auto start_server = reinterpret_cast<start_server_fn>(
        ggml_backend_reg_get_proc_address(rpc, "ggml_backend_rpc_start_server"));
    if (!start_server) {
        return fail("RPC backend is missing its server", 2);
    }

    std::string bind_error;
    if (!canBind(args.host, args.port, bind_error)) {
        return fail(bind_error +
                        ". Allow PrivateLM through Windows Firewall, close other "
                        "PrivateLM windows, or choose another port.",
                    2);
    }

    const std::string endpoint = args.host + ":" + std::to_string(args.port);
    const std::string model = args.model.empty() ? hostName() : args.model;
    worker::startMdnsAdvertiser("PrivateLM " + model, hostName(), args.port,
                                ram_mb, bandwidth, args.id, model,
                                args.advertise_ip);

    // The parent (the Flutter app) owns this process: when it exits, close the
    // RPC server with it. A Job Object in the app is the primary mechanism;
    // this watchdog also covers launches that did not create one.
    if (args.parent_pid != 0) {
        HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE, args.parent_pid);
        if (!parent) {
            return fail("The app that started this worker is no longer running", 2);
        }
        std::thread([parent] {
            WaitForSingleObject(parent, INFINITE);
            CloseHandle(parent);
            ExitProcess(0);
        }).detach();
    }
    SetConsoleCtrlHandler(ctrlHandler, TRUE);

    status.state = "running";
    worker::writeStatusFile(args.status_file, status);

    std::atomic<bool> running{true};
    std::thread status_thread([&]() {
        worker::Status live = status;
        while (running) {
            live.peer = plm::workerPeer();
            live.held_mb = worker::residentMb();
            worker::writeStatusFile(args.status_file, live);
            std::this_thread::sleep_for(std::chrono::seconds(1));
        }
    });

    // Blocks for as long as a master is served; only returns when the server
    // could not start (ggml reports that on stderr and returns).
    start_server(endpoint.c_str(),
                 args.cache_dir.empty() ? nullptr : args.cache_dir.c_str(),
                 static_cast<size_t>(std::max(1, args.threads)), 1, &cpu);

    running = false;
    if (status_thread.joinable()) status_thread.join();
    worker::stopMdnsAdvertiser();

    status.state = "error";
    status.error = "The RPC server stopped (port " + std::to_string(args.port) +
                   " may already be in use)";
    worker::writeStatusFile(args.status_file, status);
    return 1;
}
