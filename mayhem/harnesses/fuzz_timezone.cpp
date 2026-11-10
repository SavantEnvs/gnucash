// Parses a fuzzer-supplied IANA zoneinfo (TZif) file with GnuCash's own timezone loader.
#include <config.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#include <exception>
#include <string>

#include <gnc-timezone.hpp>

static char *g_path;

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    const char *tmp = getenv("TMPDIR");
    g_path = g_build_filename(tmp && *tmp ? tmp : "/tmp", "fuzz_timezone.XXXXXX", nullptr);
    int fd = g_mkstemp(g_path);
    if (fd < 0)
        return 1;
    close(fd);
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    // The TZif header is 44 bytes (tzfile(5)); IANAParser reads it unconditionally, so a shorter file is
    // not a TZif file. Header counts beyond that are NOT filtered: the loader trusts them and that is a finding.
    constexpr size_t tzif_header_size = 44;
    if (size < tzif_header_size)
        return -1;
    if (!g_file_set_contents(g_path, reinterpret_cast<const char *>(data), size, nullptr))
        return -1;
    // A leading ':' with an absolute path makes the loader read exactly this file.
    TimeZoneProvider provider(std::string(":") + g_path);
    for (int year : {1400, 1901, 1970, 2000, 2038, 2500, 9999})
        provider.get(year);
    return 0;
}
