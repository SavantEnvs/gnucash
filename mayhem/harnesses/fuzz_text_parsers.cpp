// Text-to-value parsers used by the importers and the register: amounts, dates, numerics and URIs.
// The first byte picks the parser, the rest is its input.
#include <config.h>
#include <glib.h>
#include <stdint.h>
#include <string>

#include <gnc-date.h>
#include <gnc-datetime.hpp>
#include <gnc-numeric.hpp>
#include <gnc-uri-utils.h>
#include <gnc-ui-util.h>

// GLib/GnuCash report recoverable precondition failures (g_return_if_fail and friends) as a logged
// "assertion '...' failed" and return. They are not crashes, and Mayhem counts any such line in a
// run's output as an Uncategorized defect that does not reproduce. Fatal levels still abort in GLib.
static void quiet_log(const gchar *, GLogLevelFlags level, const gchar *message, gpointer)
{
    if (level & G_LOG_FLAG_FATAL)
        g_printerr("%s\n", message);
}

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    g_log_set_default_handler(quiet_log, nullptr);
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 1)
        return -1;
    std::string text(reinterpret_cast<const char *>(data + 1), size - 1);
    switch (data[0] % 8)
    {
    case 0:
    {
        gnc_numeric value;
        char *endptr = nullptr;
        xaccParseAmount(text.c_str(), TRUE, &value, &endptr);
        break;
    }
    case 1:
    {
        gnc_numeric value;
        char *endptr = nullptr;
        xaccParseAmountExtended(text.c_str(), FALSE, '-', '.', ',', "$", &value, &endptr);
        break;
    }
    case 2:
    {
        try { GncNumeric n(text, true); (void)n.to_string(); } catch (const std::exception &) {}
        break;
    }
    case 3:
    {
        int d, m, y;
        qof_scan_date(text.c_str(), &d, &m, &y);
        break;
    }
    case 4:
        gnc_iso8601_to_time64_gmt(text.c_str());
        break;
    case 5:
    {
        try { GncDateTime t(text); (void)t.format("%Y-%m-%d %H:%M:%S"); } catch (const std::exception &) {}
        break;
    }
    case 6:
    {
        gchar *scheme = nullptr, *host = nullptr, *user = nullptr, *pass = nullptr, *path = nullptr;
        gint port = 0;
        gnc_uri_get_components(text.c_str(), &scheme, &host, &port, &user, &pass, &path);
        g_free(scheme); g_free(host); g_free(user); g_free(pass); g_free(path);
        break;
    }
    case 7:
        g_free(gnc_uri_normalize_uri(text.c_str(), TRUE));
        break;
    }
    return 0;
}
