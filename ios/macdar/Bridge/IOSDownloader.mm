// iOS implementation of Downloader using NSURLSession
// Replaces the libcurl-based downloader.cpp for iOS builds

#include "net/downloader.h"
#import <Foundation/Foundation.h>
#include <cstdio>

// ── Synchronous HTTP GET via NSURLSession ──────────────────

DownloadResult Downloader::httpGet(const std::string& host, const std::string& path,
                                    int port, bool https) {
    DownloadResult result = {};

    NSString* scheme = https ? @"https" : @"http";
    NSString* urlStr;
    if (port == 443 || port == 80) {
        urlStr = [NSString stringWithFormat:@"%@://%s%s", scheme, host.c_str(), path.c_str()];
    } else {
        urlStr = [NSString stringWithFormat:@"%@://%s:%d%s", scheme, host.c_str(), port, path.c_str()];
    }

    NSURL* url = [NSURL URLWithString:urlStr];
    if (!url) {
        result.error = "Invalid URL: " + host + path;
        return result;
    }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    request.HTTPMethod = @"GET";

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __block DownloadResult blockResult = {};

    NSURLSessionDataTask* task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            if (error) {
                blockResult.error = std::string([error.localizedDescription UTF8String]);
                blockResult.success = false;
            } else {
                NSHTTPURLResponse* httpResp = (NSHTTPURLResponse*)response;
                blockResult.status_code = (int)httpResp.statusCode;
                blockResult.success = (httpResp.statusCode >= 200 && httpResp.statusCode < 300);
                if (data && data.length > 0) {
                    const uint8_t* bytes = (const uint8_t*)data.bytes;
                    blockResult.data.assign(bytes, bytes + data.length);
                }
                if (!blockResult.success) {
                    blockResult.error = "HTTP " + std::to_string(blockResult.status_code);
                }
            }
            dispatch_semaphore_signal(semaphore);
        }];

    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

    result = std::move(blockResult);
    return result;
}

// ── Async download manager ─────────────────────────────────

Downloader::Downloader(int maxConcurrent) {
    // Create worker threads (same pattern as curl version)
    int numWorkers = std::min(maxConcurrent, 12); // cap for iOS
    for (int i = 0; i < numWorkers; i++) {
        m_workers.emplace_back(&Downloader::workerThread, this);
    }
}

Downloader::~Downloader() {
    shutdown();
}

void Downloader::queueDownload(const std::string& id,
                                const std::string& host,
                                const std::string& path,
                                Callback callback) {
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_shutdown) return;
        m_queue.push({id, host, path, std::move(callback)});
        m_pending++;
    }
    m_cv.notify_one();
}

void Downloader::waitAll() {
    std::unique_lock<std::mutex> lock(m_mutex);
    m_doneCV.wait(lock, [this] { return m_pending == 0; });
}

void Downloader::shutdown() {
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_shutdown = true;
    }
    m_cv.notify_all();
    for (auto& w : m_workers) {
        if (w.joinable()) w.join();
    }
    m_workers.clear();
}

void Downloader::workerThread() {
    while (true) {
        DownloadTask task;
        {
            std::unique_lock<std::mutex> lock(m_mutex);
            m_cv.wait(lock, [this] { return m_shutdown || !m_queue.empty(); });
            if (m_shutdown && m_queue.empty()) return;
            task = std::move(m_queue.front());
            m_queue.pop();
        }

        auto result = httpGet(task.host, task.path);

        if (task.callback) {
            try {
                task.callback(task.id, std::move(result));
            } catch (...) {}
        }

        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_pending--;
        }
        m_doneCV.notify_all();
    }
}
