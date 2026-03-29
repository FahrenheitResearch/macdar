#pragma once
#include <string>
#include <vector>
#include <mutex>

struct PollingLinkEntry {
    std::string url;
    std::string title;
    std::string last_status;
    std::string last_error;
    std::string last_fetch_utc;
    bool enabled = true;
    int refresh_seconds = 60;
    int line_count = 0;
    int polygon_count = 0;
    int text_count = 0;
    int icon_count = 0;
    size_t bytes = 0;
};

class PollingLinkManager {
public:
    bool addLink(const std::string& url, std::string& error);
    void removeLink(size_t index);
    void refreshAll();
    std::vector<PollingLinkEntry> entries() const;

private:
    bool refreshEntry(PollingLinkEntry& entry);

    std::vector<PollingLinkEntry> m_entries;
    mutable std::mutex m_mutex;
};
