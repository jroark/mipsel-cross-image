/* Bisect: 3 versions selected by argv[1]. */
#include <picogui.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    pghandle wApp, wLabel, hStr;
    const char *which = (argc > 1) ? argv[1] : "1";

    pgInit(argc, argv);
    fprintf(stderr, "BISECT: pgInit done, mode=%s\n", which);
    fflush(stderr);

    wApp = pgRegisterApp(PG_APP_NORMAL, "BisectApp", 0);
    fprintf(stderr, "BISECT: pgRegisterApp done, wApp=%d\n", (int)wApp);
    fflush(stderr);

    if (strcmp(which, "1") == 0) {
        /* mode 1: only register, then sleep so server stays connected */
        pgEventLoop();
        return 0;
    }

    hStr = pgNewString("Hello PicoGUI");
    fprintf(stderr, "BISECT: pgNewString done, hStr=%d\n", (int)hStr);
    fflush(stderr);

    if (strcmp(which, "2") == 0) {
        pgEventLoop();
        return 0;
    }

    wLabel = pgNewWidget(PG_WIDGET_LABEL, PG_DERIVE_INSIDE, wApp);
    fprintf(stderr, "BISECT: pgNewWidget done, wLabel=%d\n", (int)wLabel);
    fflush(stderr);

    if (strcmp(which, "3") == 0) {
        pgEventLoop();
        return 0;
    }

    pgSetWidget(wLabel, PG_WP_TEXT, hStr, 0);
    fprintf(stderr, "BISECT: pgSetWidget done\n");
    fflush(stderr);

    pgEventLoop();
    return 0;
}
