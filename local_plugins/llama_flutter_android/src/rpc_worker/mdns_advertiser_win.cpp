#include "mdns_advertiser.h"

#include <winsock2.h>
#include <windows.h>
#include <windns.h>

#include <cstdio>
#include <string>
#include <vector>

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

// DnsServiceRegister keeps pointers into these until deregistration, so they
// must outlive the call.
std::wstring g_instance;
std::wstring g_host;
std::vector<std::wstring> g_key_storage;
std::vector<std::wstring> g_value_storage;
std::vector<PWSTR> g_keys;
std::vector<PWSTR> g_values;
DNS_SERVICE_INSTANCE g_service = {};
DNS_SERVICE_REGISTER_REQUEST g_request = {};
DNS_SERVICE_CANCEL g_cancel = {};
IP4_ADDRESS g_ip4 = 0;
bool g_started = false;

VOID CALLBACK onRegistered(DWORD status, PVOID, PDNS_SERVICE_INSTANCE) {
    if (status != ERROR_SUCCESS) {
        // Discovery is a convenience; the worker is still reachable by IP.
        OutputDebugStringW(L"PrivateLM: mDNS registration failed\n");
    }
}

void addProperty(const wchar_t* key, const std::wstring& value) {
    g_key_storage.emplace_back(key);
    g_value_storage.push_back(value);
}

} // namespace

bool worker::startMdnsAdvertiser(const std::string& instance_name,
                                 const std::string& host_name, int port,
                                 long long ram_mb, double bandwidth,
                                 const std::string& id,
                                 const std::string& model,
                                 const std::string& ipv4) {
    if (g_started) return true;

    g_instance = widen(instance_name + "._privatelm._tcp.local");
    g_host = widen(host_name);
    if (g_instance.empty() || g_host.empty()) return false;

    g_key_storage.clear();
    g_value_storage.clear();
    g_keys.clear();
    g_values.clear();

    wchar_t bandwidth_text[32];
    std::swprintf(bandwidth_text, 32, L"%.1f", bandwidth);
    addProperty(L"ram", std::to_wstring(ram_mb));
    addProperty(L"bw", bandwidth_text);
    addProperty(L"model", widen(model));
    addProperty(L"v", L"rpc7");
    addProperty(L"id", widen(id));

    g_keys.reserve(g_key_storage.size());
    g_values.reserve(g_value_storage.size());
    for (size_t i = 0; i < g_key_storage.size(); i++) {
        g_keys.push_back(g_key_storage[i].data());
        g_values.push_back(g_value_storage[i].data());
    }

    g_service = {};
    g_service.pszInstanceName = g_instance.data();
    g_service.pszHostName = g_host.data();
    g_service.wPort = static_cast<WORD>(port);
    g_service.wPriority = 0;
    g_service.wWeight = 0;
    g_service.dwPropertyCount = static_cast<DWORD>(g_keys.size());
    g_service.keys = g_keys.data();
    g_service.values = g_values.data();
    g_service.dwInterfaceIndex = 0;

    if (!ipv4.empty()) {
        const unsigned long address = inet_addr(ipv4.c_str());
        if (address != INADDR_NONE) {
            g_ip4 = address;
            g_service.ip4Address = &g_ip4;
        }
    }

    g_request = {};
    g_request.Version = 1; // DNS_SERVICE_REGISTER_REQUEST_VERSION
    g_request.InterfaceIndex = 0;
    g_request.pServiceInstance = &g_service;
    g_request.pRegisterCompletionCallback = onRegistered;
    g_request.pQueryContext = nullptr;
    g_request.hCredentials = nullptr;
    g_request.unicastEnabled = FALSE;

    g_cancel = {};
    const DWORD result = DnsServiceRegister(&g_request, &g_cancel);
    // Registration is asynchronous: DNS_REQUEST_PENDING is the success case.
    g_started = result == DNS_REQUEST_PENDING || result == ERROR_SUCCESS;
    return g_started;
}

void worker::stopMdnsAdvertiser() {
    if (!g_started) return;
    DnsServiceDeRegister(&g_request, &g_cancel);
    g_started = false;
}
