/* BE-300 PicoGUI desktop primer.
 *
 * Tiny PG_APP_NORMAL anchored at the TOP (right under omnibar).
 * Workaround for a pgserver layout bug where the first PG_APP_NORMAL
 * after a toolbar-only divtree fails to render correctly.  Subsequent
 * apps (atomicnav etc.) launched from omnibar's Applications menu
 * then take the remaining non-toolbar area and ARE visible.
 *
 * 28px tall info strip with a hint about how to launch apps.
 */

#include <picogui.h>

int main(int argc, char **argv) {
    pghandle wApp, wLabel;

    pgInit(argc, argv);
    /* PG_APPSPEC_SIDE=PG_S_TOP -> sit right under omnibar's toolbar.
     * PG_APPSPEC_HEIGHT=28 -> fit the welcome label without dominating
     * the screen.  With PG_S_TOP + 28px, the rest of the non-toolbar
     * area falls to whatever PG_APP_NORMAL launches next (atomicnav). */
    wApp = pgRegisterApp(PG_APP_NORMAL, "BE-300",
                         PG_APPSPEC_SIDE, PG_S_TOP,
                         PG_APPSPEC_HEIGHT, 28,
                         0);

    wLabel = pgNewWidget(PG_WIDGET_LABEL, PG_DERIVE_INSIDE, wApp);
    pgSetWidget(wLabel,
                PG_WP_TEXT, pgNewString("Tap Applications above to launch"),
                PG_WP_SIDE, PG_S_ALL,
                PG_WP_ALIGN, PG_A_CENTER,
                0);

    pgEventLoop();
    return 0;
}
