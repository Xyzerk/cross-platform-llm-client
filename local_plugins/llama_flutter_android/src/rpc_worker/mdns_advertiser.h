// Best-effort DNS-SD advertisement for the Windows worker (Phase 4b).
//
// The master can always add a worker by IP or QR; this only makes the PC show
// up in "Find nearby" the way Android/iOS workers do. Windows' DNS-SD service
// is used (DnsServiceRegister), so no extra mDNS responder is shipped.
#pragma once

#include <string>

namespace worker {

/// Registers "<instance>._privatelm._tcp.local" with the TXT keys Android and
/// iOS advertise (ram, bw, model, v=rpc7, id). Returns false when the OS
/// service is unavailable; the worker still runs and manual IP keeps working.
bool startMdnsAdvertiser(const std::string& instance_name,
                         const std::string& host_name, int port,
                         long long ram_mb, double bandwidth,
                         const std::string& id, const std::string& model,
                         const std::string& ipv4);

/// Deregisters the advertisement. Registration is also tied to this process,
/// so a crash cleans up automatically.
void stopMdnsAdvertiser();

} // namespace worker
