#include "status_writer.h"

#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

namespace {

std::string jsonEscape(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 8);
    for (const char c : text) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '"': out += "\\\""; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default: out += c;
        }
    }
    return out;
}

bool writeAll(const std::string& path, const std::string& data) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    if (!file) return false;
    file.write(data.data(), static_cast<std::streamsize>(data.size()));
    file.flush();
    return static_cast<bool>(file);
}

/// Reads a /proc file into `text`; false when it cannot be opened.
bool readProc(const char* path, std::string& text) {
    std::ifstream file(path);
    if (!file) return false;
    std::ostringstream buffer;
    buffer << file.rdbuf();
    text = buffer.str();
    return true;
}

/// Value in KiB for a "<key>:<spaces><number> kB" line in /proc.
long long procKb(const std::string& text, const std::string& key) {
    const std::string prefix = key + ":";
    const size_t start = text.find(prefix);
    if (start == std::string::npos) return 0;
    return std::strtoll(text.c_str() + start + prefix.size(), nullptr, 10);
}

} // namespace

void worker::writeStatusFile(const std::string& path, const Status& status) {
    char head[1024];
    std::snprintf(head, sizeof(head),
                  "{\"state\":\"%s\",\"ramMb\":%lld,\"bandwidth\":%.2f,"
                  "\"heldMb\":%lld,\"throttled\":false,"
                  "\"batteryUnrestricted\":true,\"pid\":%ld,\"id\":\"%s\"",
                  jsonEscape(status.state).c_str(), status.ram_mb,
                  status.bandwidth, status.held_mb,
                  static_cast<long>(::getpid()), jsonEscape(status.id).c_str());

    std::string json(head);
    if (!status.peer.empty()) {
        json += ",\"peer\":\"" + jsonEscape(status.peer) + "\"";
    }
    if (!status.error.empty()) {
        json += ",\"error\":\"" + jsonEscape(status.error) + "\"";
    }
    json += "}";

    // Same file in the same directory, then rename: a reader either sees the
    // previous document or the whole new one, never a half-written JSON.
    const std::string temp = path + ".tmp";
    if (!writeAll(temp, json)) return;
    if (std::rename(temp.c_str(), path.c_str()) != 0) {
        std::remove(temp.c_str());
    }
}

long long worker::residentMb() {
    std::string text;
    if (!readProc("/proc/self/status", text)) return 0;
    return procKb(text, "VmRSS") / 1024;
}

long long worker::availableRamMb() {
    std::string text;
    if (!readProc("/proc/meminfo", text)) return 0;
    return procKb(text, "MemAvailable") / 1024;
}
