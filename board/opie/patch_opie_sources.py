#!/usr/bin/env python3
"""Final BE-300 OPIE source fixes applied before building."""

from pathlib import Path
import re
import sys
import tarfile


ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/work/opie-1.2.5-be300")
ARCHIVE_CANDIDATES = (
    Path("/work/archives/opie-1.2.5.tar.bz2"),
    Path.cwd() / "archives/opie-1.2.5.tar.bz2",
)


def read_text(path):
    return path.read_text(encoding="latin-1")


def write_text(path, text):
    path.write_text(text, encoding="latin-1")


def strip_be300_debug(text):
    lines = text.splitlines(True)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if 'fprintf(stderr, "[be300-' in line or 'qDebug("[be300-' in line:
            while i < len(lines):
                skipped = lines[i]
                i += 1
                if ");" in skipped:
                    break
            continue
        out.append(line)
        i += 1
    return "".join(out)


def original_source(rel):
    for archive in ARCHIVE_CANDIDATES:
        if not archive.exists():
            continue
        with tarfile.open(archive, "r:bz2") as tf:
            extracted = tf.extractfile(f"opie-1.2.5/{rel}")
            if extracted is None:
                continue
            return extracted.read().decode("latin-1")
    return None


def restore_original(rel):
    text = original_source(rel)
    path = ROOT / rel
    if text is None or not path.exists():
        return False
    write_text(path, text)
    return True


def patch_qpeapplication():
    path = ROOT / "library/qpeapplication.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    if "BE300 full-screen main windows" not in text:
        text = text.replace(
            "    static void show_mx(QWidget* mw, bool nomaximize, QString &strName)\n"
            "    {\n",
            "    static void show_mx(QWidget* mw, bool nomaximize, QString &strName)\n"
            "    {\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "        /* BE300 full-screen main windows: keep app content inside\n"
            "           the 240x320 display and above the launcher. */\n"
            "        if ( !nomaximize ) {\n"
            "            mw->setGeometry( qt_maxWindowRect );\n"
            "            mw->showMaximized();\n"
            "            mw->raise();\n"
            "            return;\n"
            "        }\n"
            "#endif\n",
            1,
        )
    write_text(path, text)


