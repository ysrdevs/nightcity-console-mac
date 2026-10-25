#pragma once

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace nightcity {

constexpr std::size_t outputSnapshotMaxBytes = 128 * 1024;
constexpr std::size_t outputSnapshotMaxLines = 400;

enum class OutputSnapshotStatus { ready, missing, refused, changed, ioError };

struct OutputSnapshot {
    std::vector<std::string> lines;
    OutputSnapshotStatus status = OutputSnapshotStatus::ioError;
    std::size_t bytesRead = 0; // Payload only; at most one additional byte checks the first-line boundary.
    int errorNumber = 0;
    bool byteLimitReached = false;
    bool discardedPartialFirstLine = false;
    bool lineLimitReached = false;
};

namespace output_snapshot_detail {
struct Descriptor {
    int value;
    ~Descriptor() { if (value >= 0) ::close(value); }
    Descriptor(const Descriptor&) = delete;
    Descriptor& operator=(const Descriptor&) = delete;
    explicit Descriptor(int descriptor) : value(descriptor) {}
};

// A bounded retry count avoids an endless EINTR loop during shutdown or signal storms.
inline ssize_t readAt(int fd, void* buffer, std::size_t count, off_t offset) {
    for (unsigned retry = 0; retry < 4; ++retry) {
        const ssize_t result = ::pread(fd, buffer, count, offset);
        if (result >= 0 || errno != EINTR) return result;
    }
    return -1;
}
} // namespace output_snapshot_detail

// Invoke on a worker, never on a rendering callback. There is no retained file
// position or mutable shared state: each call opens the current file, so rotation
// and truncation between calls work without a separate watcher or reset operation.
inline OutputSnapshot readOutputSnapshot(const char* path) {
    OutputSnapshot result;
    if (!path || !*path) {
        result.errorNumber = EINVAL;
        return result;
    }
    const int opened = ::open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW);
    if (opened < 0) {
        result.errorNumber = errno;
        result.status = errno == ENOENT ? OutputSnapshotStatus::missing :
                        errno == ELOOP ? OutputSnapshotStatus::refused : OutputSnapshotStatus::ioError;
        return result;
    }
    const output_snapshot_detail::Descriptor descriptor(opened);
    struct stat initial{};
    if (::fstat(opened, &initial) != 0) {
        result.errorNumber = errno;
        return result;
    }
    // O_NONBLOCK above is essential: opening a FIFO must not wait for its writer
    // before this check. Reject directories, devices, sockets and other node types.
    if (!S_ISREG(initial.st_mode) || initial.st_size < 0) {
        result.status = OutputSnapshotStatus::refused;
        return result;
    }
    const auto count = initial.st_size > static_cast<off_t>(outputSnapshotMaxBytes)
        ? outputSnapshotMaxBytes : static_cast<std::size_t>(initial.st_size);
    const off_t offset = initial.st_size - static_cast<off_t>(count);
    result.byteLimitReached = offset > 0;
    char preceding = '\n';
    if (offset > 0) {
        const ssize_t read = output_snapshot_detail::readAt(opened, &preceding, 1, offset - 1);
        if (read != 1) {
            result.status = read == 0 ? OutputSnapshotStatus::changed : OutputSnapshotStatus::ioError;
            result.errorNumber = read < 0 ? errno : 0;
            return result;
        }
    }
    std::string bytes(count, '\0');
    while (result.bytesRead < count) {
        const ssize_t read = output_snapshot_detail::readAt(opened, bytes.data() + result.bytesRead,
                                                           count - result.bytesRead,
                                                           offset + static_cast<off_t>(result.bytesRead));
        if (read <= 0) {
            // Do not publish a partially read snapshot if the file was truncated.
            result.status = read == 0 ? OutputSnapshotStatus::changed : OutputSnapshotStatus::ioError;
            result.errorNumber = read < 0 ? errno : 0;
            return result;
        }
        result.bytesRead += static_cast<std::size_t>(read);
    }
    struct stat finalState{};
    if (::fstat(opened, &finalState) != 0) {
        result.errorNumber = errno;
        return result;
    }
    if (finalState.st_size < initial.st_size) {
        result.status = OutputSnapshotStatus::changed;
        return result;
    }
    // Capture the original EOF. Concurrent appends cannot make this worker chase
    // an ever-growing file; the next request picks them up.
    std::size_t begin = 0;
    if (offset > 0 && preceding != '\n') {
        result.discardedPartialFirstLine = true;
        const std::size_t newline = bytes.find('\n');
        begin = newline == std::string::npos ? bytes.size() : newline + 1;
    }
    // Walk backwards so even a tail containing thousands of empty lines allocates
    // no more than 400 strings. Preserve real empty lines, but do not invent an
    // extra line for the final newline. An unterminated final line remains visible.
    std::size_t end = bytes.size();
    result.lines.reserve(outputSnapshotMaxLines);
    while (end > begin && result.lines.size() < outputSnapshotMaxLines) {
        std::size_t contentEnd = end;
        if (bytes[contentEnd - 1] == '\n') --contentEnd;
        const std::size_t newline = contentEnd > begin ? bytes.rfind('\n', contentEnd - 1) : std::string::npos;
        const std::size_t lineStart = newline != std::string::npos && newline >= begin ? newline + 1 : begin;
        result.lines.emplace_back(bytes.data() + lineStart, contentEnd - lineStart);
        end = lineStart;
    }
    result.lineLimitReached = end > begin;
    std::reverse(result.lines.begin(), result.lines.end());
    result.status = OutputSnapshotStatus::ready;
    return result;
}

} // namespace nightcity
