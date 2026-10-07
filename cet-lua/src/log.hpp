// cet-lua: dead-simple flushed logger to /tmp/cet-lua.log (spdlog-free; matches the runtime's /tmp logging).
#pragma once
#include <cstdarg>
#include <cstdio>

namespace cetlua
{
inline void LogInit()
{
    if (FILE* f = std::fopen("/tmp/cet-lua.log", "w"))
    {
        std::fprintf(f, "=== cet-lua log ===\n");
        std::fclose(f);
    }
}

inline void LogF(const char* fmt, ...)
{
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (FILE* f = std::fopen("/tmp/cet-lua.log", "a"))
    {
        std::fprintf(f, "%s\n", buf);
        std::fclose(f);
    }
    std::fprintf(stderr, "%s\n", buf);
}
} // namespace cetlua

#define LOGF(...) ::cetlua::LogF(__VA_ARGS__)
