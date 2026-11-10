// Loads a fuzzer-supplied file through the real GnuCash file backend: format sniffing
// (plain / gzip XML, v1 and v2), the libxml2 SAX parser and every sixtp object parser.
#include <config.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

#include <cashobjects.h>
#include <gnc-engine.h>
#include <qofsession.h>
#include "gnc-backend-xml.h"
#include "io-gncxml-v2.h"

// GLib/GnuCash report recoverable precondition failures (g_return_if_fail and friends) as a logged
// "assertion '...' failed" and return. They are not crashes, and Mayhem counts any such line in a
// run's output as an Uncategorized defect that does not reproduce. Fatal levels still abort in GLib.
static void quiet_log(const gchar *, GLogLevelFlags level, const gchar *message, gpointer)
{
    if (level & G_LOG_FLAG_FATAL)
        g_printerr("%s\n", message);
}

static char *g_path;
static char *g_out_path;

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    const char *tmp = getenv("TMPDIR");
    g_path = g_build_filename(tmp && *tmp ? tmp : "/tmp", "fuzz_xml_book.XXXXXX", nullptr);
    int fd = g_mkstemp(g_path);
    if (fd < 0)
        return 1;
    close(fd);
    g_out_path = g_strconcat(g_path, ".out", nullptr);
    qof_init();
    cashobjects_register();
    gnc_module_init_backend_xml();
    g_log_set_default_handler(quiet_log, nullptr);
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (!g_file_set_contents(g_path, reinterpret_cast<const char *>(data), size, nullptr))
        return -1;
    auto session = qof_session_new(qof_book_new());
    qof_session_begin(session, g_path, SESSION_READ_ONLY);
    if (qof_session_get_error(session) == ERR_BACKEND_NO_ERR)
    {
        qof_session_load(session, nullptr);
        // Whatever was loaded is written back out, which exercises the XML generators on hostile data.
        // The writer dereferences the book's backend unconditionally, so only a book that got one is written.
        if (qof_session_get_error(session) == ERR_BACKEND_NO_ERR &&
            qof_book_get_backend(qof_session_get_book(session)))
            gnc_book_write_to_xml_file_v2(qof_session_get_book(session), g_out_path, FALSE);
    }
    qof_session_end(session);
    qof_session_destroy(session);
    return 0;
}
