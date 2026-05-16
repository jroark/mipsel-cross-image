/* Minimal picogui demo client — pgRegisterApp + label, no DIALOGBOX. */
#include <picogui.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    pghandle wApp, wLabel;

    pgInit(argc, argv);

    /* Register a standard app (PG_APP_NORMAL) — picosm's PG_WIDGET_DIALOGBOX
     * path crashes pgserver, so go via pgRegisterApp instead, like pgboard
     * and the upstream demos do. */
    wApp = pgRegisterApp(PG_APP_NORMAL, "BE-300 PicoGUI", 0);

    /* Add a label child so the framebuffer actually shows something. */
    wLabel = pgNewWidget(PG_WIDGET_LABEL, PG_DERIVE_INSIDE, wApp);
    pgSetWidget(wLabel,
                PG_WP_TEXT, pgNewString("Hello from PicoGUI on the BE-300!"),
                PG_WP_SIDE, PG_S_ALL,
                0);

    pgEventLoop();
    return 0;
}