def patch_launcher():
    restore_original("core/launcher/launcher.h")
    restore_original("core/launcher/launcher.cpp")

    path = ROOT / "core/launcher/launcher.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))

    if "#include <qevent.h>" not in text:
        text = text.replace("#include <qdir.h>\n", "#include <qdir.h>\n#include <qevent.h>\n", 1)

    text = text.replace(
        "    createDocLoadingWidget();\n"
        "}\n\n"
        "void LauncherTabWidget::createDocLoadingWidget()\n",
        "    Config docCfg( \"Launcher\" );\n"
        "    docCfg.setGroup( \"DocTab\" );\n"
        "    docTabEnabled = docCfg.readBoolEntry( \"Enable\", true );\n"
        "    if ( docTabEnabled )\n"
        "        createDocLoadingWidget();\n"
        "}\n\n"
        "void LauncherTabWidget::createDocLoadingWidget()\n",
        1,
    )

    text = text.replace(
        "void LauncherTabWidget::initLayout()\n"
        "{\n"
        "    layout()->activate();\n"
        "    docView()->setFocus();\n"
        "    categoryBar->showTab(\"Documents\");\n"
        "}\n",
        "void LauncherTabWidget::initLayout()\n"
        "{\n"
        "    layout()->activate();\n"
        "    if ( docView() ) {\n"
        "        docView()->setFocus();\n"
        "        categoryBar->showTab(\"Documents\");\n"
        "    } else if ( categoryBar && categoryBar->count() > 0 ) {\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "        if ( categoryBar->launcherTab( \"Settings\" ) )\n"
        "            categoryBar->showTab( \"Settings\" );\n"
        "#endif\n"
        "        LauncherView *view = categoryBar->currentView();\n"
        "        if ( view ) {\n"
        "            view->setFocus();\n"
        "            stack->raiseWidget( view );\n"
        "        }\n"
        "    }\n"
        "}\n",
        1,
    )

    text = text.replace(
        "void LauncherTabWidget::raiseTabWidget()\n"
        "{\n"
        "    if ( categoryBar->currentView() == docView()\n"
        "         && docLoadingWidgetEnabled ) {\n"
        "        stack->raiseWidget( docLoadingWidget );\n"
        "        docLoadingWidget->updateGeometry();\n"
        "    } else {\n"
        "        stack->raiseWidget( categoryBar->currentView() );\n"
        "    }\n"
        "}\n",
        "void LauncherTabWidget::raiseTabWidget()\n"
        "{\n"
        "    if ( !categoryBar || categoryBar->count() <= 0 )\n"
        "        return;\n"
        "    LauncherView *view = categoryBar->currentView();\n"
        "    if ( !view )\n"
        "        return;\n"
        "    if ( view == docView() && docLoadingWidgetEnabled && docLoadingWidget ) {\n"
        "        stack->raiseWidget( docLoadingWidget );\n"
        "        docLoadingWidget->updateGeometry();\n"
        "    } else {\n"
        "        stack->raiseWidget( view );\n"
        "    }\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( view->iconView() && view->iconView()->viewport() ) {\n"
        "        view->iconView()->viewport()->update();\n"
        "        view->iconView()->viewport()->repaint( FALSE );\n"
        "    }\n"
        "    view->update();\n"
        "#endif\n"
        "}\n",
        1,
    )

    text = text.replace(
        "void LauncherTabWidget::setLoadingProgress( int percent )\n"
        "{\n"
        "    docLoadingWidgetProgress->setProgress( (percent / 4) * 4 );\n"
        "}\n",
        "void LauncherTabWidget::setLoadingProgress( int percent )\n"
        "{\n"
        "    if ( docLoadingWidgetProgress )\n"
        "        docLoadingWidgetProgress->setProgress( (percent / 4) * 4 );\n"
        "}\n",
        1,
    )

    text = text.replace(
        "    QString bgType = cfg.readEntry( \"BackgroundType\", \"Image\" );\n"
        "    if ( bgType == \"Image\" ) { // No tr\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    QString bgType = cfg.readEntry( \"BackgroundType\", \"SolidColor\" );\n"
        "#else\n"
        "    QString bgType = cfg.readEntry( \"BackgroundType\", \"Image\" );\n"
        "#endif\n"
        "    if ( bgType == \"Image\" ) { // No tr\n",
        1,
    )
    text = text.replace(
        "    } else if ( bgType == \"SolidColor\" ) {\n"
        "    QString c = cfg.readEntry( \"BackgroundColor\" );\n"
        "    v->setBackgroundType( LauncherView::SolidColor, c );\n",
        "    } else if ( bgType == \"SolidColor\" ) {\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    QString c = cfg.readEntry( \"BackgroundColor\", \"#d8e7f5\" );\n"
        "#else\n"
        "    QString c = cfg.readEntry( \"BackgroundColor\" );\n"
        "#endif\n"
        "    v->setBackgroundType( LauncherView::SolidColor, c );\n",
        1,
    )

    text = text.replace(
        "        if ( id == \"Documents\" )\n"
        "            docLoadingWidget->setBackgroundType( (LauncherView::BackgroundType)mode, pixmapOrColor );\n",
        "        if ( id == \"Documents\" && docLoadingWidget )\n"
        "            docLoadingWidget->setBackgroundType( (LauncherView::BackgroundType)mode, pixmapOrColor );\n",
        1,
    )
    text = text.replace(
        "        if ( id == \"Documents\" )\n"
        "            docLoadingWidget->setTextColor( QColor(color) );\n",
        "        if ( id == \"Documents\" && docLoadingWidget )\n"
        "            docLoadingWidget->setTextColor( QColor(color) );\n",
        1,
    )

    text = text.replace(
        "void LauncherTabWidget::reCheckDoctab(int how)\n"
        "{\n"
        "    if ((bool)how == docTabEnabled) {\n",
        "void LauncherTabWidget::reCheckDoctab(int how)\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    (void)how;\n"
        "    return;\n"
        "#endif\n"
        "    if ((bool)how == docTabEnabled) {\n",
        1,
    )

    text = text.replace(
        "    // all documents\n"
        "    QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
        "    // It could add this itself if it handles docs\n"
        "    tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n",
        "    // all documents\n"
        "    if ( docTabEnabled ) {\n"
        "        QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
        "        // It could add this itself if it handles docs\n"
        "        tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n"
        "    }\n",
        1,
    )

    text = re.sub(
        r"void Launcher::applicationAdded\( const QString& type, const AppLnk& app \)\n"
        r"\{.*?\n"
        r"\}\n\n"
        r"void Launcher::applicationRemoved",
        "void Launcher::applicationAdded( const QString& type, const AppLnk& app )\n"
        "{\n"
        "    if ( app.type() == \"Separator\" )  // No tr\n"
        "        return;\n"
        "\n"
        "    LauncherView *view = tabs->view( type );\n"
        "    if ( view ) {\n"
        "        view->addItem( new AppLnk( app ), FALSE );\n"
        "    } else {\n"
        "        owarn << \"addAppLnk: No view for type \" << type.latin1()\n"
        "              << \". Can't add app \" << app.name().latin1() << \"!\" << oendl;\n"
        "    }\n"
        "\n"
        "    MimeType::registerApp( app );\n"
        "}\n\n"
        "void Launcher::applicationRemoved",
        text,
        count=1,
        flags=re.S,
    )

    replacements = (
        (
            "void Launcher::documentAdded( const DocLnk& doc )\n"
            "{\n"
            "    tabs->docView()->addItem( new DocLnk( doc ), FALSE );\n"
            "}\n",
            "void Launcher::documentAdded( const DocLnk& doc )\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    tabs->docView()->addItem( new DocLnk( doc ), FALSE );\n"
            "}\n",
        ),
        (
            "void Launcher::aboutToAddBegin()\n"
            "{\n"
            "    tabs->docView()->setUpdatesEnabled( false );\n"
            "}\n",
            "void Launcher::aboutToAddBegin()\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    tabs->docView()->setUpdatesEnabled( false );\n"
            "}\n",
        ),
        (
            "void Launcher::aboutToAddEnd()\n"
            "{\n"
            "    tabs->docView()->setUpdatesEnabled( true );\n"
            "}\n",
            "void Launcher::aboutToAddEnd()\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    tabs->docView()->setUpdatesEnabled( true );\n"
            "}\n",
        ),
        (
            "void Launcher::showLoadingDocs()\n"
            "{\n"
            "    tabs->docView()->hide();\n"
            "}\n",
            "void Launcher::showLoadingDocs()\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    tabs->docView()->hide();\n"
            "}\n",
        ),
        (
            "void Launcher::showDocTab()\n"
            "{\n"
            "    if ( tabs->categoryBar->currentView() == tabs->docView() )\n"
            "    tabs->docView()->show();\n"
            "}\n",
            "void Launcher::showDocTab()\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    if ( tabs->categoryBar->currentView() == tabs->docView() )\n"
            "    tabs->docView()->show();\n"
            "}\n",
        ),
        (
            "void Launcher::documentRemoved( const DocLnk& doc )\n"
            "{\n"
            "    tabs->docView()->removeLink( doc.linkFile() );\n"
            "}\n",
            "void Launcher::documentRemoved( const DocLnk& doc )\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    tabs->docView()->removeLink( doc.linkFile() );\n"
            "}\n",
        ),
        (
            "void Launcher::allDocumentsRemoved()\n"
            "{\n"
            "    tabs->docView()->removeAllItems();\n"
            "}\n",
            "void Launcher::allDocumentsRemoved()\n"
            "{\n"
            "    if ( !tabs || !tabs->docView() )\n"
            "        return;\n"
            "    tabs->docView()->removeAllItems();\n"
            "}\n",
        ),
    )
    for old, new in replacements:
        text = text.replace(old, new, 1)

    text = text.replace(
        "void Launcher::documentChanged( const DocLnk& oldDoc, const DocLnk& newDoc )\n"
        "{\n"
        "#if 0\n",
        "void Launcher::documentChanged( const DocLnk& oldDoc, const DocLnk& newDoc )\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "#if 0\n",
        1,
    )
    text = text.replace(
        "void Launcher::documentScanningProgress( int percent )\n"
        "{\n"
        "    switch ( percent ) {\n",
        "void Launcher::documentScanningProgress( int percent )\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    switch ( percent ) {\n",
        1,
    )

    text = text.replace(
        "void Launcher::typeAdded( const QString& type, const QString& name,\n"
        "                    const QPixmap& pixmap, const QPixmap& )\n"
        "{\n"
        "    tabs->newView( type, pixmap, name );\n"
        "    ids.append( type );\n"
        "    /* this will be called in applicationScanningProgress with value 100! */\n"
        "//    tb->refreshStartMenu();\n"
        "\n"
        "    static bool first = TRUE;\n"
        "    if ( first ) {\n"
        "    first = FALSE;\n"
        "        tabs->categoryBar->showTab(type);\n"
        "    }\n"
        "\n"
        "    tabs->view( type )->setUpdatesEnabled( FALSE );\n"
        "    tabs->view( type )->setSortEnabled( FALSE );\n"
        "}\n",
        "void Launcher::typeAdded( const QString& type, const QString& name,\n"
        "                    const QPixmap& pixmap, const QPixmap& )\n"
        "{\n"
        "    tabs->newView( type, pixmap, name );\n"
        "    ids.append( type );\n"
        "    /* this will be called in applicationScanningProgress with value 100! */\n"
        "//    tb->refreshStartMenu();\n"
        "\n"
        "    static bool first = TRUE;\n"
        "    if ( first ) {\n"
        "    first = FALSE;\n"
        "        tabs->categoryBar->showTab(type);\n"
        "    }\n"
        "\n"
        "    LauncherView *view = tabs->view( type );\n"
        "    if ( view ) {\n"
        "        view->setUpdatesEnabled( FALSE );\n"
        "        view->setSortEnabled( FALSE );\n"
        "    }\n"
        "}\n",
        1,
    )

    text = text.replace(
        "void Launcher::applicationScanningProgress( int percent )\n"
        "{\n"
        "    switch ( percent ) {\n"
        "        case 0: {\n"
        "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
        "        tabs->view( (*it) )->setUpdatesEnabled( FALSE );\n"
        "        tabs->view( (*it) )->setSortEnabled( FALSE );\n"
        "        }\n"
        "        break;\n"
        "        }\n"
        "        case 100: {\n"
        "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
        "        tabs->view( (*it) )->setUpdatesEnabled( TRUE );\n"
        "        tabs->view( (*it) )->setSortEnabled( TRUE );\n"
        "        }\n"
        "            tb->refreshStartMenu();\n"
        "        break;\n"
        "        }\n"
        "        default:\n"
        "            break;\n"
        "    }\n"
        "}\n",
        "void Launcher::applicationScanningProgress( int percent )\n"
        "{\n"
        "    switch ( percent ) {\n"
        "        case 0: {\n"
        "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
        "            LauncherView *view = tabs->view( (*it) );\n"
        "            if ( view ) {\n"
        "                view->setUpdatesEnabled( FALSE );\n"
        "                view->setSortEnabled( FALSE );\n"
        "            }\n"
        "        }\n"
        "        break;\n"
        "        }\n"
        "        case 100: {\n"
        "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
        "            LauncherView *view = tabs->view( (*it) );\n"
        "            if ( view ) {\n"
        "                view->setUpdatesEnabled( TRUE );\n"
        "                view->setSortEnabled( TRUE );\n"
        "            }\n"
        "        }\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "            if ( !ids.isEmpty() ) {\n"
        "                QString firstType = tabs->view( \"Settings\" ) ? QString( \"Settings\" ) : *ids.begin();\n"
        "                tabs->categoryBar->showTab( firstType );\n"
        "                LauncherView *view = tabs->view( firstType );\n"
        "                if ( view ) {\n"
        "                    view->relayout();\n"
        "                    view->show();\n"
        "                    view->setFocus();\n"
        "                    view->update();\n"
        "                    if ( view->iconView() && view->iconView()->viewport() ) {\n"
        "                        view->iconView()->viewport()->update();\n"
        "                        view->iconView()->viewport()->repaint( FALSE );\n"
        "                    }\n"
        "                }\n"
        "            }\n"
        "            tabs->show();\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            update();\n"
        "#endif\n"
        "            tb->refreshStartMenu();\n"
        "        break;\n"
        "        }\n"
        "        default:\n"
        "            break;\n"
        "    }\n"
        "}\n",
        1,
    )

    write_text(path, text)


def patch_launcherview():
    restore_original("core/launcher/launcherview.cpp")

    path = ROOT / "core/launcher/launcherview.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    text = text.replace(
        "void LauncherView::setUpdatesEnabled( bool u )\n"
        "{\n"
        "    icons->setUpdatesEnabled( u );\n"
        "}\n",
        "void LauncherView::setUpdatesEnabled( bool u )\n"
        "{\n"
        "    icons->setUpdatesEnabled( u );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( icons->viewport() ) {\n"
        "        icons->viewport()->setUpdatesEnabled( u );\n"
        "        if ( u ) {\n"
        "            icons->viewport()->update();\n"
        "            icons->viewport()->repaint( FALSE );\n"
        "        }\n"
        "    }\n"
        "    if ( u ) {\n"
        "        icons->update();\n"
        "        update();\n"
        "    }\n"
        "#endif\n"
        "}\n",
        1,
    )
    write_text(path, text)


def patch_launchertab():
    restore_original("core/launcher/launchertab.cpp")

    path = ROOT / "core/launcher/launchertab.cpp"
    if not path.exists():
        return

    text = read_text(path)

    if "BE300 fixed launcher tab geometry" not in text:
        text = text.replace(
            "    setFocusPolicy( NoFocus );\n",
            "    setFocusPolicy( NoFocus );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 fixed launcher tab geometry: the stock compact\n"
            "       layout can assign non-positive widths to inactive tabs\n"
            "       when tab icons are absent. */\n"
            "    setFixedHeight( 22 );\n"
            "#endif\n",
            1,
        )

    if "BE300 visible launcher tabs" not in text:
        text = text.replace(
            "    int available = width()-1;\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    {\n"
            "    /* BE300 visible launcher tabs: use equal positive-width\n"
            "       tabs so every category has a visible click target on\n"
            "       the 240 pixel display. */\n"
            "    QFontMetrics be300fm = fontMetrics();\n"
            "    int hframe, vframe, overlap;\n"
            "    style().tabbarMetrics( this, hframe, vframe, overlap );\n"
            "    int h = QMAX( be300fm.height(), QApplication::globalStrut().height() ) + vframe + 2;\n"
            "    if ( h < 22 )\n"
            "        h = 22;\n"
            "    int x = 0;\n"
            "    int i = 0;\n"
            "    int n = count();\n"
            "    QListIterator< LauncherTab > be300it( items );\n"
            "    for ( be300it.toFirst(); be300it.current(); ++be300it, ++i ) {\n"
            "        LauncherTab *tab = be300it.current();\n"
            "        int w = ( width() - x ) / ( n - i );\n"
            "        if ( w < 1 )\n"
            "            w = 1;\n"
            "        tab->setRect( QRect( x, 0, w, h ) );\n"
            "        x += w;\n"
            "    }\n"
            "    setFixedHeight( h );\n"
            "    update();\n"
            "    return;\n"
            "    }\n"
            "#endif\n"
            "\n"
            "    int available = width()-1;\n",
            1,
        )

    if "BE300 plain launcher tab paint" not in text:
        text = text.replace(
            "    LauncherTabBar *that = (LauncherTabBar *) this;\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    {\n"
            "    /* BE300 plain launcher tab paint: avoid style/theme paths\n"
            "       that can blend tab text into the background on LinuxFb. */\n"
            "    QRect r( t->rect() );\n"
            "    QColor fill = selected ? QColor( 49, 125, 205 ) : QColor( 214, 226, 242 );\n"
            "    QColor border = selected ? QColor( 18, 63, 120 ) : QColor( 126, 146, 172 );\n"
            "    p->fillRect( r, fill );\n"
            "    p->setPen( border );\n"
            "    p->drawRect( r );\n"
            "    QFont f( font() );\n"
            "    f.setBold( selected );\n"
            "    p->setFont( f );\n"
            "    p->setPen( selected ? white : black );\n"
            "    QRect tr( r.left() + 2, r.top() + 1,\n"
            "              r.width() - 4, r.height() - 2 );\n"
            "    p->drawText( tr, AlignCenter | AlignVCenter | ShowPrefix, t->text() );\n"
            "    return;\n"
            "    }\n"
            "#endif\n"
            "\n"
            "    LauncherTabBar *that = (LauncherTabBar *) this;\n",
            1,
        )

    write_text(path, text)


def patch_documentlist():
    restore_original("core/launcher/documentlist.cpp")

    path = ROOT / "core/launcher/documentlist.cpp"
    if path.exists():
        write_text(path, strip_be300_debug(read_text(path)))


def patch_taskbar():
    for rel in (
        "core/launcher/taskbar.cpp",
        "core/launcher/server.cpp",
        "core/launcher/serverapp.cpp",
    ):
        path = ROOT / rel
        if path.exists():
            text = strip_be300_debug(read_text(path))
            if rel == "core/launcher/taskbar.cpp":
                text = text.replace(
                    "#ifndef QT_QWS_CASSIOPEIA\n"
                    "    inputMethods = new InputMethods( this );\n",
                    "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
                    "    inputMethods = new InputMethods( this );\n",
                )
                text = text.replace(
                    "#ifndef QT_QWS_CASSIOPEIA\n"
                    "    waitIcon = new Wait( this );\n",
                    "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
                    "    waitIcon = new Wait( this );\n",
                )
                text = text.replace(
                    "#ifndef QT_QWS_CASSIOPEIA\n"
                    "    (void) new AppIcons( this );\n",
                    "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
                    "    (void) new AppIcons( this );\n",
                )
            if rel == "core/launcher/server.cpp":
                text = text.replace(
                    "void Server::show()\n"
                    "{\n"
                    "#ifdef QT_QWS_CASSIOPEIA\n"
                    "#else\n"
                    "    ServerApplication::login(TRUE);\n"
                    "    QWidget::show();\n"
                    "#endif\n"
                    "}\n",
                    "void Server::show()\n"
                    "{\n"
                    "    ServerApplication::login(TRUE);\n"
                    "    QWidget::show();\n"
                    "}\n",
                    1,
                )
            write_text(path, text)


def patch_opie_application():
    path = ROOT / "libopie2/opiecore/oapplication.cpp"
    if path.exists():
        write_text(path, strip_be300_debug(read_text(path)))


def patch_launcher_main():
    path = ROOT / "core/launcher/main.cpp"
    if not path.exists():
        return

    text = read_text(path)
    text = re.sub(
        r"#define BE300_QPE_STAGE\(s\) do \{ be300_qpe_stage = \(s\); "
        r"(?:fprintf\(stderr, \"\[be300-qpe\].*?fflush\(stderr\);|"
        r"qDebug\(\"\[be300-qpe\].*?) \} while \(0\)",
        "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); } while (0)",
        text,
    )
    text = strip_be300_debug(text)
    if "BE300_QPE_STAGE" in text and "#define BE300_QPE_STAGE" not in text:
        if "be300_qpe_stage" not in text:
            text = text.replace(
                "void create_pidfile();\nvoid remove_pidfile();\n",
                "void create_pidfile();\nvoid remove_pidfile();\n\n"
                "static const char *be300_qpe_stage = \"startup\";\n",
                1,
            )
        text = text.replace(
            "static const char *be300_qpe_stage = \"startup\";\n",
            "static const char *be300_qpe_stage = \"startup\";\n"
            "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); } while (0)\n",
            1,
        )
    write_text(path, text)


def patch_backup():
    for rel in (
        "noncore/settings/backup/backuprestore.h",
        "noncore/settings/backup/backuprestore.cpp",
    ):
        restore_original(rel)
        path = ROOT / rel
        if not path.exists():
            continue

        text = read_text(path).replace("__dev_t", "dev_t")
        if rel.endswith(".h") and "#include <sys/types.h>" not in text:
            text = text.replace(
                "#include <qlist.h>\n#include <sys/stat.h>\n",
                "#include <qlist.h>\n#include <sys/types.h>\n#include <sys/stat.h>\n",
                1,
            )
        write_text(path, text)


def main():
    patch_qpeapplication()
    patch_launcher()
    patch_launcherview()
    patch_launchertab()
    patch_documentlist()
    patch_taskbar()
    patch_opie_application()
    patch_launcher_main()
    patch_backup()


if __name__ == "__main__":
    main()
