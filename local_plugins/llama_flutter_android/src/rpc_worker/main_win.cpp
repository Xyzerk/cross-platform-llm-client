// Windows entry point and OS hooks for privatelm_rpc_worker.exe.
#include <winsock2.h>
#include <windows.h>
#include <ws2tcpip.h>

#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

#include "platform.h"

namespace {

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

std::string messageFor(DWORD code) {
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

BOOL WINAPI ctrlHandler(DWORD type) {
    if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT ||
        type == CTRL_CLOSE_EVENT || type == CTRL_SHUTDOWN_EVENT) {
        ExitProcess(0);
    }
    return FALSE;
}

} // namespace

std::string worker::systemError(int code) {
    return messageFor(static_cast<DWORD>(code));
}

std::string worker::hostName() {
    wchar_t buffer[MAX_COMPUTERNAME_LENGTH + 1] = {};
    DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
    if (!GetComputerNameW(buffer, &size)) return "Windows PC";
    return narrow(std::wstring(buffer, size));
}

/// Detached children have no stdio handles. Point them at NUL so llama.cpp's
/// printf/fprintf calls never hit an invalid handle.
void worker::silenceMissingStdio() {
    const HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    if (out == nullptr || out == INVALID_HANDLE_VALUE) {
        std::freopen("NUL", "w", stdout);
    }
    const HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    if (err == nullptr || err == INVALID_HANDLE_VALUE) {
        std::freopen("NUL", "w", stderr);
    }
}

bool worker::canBind(const std::string& host, int port, std::string& error) {
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

std::string worker::bindHint() {
    return "Allow PrivateLM through Windows Firewall, close other PrivateLM "
           "windows, or choose another port.";
}

void worker::installShutdownHandlers() {
    SetConsoleCtrlHandler(ctrlHandler, TRUE);
}

bool worker::watchParent(unsigned long long parent_pid, std::string& error) {
    HANDLE parent = OpenProcess(SYNCHRONIZE, FALSE,
                                static_cast<DWORD>(parent_pid));
    if (!parent) {
        error = "The app that started this worker is no longer running";
        return false;
    }
    // Detached so nothing has to join it: the watchdog only exits the process.
    std::thread([parent] {
        WaitForSingleObject(parent, INFINITE);
        CloseHandle(parent);
        ExitProcess(0);
    }).detach();
    return true;
}

int main(int argc, char** argv) {
    return worker::runWorker(argc, argv);
}
