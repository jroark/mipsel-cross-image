/* BE-300 PicoGUI interactive demo: title bar, label, tappable button.
 *
 * Touch the button — pgserver fires PG_WE_ACTIVATE → libpgui calls our
 * handler → label updates, counter increments.  Counts pgserver alive
 * for as many ticks as the button is responsive.
 */
#include <picogui.h>
#include <stdio.h>
#include <stdlib.h>

static pghandle wLabel;
static int taps = 0;

static int on_button(struct pgEvent *evt) {
    char buf[64];
    taps++;
    snprintf(buf, sizeof(buf), "Tapped %d times!", taps);
    pgReplaceText(wLabel, buf);
    pgSubUpdate(wLabel);
    fprintf(stderr, "DEMO: tap #%d\n", taps);
    fflush(stderr);
    return 0;
}

int main(int argc, char **argv)
{
    pghandle wApp, wButton;

    pgInit(argc, argv);
    fprintf(stderr, "DEMO: pgInit done\n");
    fflush(stderr);

    wApp = pgRegisterApp(PG_APP_NORMAL, "BE-300 PicoGUI Demo", 0);
    fprintf(stderr, "DEMO: registered app wApp=%d\n", (int)wApp);
    fflush(stderr);

    /* Label at top */
    wLabel = pgNewWidget(PG_WIDGET_LABEL, PG_DERIVE_INSIDE, wApp);
    pgSetWidget(wLabel,
                PG_WP_TEXT, pgNewString("Tap the button below"),
                PG_WP_SIDE, PG_S_TOP,
                0);
    fprintf(stderr, "DEMO: label created wLabel=%d\n", (int)wLabel);
    fflush(stderr);

    /* Button below */
    wButton = pgNewWidget(PG_WIDGET_BUTTON, PG_DERIVE_INSIDE, wApp);
    pgSetWidget(wButton,
                PG_WP_TEXT, pgNewString("Tap me!"),
                PG_WP_SIDE, PG_S_TOP,
                0);
    pgBind(wButton, PG_WE_ACTIVATE, on_button, NULL);
    fprintf(stderr, "DEMO: button created wButton=%d\n", (int)wButton);
    fflush(stderr);

    fprintf(stderr, "DEMO: entering event loop\n");
    fflush(stderr);
    pgEventLoop();

    return 0;
}
