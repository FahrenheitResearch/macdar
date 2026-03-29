#include "polling_links.h"
#include "downloader.h"
#include <algorithm>
#include <cctype>
#include <ctime>
#include <sstream>

namespace {

std::string trim(const std::string& s) {
    size_t start = 0;
    while (start < s.size() && std::isspace((unsigned char)s[start])) start++;
    size_t end = s.size();
    while (end > start && std::isspace((unsigned char)s[end - 1])) end--;
    return s.substr(start, end - start);
}

std::string toLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return s;
}

bool startsWithInsensitive(const std::string& text, const char* prefix) {
    const std::string lhs = toLower(trim(text));
    const std::string rhs = toLower(prefix);
    return lhs.rfind(rhs, 0) == 0;
}

std::string currentUtcString() {
    std::time_t now = std::time(nullptr);
    std::tm tm = {};
#ifdef _WIN32
    gmtime_s(&tm, &now);
#else
    gmtime_r(&now, &tm);
#endif
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02dZ",
                  tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                  tm.tm_hour, tm.tm_min, tm.tm_sec);
    return buf;
}

bool splitHttpUrl(const std::string& url,
                  bool& https,
                  std::string& host,
                  std::string& path,
                  int& port,
                  std::string& error) {
    std::string work = trim(url);
    if (work.empty()) {
        error = "Polling link URL is empty";
        return false;
    }

    https = true;
    port = 443;
    size_t start = 0;
    if (work.rfind("https://", 0) == 0) {
        start = 8;
    } else if (work.rfind("http://", 0) == 0) {
        start = 7;
        https = false;
        port = 80;
    } else {
        error = "Polling links must start with http:// or https://";
        return false;
    }

    size_t slash = work.find('/', start);
    std::string hostPort = (slash == std::string::npos) ? work.substr(start) : work.substr(start, slash - start);
    path = (slash == std::string::npos) ? "/" : work.substr(slash);
    if (hostPort.empty()) {
        error = "Polling link is missing a host";
        return false;
    }

    size_t colon = hostPort.find(':');
    host = (colon == std::string::npos) ? hostPort : hostPort.substr(0, colon);
    if (colon != std::string::npos)
        port = std::stoi(hostPort.substr(colon + 1));
    return true;
}

} // namespace

bool PollingLinkManager::addLink(const std::string& url, std::string& error) {
    bool https = true;
    std::string host;
    std::string path;
    int port = 443;
    if (!splitHttpUrl(url, https, host, path, port, error))
        return false;

    PollingLinkEntry entry;
    entry.url = trim(url);
    entry.title = host;

    if (!refreshEntry(entry)) {
        error = entry.last_error.empty() ? entry.last_status : entry.last_error;
        return false;
    }

    std::lock_guard<std::mutex> lock(m_mutex);
    m_entries.push_back(std::move(entry));
    return true;
}

void PollingLinkManager::removeLink(size_t index) {
    std::lock_guard<std::mutex> lock(m_mutex);
    if (index >= m_entries.size()) return;
    m_entries.erase(m_entries.begin() + (ptrdiff_t)index);
}

std::vector<PollingLinkEntry> PollingLinkManager::entries() const {
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_entries;
}

void PollingLinkManager::refreshAll() {
    std::lock_guard<std::mutex> lock(m_mutex);
    for (auto& entry : m_entries)
        refreshEntry(entry);
}

bool PollingLinkManager::refreshEntry(PollingLinkEntry& entry) {
    try {
        bool https = true;
        std::string host;
        std::string path;
        int port = 443;
        std::string error;
        if (!splitHttpUrl(entry.url, https, host, path, port, error)) {
            entry.last_status = "Invalid URL";
            entry.last_error = error;
            return false;
        }

        auto result = Downloader::httpGet(host, path, port, https);
        entry.last_fetch_utc = currentUtcString();
        entry.bytes = result.data.size();
        entry.line_count = 0;
        entry.polygon_count = 0;
        entry.text_count = 0;
        entry.icon_count = 0;

        if (!result.success) {
            entry.last_status = "HTTP " + std::to_string(result.status_code);
            entry.last_error = result.error;
            return false;
        }

        entry.last_error.clear();
        entry.last_status = "OK";

        std::string text(result.data.begin(), result.data.end());
        std::istringstream input(text);
        std::string line;
        while (std::getline(input, line)) {
            std::string trimmed = trim(line);
            if (trimmed.empty()) continue;
            if (startsWithInsensitive(trimmed, "title:")) {
                entry.title = trim(trimmed.substr(trimmed.find(':') + 1));
            } else if (startsWithInsensitive(trimmed, "refresh:")) {
                try {
                    entry.refresh_seconds = std::max(1, std::stoi(trim(trimmed.substr(trimmed.find(':') + 1))));
                } catch (...) {
                    entry.refresh_seconds = 60;
                }
            } else if (startsWithInsensitive(trimmed, "line:")) {
                entry.line_count++;
            } else if (startsWithInsensitive(trimmed, "polygon:")) {
                entry.polygon_count++;
            } else if (startsWithInsensitive(trimmed, "text:")) {
                entry.text_count++;
            } else if (startsWithInsensitive(trimmed, "icon:")) {
                entry.icon_count++;
            }
        }

        return true;
    } catch (const std::exception& e) {
        entry.last_status = "Parse Error";
        entry.last_error = e.what();
        return false;
    } catch (...) {
        entry.last_status = "Parse Error";
        entry.last_error = "Unknown polling link exception";
        return false;
    }
}
