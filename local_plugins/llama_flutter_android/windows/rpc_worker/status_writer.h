// Status file shared between privatelm_rpc_worker.exe and the Flutter app.
//
// The worker can't talk to the app over Dart (it blocks forever inside
// ggml_backend_rpc_start_server), so the app polls this JSON file, exactly
// like the Android ClusterWorkerService does for its ":cluster" process.
#pragma once

#include <string>

namespace worker {

struct Status {
    /// starting, running, error or stopped.
    std::string state = "starting";
    /// Address of the master currently using this worker, empty when idle.
    std::string peer;
    /// Why the worker stopped, when state is "error".
    std::string error;
    /// Stable worker ID, so a master can find this PC after an IP change.
    std::string id;

    long long ram_mb = 0;
    long long held_mb = 0;
    double bandwidth = 0.0;
};

/// Writes `status` to `path` atomically (temp file + replace), so a reader
/// never sees a half-written JSON document. Paths are UTF-8.
void writeStatusFile(const std::string& path, const Status& status);

/// This process's resident memory (working set), in MiB.
long long residentMb();

/// Currently free physical RAM, in MiB.
long long availableRamMb();

} // namespace worker
