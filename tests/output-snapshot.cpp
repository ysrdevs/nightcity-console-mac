#include "../overlay/output_snapshot.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

namespace fs = std::filesystem;
using nightcity::OutputSnapshotStatus;

static void write(const fs::path& path, const std::string& text) {
    std::ofstream stream(path, std::ios::binary | std::ios::trunc);
    assert(stream);
    stream.write(text.data(), static_cast<std::streamsize>(text.size()));
    assert(stream.good());
}

static nightcity::OutputSnapshot read(const fs::path& path) {
    auto snapshot = nightcity::readOutputSnapshot(path.c_str());
    assert(snapshot.bytesRead <= nightcity::outputSnapshotMaxBytes);
    assert(snapshot.lines.size() <= nightcity::outputSnapshotMaxLines);
    std::size_t characters = 0;
    for (const auto& line : snapshot.lines) characters += line.size();
    assert(characters <= nightcity::outputSnapshotMaxBytes);
    return snapshot;
}

int main() {
    char temporary[] = "/tmp/nightcity-output-snapshot.XXXXXX";
    const char* made = ::mkdtemp(temporary);
    assert(made);
    const fs::path directory(made), file = directory / "output.txt";
    // A FIFO regression should terminate this isolated test rather than hang CI.
    ::alarm(15);

    assert(read(file).status == OutputSnapshotStatus::missing);
    assert(nightcity::readOutputSnapshot(nullptr).errorNumber == EINVAL);
    write(file, "");
    auto empty = read(file);
    assert(empty.status == OutputSnapshotStatus::ready && empty.lines.empty());
    write(file, "first\n\nlast");
    auto ordinary = read(file);
    assert((ordinary.lines == std::vector<std::string>{"first", "", "last"}));
    assert(!ordinary.byteLimitReached && !ordinary.lineLimitReached);
    write(file, "one\n\n");
    assert((read(file).lines == std::vector<std::string>{"one", ""}));
    write(file, "\n");
    assert((read(file).lines == std::vector<std::string>{""}));

    // A large log keeps the actual last 400 lines without splitting long lines
    // into 2047-byte chunks as fgets did. Read allocation remains byte-bounded.
    std::string large;
    for (int i = 0; i < 3000; ++i) large += std::to_string(i) + ":" + std::string(180, 'x') + "\n";
    write(file, large);
    auto tail = read(file);
    assert(tail.byteLimitReached && tail.lineLimitReached);
    assert(tail.lines.size() == 400 && tail.lines.front().rfind("2600:", 0) == 0);
    assert(tail.lines.back().rfind("2999:", 0) == 0);

    // If the byte cutoff is exactly a line boundary, keep that complete line.
    const std::string first = "complete first line\n", last = "\nlast\n";
    std::string exact = first + std::string(nightcity::outputSnapshotMaxBytes - first.size() - last.size(), 'x') + last;
    assert(exact.size() == nightcity::outputSnapshotMaxBytes);
    write(file, "previous\n" + exact);
    auto aligned = read(file);
    assert(aligned.lines.size() == 3 && aligned.lines.front() == "complete first line");
    assert(!aligned.discardedPartialFirstLine);

    // A byte cutoff inside a line discards that prefix, including an oversized
    // single line with no following newline. The final complete line survives.
    write(file, std::string(nightcity::outputSnapshotMaxBytes * 2, 'x') + "\nretained\n");
    auto partial = read(file);
    assert(partial.discardedPartialFirstLine && partial.lines == std::vector<std::string>{"retained"});
    write(file, std::string(nightcity::outputSnapshotMaxBytes + 1, 'x'));
    assert(read(file).lines.empty());
    write(file, std::string(8192, 'y') + "\n");
    auto longLine = read(file);
    assert(longLine.lines.size() == 1 && longLine.lines[0].size() == 8192);

    write(file, std::string(2000, '\n'));
    auto blankLines = read(file);
    assert(blankLines.lines.size() == 400 && blankLines.lineLimitReached);
    for (const auto& line : blankLines.lines) assert(line.empty());

    // Truncation and inode replacement between requests do not keep an old seek
    // position or append new content to an obsolete snapshot.
    write(file, "before rotation\n");
    auto before = read(file);
    fs::rename(file, directory / "rotated.txt");
    write(file, "replacement\n");
    assert(read(file).lines == std::vector<std::string>{"replacement"});
    assert(before.lines == std::vector<std::string>{"before rotation"});
    write(file, "a much longer record\nsecond record\n");
    write(file, "new\n");
    assert(read(file).lines == std::vector<std::string>{"new"});
    fs::remove(file);
    assert(read(file).status == OutputSnapshotStatus::missing);
    write(file, "back\n");
    assert(read(file).lines == std::vector<std::string>{"back"});

    const fs::path fifo = directory / "fifo", symlink = directory / "symlink", dangling = directory / "dangling";
    assert(::mkfifo(fifo.c_str(), 0600) == 0);
    const auto started = std::chrono::steady_clock::now();
    assert(read(fifo).status == OutputSnapshotStatus::refused);
    assert(std::chrono::steady_clock::now() - started < std::chrono::seconds(1));
    fs::create_symlink(file, symlink);
    fs::create_symlink(directory / "absent", dangling);
    assert(read(symlink).status == OutputSnapshotStatus::refused);
    assert(read(dangling).status == OutputSnapshotStatus::refused);
    assert(read(directory).status == OutputSnapshotStatus::refused);

    // Concurrent callers own their vectors; replacing the path is atomic, so
    // each snapshot contains either whole generation, never a mixture of both.
    const std::string a = "alpha\nalpha\nalpha\n", b = "bravo\nbravo\nbravo\n";
    write(file, a);
    std::atomic<bool> failed{false};
    std::thread writer([&] {
        for (int i = 0; i < 100; ++i) {
            const auto replacement = directory / "replacement.txt";
            write(replacement, (i % 2) ? a : b);
            fs::rename(replacement, file);
        }
    });
    std::vector<std::thread> readers;
    for (int i = 0; i < 4; ++i) readers.emplace_back([&] {
        for (int sample = 0; sample < 200; ++sample) {
            const auto snapshot = read(file);
            if (snapshot.status != OutputSnapshotStatus::ready || snapshot.lines.size() != 3) { failed = true; continue; }
            const auto& line = snapshot.lines[0];
            if ((line != "alpha" && line != "bravo") || snapshot.lines[1] != line || snapshot.lines[2] != line) failed = true;
        }
    });
    writer.join();
    for (auto& reader : readers) reader.join();
    assert(!failed.load());
    ::alarm(0);
    fs::remove_all(directory);
    std::cout << "PASS bounded output tail, line boundaries, empty/long lines, rotation, truncation, missing file, FIFO/symlink refusal and concurrent snapshot ownership\n";
}
