/* BE-300 PicoGUI key event probe.
 *
 * Registers an app, binds a KEYDOWN/KEYUP/CHAR handler on its root,
 * and writes every key event it sees to /dev/kmsg so we can confirm
 * that pgserver is actually dispatching keys to clients on this build.
 */
#include <picogui.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

static int kmfd = -2;
static void klog(const char *fmt, ...) {
    char buf[160];
    va_list ap;
    int n;
    if (kmfd == -2) kmfd = open("/dev/kmsg", O_WRONLY | O_NONBLOCK);
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (kmfd >= 0 && n > 0) write(kmfd, buf, (n < (int)sizeof(buf)) ? n : (int)sizeof(buf)-1);
}

static int on_keydown(struct pgEvent *evt) {
    klog("[pg-keytest] KEYDOWN key=%d mods=%d\n",
         evt->e.kbd.key, evt->e.kbd.mods);
    return 0;
}
static int on_keyup(struct pgEvent *evt) {
    klog("[pg-keytest] KEYUP key=%d mods=%d\n",
         evt->e.kbd.key, evt->e.kbd.mods);
    return 0;
}
static int on_char(struct pgEvent *evt) {
    klog("[pg-keytest] CHAR key=%d mods=%d\n",
         evt->e.kbd.key, evt->e.kbd.mods);
    return 0;
}

int main(int argc, char **argv) {
    pghandle wApp, wLabel;
    pgInit(argc, argv);
    klog("[pg-keytest] pgInit done\n");

    wApp = pgRegisterApp(PG_APP_NORMAL, "BE-300 KeyTest", 0);
    klog("[pg-keytest] app registered wApp=%d\n", (int)wApp);

    wLabel = pgNewWidget(PG_WIDGET_LABEL, PG_DERIVE_INSIDE, wApp);
    pgSetWidget(wLabel,
                PG_WP_TEXT, pgNewString("Press keys (Stowaway/host).\nWatch /dev/kmsg."),
                PG_WP_SIDE, PG_S_TOP,
                0);

    /* PG_BIND_ANY catches events from any widget. */
    pgBind(PGBIND_ANY, PG_WE_KBD_KEYDOWN, on_keydown, NULL);
    pgBind(PGBIND_ANY, PG_WE_KBD_KEYUP,   on_keyup,   NULL);
    pgBind(PGBIND_ANY, PG_WE_KBD_CHAR,    on_char,    NULL);

    pgFocus(wLabel);
    klog("[pg-keytest] entering event loop\n");
    pgEventLoop();
    return 0;
}
