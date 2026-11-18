// privatelm_rpc_worker — the desktop half of a PrivateLM cluster.
//
// Runs llama.cpp's RPC server over this machine's CPU, the same protocol the
// Android ":cluster" process serves. It lives in its own executable because
// ggml_backend_rpc_start_server blocks forever and cannot be stopped in
// process; the app kills this process to stop sharing.
//
// The app polls the JSON status file written by status_writer.cpp, so this
// process never needs a Dart isolate or a method channel. Manual IP / QR
// pairing is the guaranteed path; mDNS is a best-effort convenience.
//
// This file is the platform-neutral core; main_win.cpp and main_posix.cpp add
// the sockets, signal handling and parent watchdog.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>

#include "ggml-backend.h"
#include "llama.h"
#include "mdns_advertiser.h"
#include "plm_core.h"
#include "platform.h"
#include "status_writer.h"

namespace {

struct Args {
    std::string host = "0.0.0.0";
    int port = 50052;
    int threads = 0;
    std::string cache_dir;
    std::string status_file;
    std::string id;
    std::string model;
    std::string advertise_ip;
    unsigned long long parent_pid = 0;
};

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
            args.parent_pid = std::strtoull(next("--parent-pid").c_str(), nullptr, 10);
        }
    }
}

void stderrSink(ggml_log_level /* level */, const char* text) {
    if (!text) return;
    std::fputs(text, stderr);
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

int worker::runWorker(int argc, char** argv) {
    worker::silenceMissingStdio();

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
    if (!worker::canBind(args.host, args.port, bind_error)) {
        return fail(bind_error + ". " + worker::bindHint(), 2);
    }

    const std::string endpoint = args.host + ":" + std::to_string(args.port);
    const std::string model = args.model.empty() ? worker::hostName() : args.model;
    worker::startMdnsAdvertiser("PrivateLM " + model, worker::hostName(), args.port,
                                ram_mb, bandwidth, args.id, model,
                                args.advertise_ip);

    // The parent (the Flutter app) owns this process: when it exits, close the
    // RPC server with it. Windows uses a job object plus this watchdog; Linux
    // sets PR_SET_PDEATHSIG and re-checks the parent here.
    if (args.parent_pid != 0) {
        std::string parent_error;
        if (!worker::watchParent(args.parent_pid, parent_error)) {
            return fail(parent_error, 2);
        }
    }
    worker::installShutdownHandlers();

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
