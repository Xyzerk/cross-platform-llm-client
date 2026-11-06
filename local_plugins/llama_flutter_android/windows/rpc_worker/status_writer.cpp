#include "status_writer.h"

#include <windows.h>
#include <psapi.h>

#include <cstdio>
#include <string>

namespace {

std::wstring widen(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                        static_cast<int>(utf8.size()), nullptr, 0);
    if (len <= 0) return {};
    std::wstring out(static_cast<size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                        out.data(), len);
    return out;
}

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

bool writeAll(const std::wstring& path, const std::string& data) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                              nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok =
        WriteFile(file, data.data(), static_cast<DWORD>(data.size()), &written,
                  nullptr) != 0 &&
        written == data.size();
    CloseHandle(file);
    return ok;
}

} // namespace

void worker::writeStatusFile(const std::string& path, const Status& status) {
    char head[1024];
    std::snprintf(head, sizeof(head),
                  "{\"state\":\"%s\",\"ramMb\":%lld,\"bandwidth\":%.2f,"
                  "\"heldMb\":%lld,\"throttled\":false,"
                  "\"batteryUnrestricted\":true,\"pid\":%lu,\"id\":\"%s\"",
                  jsonEscape(status.state).c_str(), status.ram_mb,
                  status.bandwidth, status.held_mb,
                  static_cast<unsigned long>(GetCurrentProcessId()),
                  jsonEscape(status.id).c_str());

    std::string json(head);
    if (!status.peer.empty()) {
        json += ",\"peer\":\"" + jsonEscape(status.peer) + "\"";
    }
    if (!status.error.empty()) {
        json += ",\"error\":\"" + jsonEscape(status.error) + "\"";
    }
    json += "}";

    const std::wstring wide = widen(path);
    if (wide.empty()) return;
    const std::wstring temp = wide + L".tmp";
    if (!writeAll(temp, json)) return;
    if (!MoveFileExW(temp.c_str(), wide.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(temp.c_str());
    }
}

long long worker::residentMb() {
    PROCESS_MEMORY_COUNTERS_EX counters = {};
    if (!GetProcessMemoryInfo(GetCurrentProcess(),
                              reinterpret_cast<PROCESS_MEMORY_COUNTERS*>(&counters),
                              sizeof(counters))) {
        return 0;
    }
    return static_cast<long long>(counters.WorkingSetSize / (1024 * 1024));
}

long long worker::availableRamMb() {
    MEMORYSTATUSEX memory = {};
    memory.dwLength = sizeof(memory);
    if (!GlobalMemoryStatusEx(&memory)) return 0;
    return static_cast<long long>(memory.ullAvailPhys / (1024 * 1024));
}
