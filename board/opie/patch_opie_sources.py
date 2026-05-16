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

    header_path = ROOT / "core/launcher/launcher.h"
    if header_path.exists():
        header = read_text(header_path)
        if "class Be300HomeWidget;" not in header:
            header = header.replace(
                "class QWidgetStack;\nclass TaskBar;\nclass Launcher;\n",
                "class QWidgetStack;\nclass TaskBar;\nclass Launcher;\n"
                "#ifdef QT_QWS_CASSIOPEIA\n"
                "class Be300HomeWidget;\n"
                "#endif\n",
                1,
            )
        if "Be300HomeWidget *be300Home;" not in header:
            header = header.replace(
                "    LauncherTabWidget *tabs;\n"
                "    QStringList ids;\n"
                "    TaskBar *tb;\n\n"
                "    bool docTabEnabled;\n",
                "    LauncherTabWidget *tabs;\n"
                "    QStringList ids;\n"
                "    TaskBar *tb;\n"
                "#ifdef QT_QWS_CASSIOPEIA\n"
                "    Be300HomeWidget *be300Home;\n"
                "#endif\n\n"
                "    bool docTabEnabled;\n",
                1,
            )
        write_text(header_path, header)

    path = ROOT / "core/launcher/launcher.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))

    if "#include <qevent.h>" not in text:
        text = text.replace("#include <qdir.h>\n", "#include <qdir.h>\n#include <qevent.h>\n", 1)
    if "#include <qfile.h>" not in text:
        text = text.replace("#include <qevent.h>\n", "#include <qevent.h>\n#include <qfile.h>\n", 1)
    if "#include <fcntl.h>" not in text:
        text = text.replace("#include <qfile.h>\n", "#include <qfile.h>\n#include <fcntl.h>\n", 1)
    if "#include <unistd.h>" not in text:
        text = text.replace("#include <fcntl.h>\n", "#include <fcntl.h>\n#include <unistd.h>\n", 1)
    if "#include <sys/mman.h>" not in text:
        text = text.replace("#include <fcntl.h>\n", "#include <fcntl.h>\n#include <sys/mman.h>\n", 1)

    if "class Be300HomeButton" not in text:
        text = text.replace(
            "static bool isVisibleWindow( int );\n"
            "//===========================================================================\n\n",
            "static bool isVisibleWindow( int );\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "class Be300HomeButton : public QPushButton\n"
            "{\n"
            "public:\n"
            "    Be300HomeButton( const AppLnk &app, QWidget *parent )\n"
            "        : QPushButton( app.name(), parent ), appLnk( new AppLnk( app ) )\n"
            "    {\n"
            "        setMinimumHeight( 24 );\n"
            "        setFocusPolicy( QWidget::StrongFocus );\n"
            "    }\n"
            "\n"
            "    Be300HomeButton( const QString &file, QWidget *parent )\n"
            "        : QPushButton( QString::null, parent ), appLnk( new AppLnk( file ) )\n"
            "    {\n"
            "        QString title = appLnk->name();\n"
            "        if ( title.isEmpty() )\n"
            "            title = file.mid( file.findRev( '/' ) + 1 );\n"
            "        setText( title );\n"
            "        setMinimumHeight( 24 );\n"
            "        setFocusPolicy( QWidget::StrongFocus );\n"
            "    }\n"
            "\n"
            "    ~Be300HomeButton()\n"
            "    {\n"
            "        delete appLnk;\n"
            "    }\n"
            "\n"
            "    bool valid() const\n"
            "    {\n"
            "        return appLnk && appLnk->isValid() && !appLnk->exec().isEmpty();\n"
            "    }\n"
            "\n"
            "    void executeApp()\n"
            "    {\n"
            "        if ( valid() )\n"
            "            appLnk->execute();\n"
            "    }\n"
            "\n"
            "protected:\n"
            "    void mouseReleaseEvent( QMouseEvent *e )\n"
            "    {\n"
            "        bool inside = rect().contains( e->pos() );\n"
            "        QPushButton::mouseReleaseEvent( e );\n"
            "        if ( inside )\n"
            "            executeApp();\n"
            "    }\n"
            "\n"
            "    void keyReleaseEvent( QKeyEvent *e )\n"
            "    {\n"
            "        if ( e->key() == Qt::Key_Return || e->key() == Qt::Key_Enter ||\n"
            "             e->key() == Qt::Key_Space ) {\n"
            "            executeApp();\n"
            "            e->accept();\n"
            "            return;\n"
            "        }\n"
            "        QPushButton::keyReleaseEvent( e );\n"
            "    }\n"
            "\n"
            "private:\n"
            "    AppLnk *appLnk;\n"
            "};\n"
            "\n"
            "class Be300HomeWidget : public QWidget\n"
            "{\n"
            "public:\n"
            "    Be300HomeWidget( QWidget *parent = 0 )\n"
            "        : QWidget( parent, \"be300Home\" )\n"
            "    {\n"
            "        buttons.setAutoDelete( TRUE );\n"
            "        setBackgroundColor( QColor( 235, 240, 236 ) );\n"
            "        QTimer *heartbeat = new QTimer( this );\n"
            "        connect( heartbeat, SIGNAL(timeout()), this, SLOT(update()) );\n"
            "        heartbeat->start( 500 );\n"
            "        populateDefaultApps();\n"
            "    }\n"
            "\n"
            "    void addApp( const AppLnk &app )\n"
            "    {\n"
            "        if ( app.type() == \"Separator\" || app.exec().isEmpty() )\n"
            "            return;\n"
            "        Be300HomeButton *button = new Be300HomeButton( app, this );\n"
            "        addButton( button );\n"
            "    }\n"
            "\n"
            "    void ensureVisible()\n"
            "    {\n"
            "        layoutButtons();\n"
            "        show();\n"
            "        raise();\n"
            "        repaint( FALSE );\n"
            "    }\n"
            "\n"
            "protected:\n"
            "    void resizeEvent( QResizeEvent * )\n"
            "    {\n"
            "        layoutButtons();\n"
            "    }\n"
            "\n"
            "    void paintEvent( QPaintEvent * )\n"
            "    {\n"
            "        QPainter p( this );\n"
            "        p.fillRect( rect(), QColor( 235, 240, 236 ) );\n"
            "        p.fillRect( 0, 0, width(), 24, QColor( 36, 91, 144 ) );\n"
            "        p.setPen( white );\n"
            "        p.drawText( 7, 17, \"OPIE\" );\n"
            "        p.setPen( QColor( 104, 124, 124 ) );\n"
            "        p.drawLine( 0, 24, width(), 24 );\n"
            "    }\n"
            "\n"
            "private:\n"
            "    void populateDefaultApps()\n"
            "    {\n"
            "        static const char *apps[] = {\n"
            "            \"apps/1Pim/datebook.desktop\",\n"
            "            \"apps/1Pim/addressbook.desktop\",\n"
            "            \"apps/1Pim/todolist.desktop\",\n"
            "            \"apps/1Pim/opie-notes.desktop\",\n"
            "            \"apps/Applications/calculator.desktop\",\n"
            "            \"apps/Applications/textedit.desktop\",\n"
            "            \"apps/Applications/clock.desktop\",\n"
            "            \"apps/Applications/advancedfm.desktop\",\n"
            "            \"apps/Applications/embeddedkonsole.desktop\",\n"
            "            \"apps/Applications/sysinfo.desktop\",\n"
            "            \"apps/Applications/helpbrowser.desktop\",\n"
            "            \"apps/Settings/launchersettings.desktop\",\n"
            "            \"apps/Settings/light-and-power.desktop\",\n"
            "            \"apps/Settings/citytime.desktop\",\n"
            "            0\n"
            "        };\n"
            "        for ( int i = 0; apps[i]; ++i ) {\n"
            "            QString file = QPEApplication::qpeDir() + apps[i];\n"
            "            if ( QFile::exists( file ) ) {\n"
            "                Be300HomeButton *button = new Be300HomeButton( file, this );\n"
            "                addButton( button );\n"
            "            }\n"
            "        }\n"
            "    }\n"
            "\n"
            "    void addButton( Be300HomeButton *button )\n"
            "    {\n"
            "        if ( !button->valid() ) {\n"
            "            delete button;\n"
            "            return;\n"
            "        }\n"
            "        buttons.append( button );\n"
            "        layoutButtons();\n"
            "        button->show();\n"
            "        if ( buttons.count() == 1 )\n"
            "            button->setFocus();\n"
            "    }\n"
            "\n"
            "    void layoutButtons()\n"
            "    {\n"
            "        int n = (int)buttons.count();\n"
            "        if ( n <= 0 || width() <= 0 || height() <= 0 )\n"
            "            return;\n"
            "\n"
            "        int cols = 2;\n"
            "        int margin = 6;\n"
            "        int gap = 4;\n"
            "        int top = 30;\n"
            "        int buttonW = ( width() - margin * 2 - gap ) / cols;\n"
            "        int buttonH = 24;\n"
            "\n"
            "        if ( buttonW < 40 )\n"
            "            buttonW = 40;\n"
            "\n"
            "        int i = 0;\n"
            "        for ( Be300HomeButton *b = buttons.first(); b; b = buttons.next(), ++i ) {\n"
            "            int row = i / cols;\n"
            "            int col = i % cols;\n"
            "            int x = margin + col * ( buttonW + gap );\n"
            "            int y = top + row * ( buttonH + gap );\n"
            "            if ( y + buttonH <= height() - margin ) {\n"
            "                b->setGeometry( x, y, buttonW, buttonH );\n"
            "                b->show();\n"
            "            } else {\n"
            "                b->hide();\n"
            "            }\n"
            "        }\n"
            "    }\n"
            "\n"
            "    QList<Be300HomeButton> buttons;\n"
            "};\n"
            "#endif\n"
            "\n"
            "//===========================================================================\n\n",
            1,
        )

    if "class Be300HomeWidget" not in text:
        home_code = r'''struct Be300HomeEntry
{
    const char *tab;
    const char *label;
    const char *exec;
};

static const Be300HomeEntry be300HomeEntries[] = {
    { "Settings", "Buttons", "buttonsettings" },
    { "Settings", "CityTime", "citytime" },
    { "Settings", "Launcher", "launchersettings" },
    { "Settings", "Power", "light-and-power" },
    { "Settings", "Security", "security" },
    { "Settings", "SysInfo", "sysinfo" },
    { "Applications", "Calc", "calculator" },
    { "Applications", "TextEdit", "textedit" },
    { "Applications", "Clock", "clock" },
    { "Applications", "Files", "advancedfm" },
    { "Applications", "Konsole", "embeddedkonsole" },
    { "Applications", "Help", "helpbrowser" },
    { "1Pim", "Calendar", "datebook" },
    { "1Pim", "Contacts", "addressbook" },
    { "1Pim", "Tasks", "todolist" },
    { "1Pim", "Notes", "opie-notes" },
    { 0, 0, 0 }
};

class Be300HomeWidget : public QWidget
{
public:
    Be300HomeWidget( QWidget *parent = 0 )
        : QWidget( parent, "be300Home" ), currentTab( 1 ),
          selectedItem( 0 ), pressedTab( -1 ), pressedItem( -1 )
    {
        setBackgroundColor( QColor( 216, 231, 245 ) );
        setFocusPolicy( QWidget::StrongFocus );
    }

    void addApp( const QString &, const AppLnk & )
    {
        update();
    }

    void ensureVisible()
    {
        setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );
        show();
        raise();
        setFocus();
        repaint( FALSE );
    }

protected:
    void paintEvent( QPaintEvent * )
    {
        QPainter p( this );
        p.fillRect( rect(), QColor( 216, 231, 245 ) );
        drawTabs( p );
        drawItems( p );
        drawTaskStrip( p );
    }

    void mousePressEvent( QMouseEvent *e )
    {
        pressedTab = tabAt( e->pos() );
        pressedItem = itemAt( e->pos() );
    }

    void mouseReleaseEvent( QMouseEvent *e )
    {
        int t = tabAt( e->pos() );
        int item = itemAt( e->pos() );
        if ( pressedTab >= 0 && pressedTab == t ) {
            currentTab = t;
            selectedItem = 0;
            update();
        } else if ( pressedItem >= 0 && pressedItem == item ) {
            const Be300HomeEntry *entry = visibleEntryAt( item );
            if ( entry && entry->exec )
                Global::execute( entry->exec );
        }
        pressedTab = -1;
        pressedItem = -1;
    }

    void keyReleaseEvent( QKeyEvent *e )
    {
        int n = visibleEntryCount();
        if ( e->key() == Qt::Key_Return || e->key() == Qt::Key_Enter ||
             e->key() == Qt::Key_Space ) {
            const Be300HomeEntry *entry = visibleEntryAt( selectedItem );
            if ( entry && entry->exec )
                Global::execute( entry->exec );
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Left && selectedItem > 0 ) {
            --selectedItem;
            update();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Right && selectedItem + 1 < n ) {
            ++selectedItem;
            update();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Up && selectedItem >= 3 ) {
            selectedItem -= 3;
            update();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Down && selectedItem + 3 < n ) {
            selectedItem += 3;
            update();
            e->accept();
            return;
        }
        QWidget::keyReleaseEvent( e );
    }

private:
    const char *tabName( int tab ) const
    {
        if ( tab == 0 )
            return "Applications";
        if ( tab == 2 )
            return "1Pim";
        return "Settings";
    }

    QString tabLabel( int tab ) const
    {
        if ( tab == 0 )
            return "A";
        if ( tab == 2 )
            return "1";
        return "Settings";
    }

    int tabAt( const QPoint &pos ) const
    {
        if ( pos.y() < 0 || pos.y() > 24 )
            return -1;
        int w = width() / 3;
        int tab = pos.x() / ( w > 0 ? w : 1 );
        return tab >= 0 && tab < 3 ? tab : -1;
    }

    int visibleEntryCount() const
    {
        int count = 0;
        const char *tab = tabName( currentTab );
        for ( int i = 0; be300HomeEntries[i].tab; ++i )
            if ( QString( be300HomeEntries[i].tab ) == tab )
                ++count;
        return count;
    }

    const Be300HomeEntry *visibleEntryAt( int index ) const
    {
        int n = 0;
        const char *tab = tabName( currentTab );
        for ( int i = 0; be300HomeEntries[i].tab; ++i ) {
            if ( QString( be300HomeEntries[i].tab ) != tab )
                continue;
            if ( n == index )
                return &be300HomeEntries[i];
            ++n;
        }
        return 0;
    }

    QRect itemRect( int index ) const
    {
        int cols = 3;
        int margin = 4;
        int top = 30;
        int stripTop = height() - 18;
        int cellW = width() / cols;
        int cellH = 58;
        int row = index / cols;
        int col = index % cols;
        QRect r( col * cellW + margin, top + row * cellH,
                 cellW - margin * 2, cellH - 4 );
        if ( r.bottom() >= stripTop )
            r.setBottom( stripTop - 1 );
        return r;
    }

    int itemAt( const QPoint &pos ) const
    {
        int n = visibleEntryCount();
        for ( int i = 0; i < n; ++i )
            if ( itemRect( i ).contains( pos ) )
                return i;
        return -1;
    }

    void drawTabs( QPainter &p )
    {
        int tabW = width() / 3;
        for ( int i = 0; i < 3; ++i ) {
            QRect r( i * tabW, 0, i == 2 ? width() - i * tabW : tabW, 24 );
            bool active = i == currentTab;
            p.fillRect( r, active ? QColor( 30, 126, 218 ) : QColor( 226, 237, 249 ) );
            p.setPen( QColor( 93, 118, 145 ) );
            p.drawRect( r );
            p.setPen( active ? white : black );
            p.drawText( r, AlignCenter, tabLabel( i ) );
        }
    }

    void drawItems( QPainter &p )
    {
        QFont f = font();
        f.setPointSize( 8 );
        p.setFont( f );
        int n = visibleEntryCount();
        for ( int i = 0; i < n; ++i ) {
            const Be300HomeEntry *entry = visibleEntryAt( i );
            if ( !entry )
                continue;
            QRect r = itemRect( i );
            if ( r.isEmpty() )
                continue;
            if ( i == selectedItem ) {
                p.fillRect( r, QColor( 188, 220, 246 ) );
                p.setPen( QColor( 50, 92, 140 ) );
                p.drawRect( r );
            }
            QRect icon( r.x() + ( r.width() - 28 ) / 2, r.y() + 3, 28, 28 );
            p.setPen( QColor( 45, 93, 151 ) );
            p.setBrush( QColor( 247, 251, 255 ) );
            p.drawRect( icon );
            p.drawText( icon, AlignCenter, QString( entry->label ).left( 1 ) );
            QRect label( r.x(), r.y() + 34, r.width(), r.height() - 34 );
            p.setPen( black );
            p.drawText( label, AlignHCenter | WordBreak, entry->label );
        }
    }

    void drawTaskStrip( QPainter &p )
    {
        int y = height() - 18;
        if ( y <= 24 )
            return;
        p.fillRect( 0, y, width(), height() - y, QColor( 226, 230, 234 ) );
        p.setPen( QColor( 130, 145, 160 ) );
        p.drawLine( 0, y, width(), y );
        p.setPen( black );
        p.drawText( 5, y + 14, "O" );
    }

    int currentTab;
    int selectedItem;
    int pressedTab;
    int pressedItem;
};
'''
        text = text.replace(
            "static QString be300QpeBase()\n",
            home_code + "\nstatic QString be300QpeBase()\n",
            1,
        )

    if "class Be300HomeWidget" not in text:
        home_code = r'''struct Be300HomeEntry
{
    const char *tab;
    const char *label;
    const char *exec;
};

static const Be300HomeEntry be300HomeEntries[] = {
    { "Settings", "Buttons", "buttonsettings" },
    { "Settings", "CityTime", "citytime" },
    { "Settings", "Launcher", "launchersettings" },
    { "Settings", "Power", "light-and-power" },
    { "Settings", "Security", "security" },
    { "Settings", "SysInfo", "sysinfo" },
    { "Applications", "Calc", "calculator" },
    { "Applications", "TextEdit", "textedit" },
    { "Applications", "Clock", "clock" },
    { "Applications", "Files", "advancedfm" },
    { "Applications", "Konsole", "embeddedkonsole" },
    { "Applications", "Help", "helpbrowser" },
    { "1Pim", "Calendar", "datebook" },
    { "1Pim", "Contacts", "addressbook" },
    { "1Pim", "Tasks", "todolist" },
    { "1Pim", "Notes", "opie-notes" },
    { 0, 0, 0 }
};

class Be300HomeWidget : public QWidget
{
public:
    Be300HomeWidget( QWidget *parent = 0 )
        : QWidget( parent, "be300Home" ), currentTab( 1 ), pressedTab( -1 ),
          pressedItem( -1 )
    {
        setBackgroundColor( QColor( 216, 231, 245 ) );
        setFocusPolicy( QWidget::StrongFocus );
    }

    void addApp( const QString &, const AppLnk & ) { update(); }

    void ensureVisible()
    {
        setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );
        show();
        raise();
        setFocus();
        repaint( FALSE );
    }

protected:
    void paintEvent( QPaintEvent * )
    {
        QPainter p( this );
        p.fillRect( rect(), QColor( 216, 231, 245 ) );
        drawTabs( p );
        drawItems( p );
        int y = height() - 18;
        p.fillRect( 0, y, width(), 18, QColor( 226, 230, 234 ) );
        p.setPen( black );
        p.drawText( 5, y + 14, "O" );
    }

    void mousePressEvent( QMouseEvent *e )
    {
        pressedTab = tabAt( e->pos() );
        pressedItem = itemAt( e->pos() );
    }

    void mouseReleaseEvent( QMouseEvent *e )
    {
        int tab = tabAt( e->pos() );
        int item = itemAt( e->pos() );
        if ( pressedTab >= 0 && pressedTab == tab ) {
            currentTab = tab;
            update();
        } else if ( pressedItem >= 0 && pressedItem == item ) {
            const Be300HomeEntry *entry = visibleEntryAt( item );
            if ( entry && entry->exec )
                Global::execute( entry->exec );
        }
        pressedTab = -1;
        pressedItem = -1;
    }

private:
    const char *tabName( int tab ) const
    {
        if ( tab == 0 )
            return "Applications";
        if ( tab == 2 )
            return "1Pim";
        return "Settings";
    }

    QString tabLabel( int tab ) const
    {
        if ( tab == 0 )
            return "A";
        if ( tab == 2 )
            return "1";
        return "Settings";
    }

    int tabAt( const QPoint &pos ) const
    {
        if ( pos.y() < 0 || pos.y() > 24 )
            return -1;
        int w = width() / 3;
        int tab = pos.x() / ( w > 0 ? w : 1 );
        return tab >= 0 && tab < 3 ? tab : -1;
    }

    const Be300HomeEntry *visibleEntryAt( int index ) const
    {
        int n = 0;
        const char *tab = tabName( currentTab );
        for ( int i = 0; be300HomeEntries[i].tab; ++i ) {
            if ( QString( be300HomeEntries[i].tab ) != tab )
                continue;
            if ( n == index )
                return &be300HomeEntries[i];
            ++n;
        }
        return 0;
    }

    int visibleEntryCount() const
    {
        int n = 0;
        const char *tab = tabName( currentTab );
        for ( int i = 0; be300HomeEntries[i].tab; ++i )
            if ( QString( be300HomeEntries[i].tab ) == tab )
                ++n;
        return n;
    }

    QRect itemRect( int index ) const
    {
        int cellW = width() / 3;
        return QRect( ( index % 3 ) * cellW + 4,
                      30 + ( index / 3 ) * 58,
                      cellW - 8, 54 );
    }

    int itemAt( const QPoint &pos ) const
    {
        for ( int i = 0; i < visibleEntryCount(); ++i )
            if ( itemRect( i ).contains( pos ) )
                return i;
        return -1;
    }

    void drawTabs( QPainter &p )
    {
        int tabW = width() / 3;
        for ( int i = 0; i < 3; ++i ) {
            QRect r( i * tabW, 0, i == 2 ? width() - i * tabW : tabW, 24 );
            bool active = i == currentTab;
            p.fillRect( r, active ? QColor( 30, 126, 218 ) : QColor( 226, 237, 249 ) );
            p.setPen( QColor( 93, 118, 145 ) );
            p.drawRect( r );
            p.setPen( active ? white : black );
            p.drawText( r, AlignCenter, tabLabel( i ) );
        }
    }

    void drawItems( QPainter &p )
    {
        QFont f = font();
        f.setPointSize( 8 );
        p.setFont( f );
        for ( int i = 0; i < visibleEntryCount(); ++i ) {
            const Be300HomeEntry *entry = visibleEntryAt( i );
            if ( !entry )
                continue;
            QRect r = itemRect( i );
            QRect icon( r.x() + ( r.width() - 28 ) / 2, r.y() + 3, 28, 28 );
            p.setPen( QColor( 45, 93, 151 ) );
            p.setBrush( QColor( 247, 251, 255 ) );
            p.drawRect( icon );
            p.drawText( icon, AlignCenter, QString( entry->label ).left( 1 ) );
            p.setPen( black );
            p.drawText( QRect( r.x(), r.y() + 34, r.width(), r.height() - 34 ),
                        AlignHCenter | WordBreak, entry->label );
        }
    }

    int currentTab;
    int pressedTab;
    int pressedItem;
};
'''
        text = text.replace(
            "static QString be300QpeBase()\n",
            home_code + "\nstatic QString be300QpeBase()\n",
            1,
        )

    text = text.replace(
        "    createDocLoadingWidget();\n"
        "}\n\n"
        "void LauncherTabWidget::createDocLoadingWidget()\n",
        "    Config docCfg( \"Launcher\" );\n"
        "    docCfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    docTabEnabled = docCfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    docTabEnabled = docCfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n"
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
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( be300Home ) {\n"
        "        be300Home->addApp( app );\n"
        "        be300Home->ensureVisible();\n"
        "    }\n"
        "#endif\n"
        "\n"
        "    QString viewType = type;\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    QString execName = app.exec();\n"
        "    QString linkName = app.linkFile();\n"
        "    if ( linkName.find( \"/Settings/\" ) >= 0 ||\n"
        "         execName == \"launchersettings\" || execName == \"buttonsettings\" ||\n"
        "         execName == \"light-and-power\" || execName == \"citytime\" ||\n"
        "         execName == \"security\" || execName == \"sysinfo\" ||\n"
        "         execName == \"appearance\" || execName == \"backup\" ||\n"
        "         execName == \"systemtime\" || execName == \"language\" ||\n"
        "         execName == \"networksettings\" || execName == \"packagemanager\" ||\n"
        "         execName == \"aqpkg\" || execName == \"calibrate\" || execName == \"quit\" )\n"
        "        viewType = \"Settings\";\n"
        "    else if ( linkName.find( \"/1Pim/\" ) >= 0 ||\n"
        "              execName == \"datebook\" || execName == \"addressbook\" ||\n"
        "              execName == \"todolist\" || execName == \"opie-notes\" )\n"
        "        viewType = \"1Pim\";\n"
        "    else if ( linkName.find( \"/Applications/\" ) >= 0 ||\n"
        "              linkName.find( \"/Unsupported/\" ) >= 0 || type == \"Application\" )\n"
        "        viewType = \"Applications\";\n"
        "#endif\n"
        "\n"
        "    LauncherView *view = tabs->view( viewType );\n"
        "    if ( view ) {\n"
        "        view->addItem( new AppLnk( app ), FALSE );\n"
        "    } else {\n"
        "        owarn << \"addAppLnk: No view for type \" << viewType.latin1()\n"
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
        "            if ( be300Home )\n"
        "                be300Home->ensureVisible();\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            repaint( FALSE );\n"
        "#else\n"
        "            tb->refreshStartMenu();\n"
        "#endif\n"
        "        break;\n"
        "        }\n"
        "        default:\n"
        "            break;\n"
        "    }\n"
        "}\n",
        1,
    )

    text = text.replace(
        "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n"
        "    qApp->setMainWidget( this );\n"
        "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n",
        "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n"
        "    qApp->setMainWidget( this );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( be300Home )\n"
        "        be300Home->ensureVisible();\n"
        "    showMaximized();\n"
        "    raise();\n"
        "#else\n"
        "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
        "#endif\n",
        1,
    )

    text = text.replace(
        "    tabs = 0;\n"
        "    tb = 0;\n",
        "    tabs = 0;\n"
        "    tb = 0;\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    be300Home = 0;\n"
        "#endif\n",
        1,
    )

    text = text.replace(
        "    tb = new TaskBar;\n"
        "    tabs = new LauncherTabWidget( this );\n"
        "    setCentralWidget( tabs );\n",
        "    tb = new TaskBar;\n"
        "    tabs = new LauncherTabWidget( this );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->hide();\n"
        "    be300Home = new Be300HomeWidget( this );\n"
        "    setCentralWidget( be300Home );\n"
        "#else\n"
        "    setCentralWidget( tabs );\n"
        "#endif\n",
        1,
    )

    text = text.replace(
        "void Launcher::destroyGUI()\n"
        "{\n"
        "    delete tb;\n"
        "    tb = 0;\n"
        "    delete tabs;\n"
        "    tabs =0;\n"
        "}\n",
        "void Launcher::destroyGUI()\n"
        "{\n"
        "    delete tb;\n"
        "    tb = 0;\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    delete be300Home;\n"
        "    be300Home = 0;\n"
        "#endif\n"
        "    delete tabs;\n"
        "    tabs =0;\n"
        "}\n",
        1,
    )

    text = text.replace(
        "    cfg.setGroup( \"DocTab\" );\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n",
        "    cfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n",
        2,
    )

    text = text.replace(
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
        "}\n"
        "\n"
        "void Launcher::createGUI()\n",
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n"
        "}\n"
        "\n"
        "void Launcher::createGUI()\n",
        1,
    )

    text = text.replace(
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
        "}\n"
        "\n"
        "void Launcher::createGUI()\n",
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n"
        "}\n"
        "\n"
        "void Launcher::createGUI()\n",
        1,
    )

    text = text.replace(
        " bool Launcher::requiresDocuments() const\n"
        " {\n"
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "    return cfg.readBoolEntry( \"Enable\", true );\n"
        "}\n",
        " bool Launcher::requiresDocuments() const\n"
        " {\n"
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return cfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    return cfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n"
        "}\n",
        1,
    )

    write_text(path, text)


def patch_be300_regular_home_shell():
    path = ROOT / "core/launcher/launcher.cpp"
    if not path.exists():
        return

    text = read_text(path)
    start = text.find("#ifdef QT_QWS_CASSIOPEIA\nclass Be300HomeButton")
    if start < 0:
        start = text.find("#ifdef QT_QWS_CASSIOPEIA\nclass Be300HomeItem")
    if start < 0:
        return
    end_marker = "#endif\n\n//===========================================================================\n\n"
    end = text.find(end_marker, start)
    if end < 0:
        return

    shell_code = r'''#ifdef QT_QWS_CASSIOPEIA
class Be300HomeItem
{
public:
    Be300HomeItem( const QString &tabName, const AppLnk &app )
        : tab( tabName ), appLnk( new AppLnk( app ) )
    {
        loadFromApp();
    }

    Be300HomeItem( const QString &tabName, const QString &file )
        : tab( tabName ), appLnk( new AppLnk( file ) )
    {
        loadFromApp();
        loadFromDesktop( file );
    }

    ~Be300HomeItem()
    {
        delete appLnk;
    }

    bool valid() const
    {
        return !execName.isEmpty();
    }

    QString name() const
    {
        if ( !displayName.isEmpty() )
            return displayName;
        return execName;
    }

    QString exec() const
    {
        return execName;
    }

    QString icon() const
    {
        return iconName;
    }

    void executeApp()
    {
        if ( appLnk && appLnk->isValid() && !appLnk->exec().isEmpty() )
            appLnk->execute();
        else if ( !execName.isEmpty() )
            Global::execute( execName );
    }

    AppLnk *app() const
    {
        return appLnk;
    }

    QString tab;
    QRect rect;

private:
    void loadFromApp()
    {
        if ( !appLnk )
            return;
        if ( execName.isEmpty() )
            execName = appLnk->exec();
        if ( displayName.isEmpty() )
            displayName = appLnk->name();
        if ( iconName.isEmpty() )
            iconName = appLnk->icon();
    }

    void loadFromDesktop( const QString &file )
    {
        QFile desktop( file );
        if ( !desktop.open( IO_ReadOnly ) )
            return;

        QTextStream ts( &desktop );
        while ( !ts.eof() ) {
            QString line = ts.readLine().stripWhiteSpace();
            if ( line.isEmpty() || line[0] == '[' || line[0] == '#' )
                continue;
            int eq = line.find( '=' );
            if ( eq <= 0 )
                continue;
            QString key = line.left( eq );
            QString value = line.mid( eq + 1 ).stripWhiteSpace();
            if ( key == "Exec" && execName.isEmpty() )
                execName = value;
            else if ( key == "Name" && displayName.isEmpty() )
                displayName = value;
            else if ( key == "Icon" && iconName.isEmpty() )
                iconName = value;
        }
    }

    AppLnk *appLnk;
    QString displayName;
    QString execName;
    QString iconName;
};

class Be300HomeWidget : public QWidget
{
public:
    Be300HomeWidget( QWidget *parent = 0 )
        : QWidget( parent, "be300Home" ), pressedItem( -1 ),
          pressedTab( -1 ), selectedItem( 0 ), currentTab( "Settings" )
    {
        items.setAutoDelete( TRUE );
        tabNames.append( "1Pim" );
        tabNames.append( "Applications" );
        tabNames.append( "Settings" );
        setBackgroundColor( QColor( 108, 181, 231 ) );
        setFocusPolicy( QWidget::StrongFocus );
        QTimer *heartbeat = new QTimer( this );
        connect( heartbeat, SIGNAL(timeout()), this, SLOT(update()) );
        heartbeat->start( 500 );
        populateDefaultApps();
    }

    void addApp( const QString &type, const AppLnk &app )
    {
        if ( app.type() == "Separator" || app.exec().isEmpty() )
            return;
        addItem( new Be300HomeItem( normalizeTab( type, app.exec() ), app ) );
    }

    void ensureVisible()
    {
        layoutItems();
        show();
        raise();
        setFocus();
        repaint( FALSE );
    }

protected:
    void resizeEvent( QResizeEvent * )
    {
        layoutItems();
    }

    void paintEvent( QPaintEvent * )
    {
        layoutItems();
        QPainter p( this );
        drawBackground( p );
        drawTabs( p );
        drawItems( p );
        drawTaskStrip( p );
    }

    void mousePressEvent( QMouseEvent *e )
    {
        pressedTab = tabAt( e->pos() );
        pressedItem = itemAt( e->pos() );
        update();
    }

    void mouseReleaseEvent( QMouseEvent *e )
    {
        int tab = tabAt( e->pos() );
        int item = itemAt( e->pos() );
        if ( pressedTab >= 0 && pressedTab == tab ) {
            setCurrentTab( tabNames[tab] );
        } else if ( pressedItem >= 0 && pressedItem == item ) {
            Be300HomeItem *entry = visibleItemAt( item );
            if ( entry )
                entry->executeApp();
        }
        pressedTab = -1;
        pressedItem = -1;
        update();
    }

    void keyReleaseEvent( QKeyEvent *e )
    {
        int count = visibleItemCount();
        if ( count <= 0 ) {
            QWidget::keyReleaseEvent( e );
            return;
        }

        if ( e->key() == Qt::Key_Return || e->key() == Qt::Key_Enter ||
             e->key() == Qt::Key_Space ) {
            Be300HomeItem *entry = visibleItemAt( selectedItem );
            if ( entry )
                entry->executeApp();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Left && selectedItem > 0 ) {
            --selectedItem;
            update();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Right && selectedItem + 1 < count ) {
            ++selectedItem;
            update();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Up && selectedItem >= gridColumns() ) {
            selectedItem -= gridColumns();
            update();
            e->accept();
            return;
        }
        if ( e->key() == Qt::Key_Down && selectedItem + gridColumns() < count ) {
            selectedItem += gridColumns();
            update();
            e->accept();
            return;
        }
        QWidget::keyReleaseEvent( e );
    }

private:
    void populateDefaultApps()
    {
        static const char *defs[][2] = {
            { "Settings", "apps/Settings/appearance.desktop" },
            { "Settings", "apps/Applications/backup.desktop" },
            { "Settings", "apps/Settings/buttonsettings.desktop" },
            { "Settings", "apps/Settings/citytime.desktop" },
            { "Settings", "apps/Settings/systemtime.desktop" },
            { "Settings", "apps/Settings/language.desktop" },
            { "Settings", "apps/Settings/launchersettings.desktop" },
            { "Settings", "apps/Settings/light-and-power.desktop" },
            { "Settings", "apps/Settings/networksettings.desktop" },
            { "Settings", "apps/Settings/packagemanager.desktop" },
            { "Settings", "apps/Settings/aqpkg.desktop" },
            { "Settings", "apps/Settings/calibrate.desktop" },
            { "Settings", "apps/Settings/security.desktop" },
            { "Settings", "apps/Settings/quit.desktop" },
            { "Settings", "apps/Applications/sysinfo.desktop" },
            { "1Pim", "apps/1Pim/datebook.desktop" },
            { "1Pim", "apps/1Pim/addressbook.desktop" },
            { "1Pim", "apps/1Pim/todolist.desktop" },
            { "1Pim", "apps/1Pim/opie-notes.desktop" },
            { "Applications", "apps/Applications/calculator.desktop" },
            { "Applications", "apps/Applications/textedit.desktop" },
            { "Applications", "apps/Applications/clock.desktop" },
            { "Applications", "apps/Applications/advancedfm.desktop" },
            { "Applications", "apps/Applications/embeddedkonsole.desktop" },
            { "Applications", "apps/Applications/helpbrowser.desktop" },
            { "Applications", "apps/Unsupported/ubrowser.desktop" },
            { 0, 0 }
        };

        QString base = QPEApplication::qpeDir();
        if ( base.isEmpty() || base == "../" )
            base = "/opt/QtPalmtop/";
        else if ( base.right( 1 ) != "/" )
            base += "/";

        for ( int i = 0; defs[i][0]; ++i ) {
            QString file = base + defs[i][1];
            if ( QFile::exists( file ) )
                addItem( new Be300HomeItem( defs[i][0], file ) );
        }
    }

    QString normalizeTab( const QString &type, const QString &exec ) const
    {
        if ( type == "Settings" )
            return "Settings";
        if ( type == "1Pim" || type == "Pim" )
            return "1Pim";
        if ( exec == "launchersettings" || exec == "buttonsettings" ||
             exec == "light-and-power" || exec == "citytime" ||
             exec == "security" || exec == "sysinfo" )
            return "Settings";
        if ( exec == "datebook" || exec == "addressbook" ||
             exec == "todolist" || exec == "opie-notes" )
            return "1Pim";
        return "Applications";
    }

    bool containsExec( const QString &exec ) const
    {
        if ( exec.isEmpty() )
            return FALSE;
        for ( Be300HomeItem *item = items.first(); item; item = items.next() ) {
            if ( item->exec() == exec )
                return TRUE;
        }
        return FALSE;
    }

    void addItem( Be300HomeItem *item )
    {
        if ( !item || !item->valid() || containsExec( item->exec() ) ) {
            delete item;
            return;
        }
        items.append( item );
        layoutItems();
        update();
    }

    int gridColumns() const
    {
        return 3;
    }

    int contentTop() const
    {
        return 30;
    }

    int taskStripTop() const
    {
        return height() - 20;
    }

    void layoutItems()
    {
        int cols = gridColumns();
        int tileW = width() / cols;
        int tileH = 56;
        int top = contentTop() + 3;
        int i = 0;

        for ( Be300HomeItem *item = items.first(); item; item = items.next() ) {
            if ( item->tab != currentTab ) {
                item->rect = QRect();
                continue;
            }
            int row = i / cols;
            int col = i % cols;
            item->rect = QRect( col * tileW, top + row * tileH, tileW, tileH );
            ++i;
        }
        if ( selectedItem >= i )
            selectedItem = i > 0 ? i - 1 : 0;
    }

    void drawBackground( QPainter &p )
    {
        p.fillRect( rect(), QColor( 104, 178, 231 ) );
        p.setPen( QColor( 181, 220, 247 ) );
        p.drawArc( -36, 34, 196, 96, 0, 360 * 16 );
        p.drawArc( 36, 22, 172, 150, 0, 360 * 16 );
        p.drawArc( 90, 92, 188, 88, 0, 360 * 16 );
        p.setPen( white );
        p.drawArc( -8, 76, 166, 38, 10 * 16, 220 * 16 );
        p.drawArc( 58, 138, 190, 58, 190 * 16, 230 * 16 );
        p.setPen( QColor( 151, 206, 244 ) );
        p.drawLine( 12, 246, width() - 16, 190 );
        p.drawLine( 34, 42, width() - 22, 250 );
    }

    void drawTabs( QPainter &p )
    {
        p.fillRect( 0, 0, width(), 24, QColor( 86, 151, 205 ) );
        p.setPen( QColor( 42, 80, 126 ) );
        p.drawLine( 0, 23, width(), 23 );

        for ( unsigned int i = 0; i < tabNames.count(); ++i ) {
            QRect r = tabRect( i );
            bool active = tabNames[i] == currentTab;
            p.fillRect( r, active ? QColor( 154, 202, 238 ) : QColor( 104, 169, 220 ) );
            p.setPen( active ? QColor( 20, 50, 90 ) : QColor( 68, 113, 163 ) );
            p.drawRect( r );
            p.setPen( black );
            if ( active )
                p.drawText( r, AlignCenter, tabNames[i] );
            else
                p.drawText( r, AlignCenter, tabNames[i].left( 1 ) );
        }
    }

    QRect tabRect( int i ) const
    {
        int x = i == 0 ? 0 : ( i == 1 ? 28 : 56 );
        int w = i == 2 ? width() - x : 28;
        return QRect( x, 0, w, 24 );
    }

    int tabAt( const QPoint &pos ) const
    {
        for ( unsigned int i = 0; i < tabNames.count(); ++i ) {
            if ( tabRect( i ).contains( pos ) )
                return (int)i;
        }
        return -1;
    }

    void setCurrentTab( const QString &tab )
    {
        if ( currentTab == tab )
            return;
        currentTab = tab;
        selectedItem = 0;
        layoutItems();
    }

    void drawItems( QPainter &p )
    {
        QFont small = font();
        small.setPointSize( 8 );
        p.setFont( small );
        QFontMetrics fm( small );
        int i = 0;

        for ( Be300HomeItem *item = items.first(); item; item = items.next() ) {
            if ( item->tab != currentTab || item->rect.isNull() )
                continue;

            QRect r = item->rect;
            bool pressed = i == pressedItem;
            bool selected = hasFocus() && i == selectedItem;
            if ( pressed )
                p.fillRect( r.x() + 4, r.y() + 2, r.width() - 8, r.height() - 4,
                            QColor( 186, 220, 246 ) );
            if ( selected ) {
                p.setPen( QColor( 20, 80, 140 ) );
                p.drawRect( r.x() + 3, r.y() + 2, r.width() - 7, r.height() - 5 );
            }

            QPixmap pm;
            if ( item->app() && item->app()->isValid() )
                pm = item->app()->bigPixmap();
            if ( pm.isNull() && !item->icon().isEmpty() )
                pm = OResource::loadPixmap( item->icon(), OResource::BigIcon );
            int iconX = r.x() + ( r.width() - 32 ) / 2;
            int iconY = r.y() + 2;
            if ( !pm.isNull() ) {
                int px = r.x() + ( r.width() - pm.width() ) / 2;
                p.drawPixmap( px, iconY, pm );
            } else {
                p.setPen( QColor( 45, 93, 151 ) );
                p.setBrush( QColor( 236, 246, 255 ) );
                p.drawRect( iconX, iconY, 31, 31 );
                p.setPen( QColor( 45, 93, 151 ) );
                p.drawText( QRect( iconX, iconY, 32, 32 ), AlignCenter,
                            item->name().left( 1 ) );
            }

            QRect label( r.x() + 2, r.y() + 35, r.width() - 4, r.height() - 35 );
            p.setPen( white );
            p.drawText( label.x() + 1, label.y() + 1, label.width(), label.height(),
                        AlignHCenter | WordBreak, item->name() );
            p.setPen( black );
            p.drawText( label, AlignHCenter | WordBreak, item->name() );
            ++i;
        }

        if ( i == 0 ) {
            p.setPen( black );
            p.drawText( QRect( 0, contentTop(), width(), taskStripTop() - contentTop() ),
                        AlignCenter | WordBreak, tr( "No applications" ) );
        }
    }

    void drawTaskStrip( QPainter &p )
    {
        int y = taskStripTop();
        if ( y <= contentTop() )
            return;
        p.fillRect( 0, y, width(), height() - y, QColor( 224, 231, 235 ) );
        p.setPen( QColor( 132, 146, 158 ) );
        p.drawLine( 0, y, width(), y );
        p.setPen( QColor( 40, 92, 156 ) );
        p.drawText( 4, y + 15, "O" );
        p.setPen( black );
        p.drawText( width() - 43, y + 15, "1:08" );
    }

    int visibleItemCount() const
    {
        int count = 0;
        for ( Be300HomeItem *item = items.first(); item; item = items.next() ) {
            if ( item->tab == currentTab )
                ++count;
        }
        return count;
    }

    Be300HomeItem *visibleItemAt( int index ) const
    {
        int i = 0;
        for ( Be300HomeItem *item = items.first(); item; item = items.next() ) {
            if ( item->tab != currentTab )
                continue;
            if ( i == index )
                return item;
            ++i;
        }
        return 0;
    }

    int itemAt( const QPoint &pos ) const
    {
        int i = 0;
        for ( Be300HomeItem *item = items.first(); item; item = items.next() ) {
            if ( item->tab != currentTab )
                continue;
            if ( item->rect.contains( pos ) )
                return i;
            ++i;
        }
        return -1;
    }

    QList<Be300HomeItem> items;
    QStringList tabNames;
    int pressedItem;
    int pressedTab;
    int selectedItem;
    QString currentTab;
};
#endif

//===========================================================================

'''
    text = text[:start] + shell_code + text[end + len(end_marker):]
    text = text.replace(
        "    if ( be300Home ) {\n"
        "        be300Home->addApp( app );\n",
        "    if ( be300Home ) {\n"
        "        be300Home->addApp( type, app );\n",
        1,
    )
    write_text(path, text)


def patch_regular_launcher_shell():
    restore_original("core/launcher/launcher.h")
    restore_original("core/launcher/launcher.cpp")

    hpath = ROOT / "core/launcher/launcher.h"
    if hpath.exists():
        htext = read_text(hpath)
        if "class Be300HomeWidget;" not in htext:
            htext = htext.replace(
                "class QWidgetStack;\nclass TaskBar;\nclass Launcher;\n",
                "class QWidgetStack;\nclass TaskBar;\nclass Launcher;\n"
                "#ifdef QT_QWS_CASSIOPEIA\n"
                "class Be300HomeWidget;\n"
                "#endif\n",
                1,
            )
        htext = htext.replace(
            "    void makeVisible();\n",
            "    void makeVisible();\n"
            "    void be300PopulateLauncher();\n",
            1,
        )
        htext = htext.replace(
            "protected slots:\n"
            "    void raiseTabWidget();\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "public slots:\n"
            "    void raiseTabWidget();\n"
            "protected slots:\n"
            "#else\n"
            "protected slots:\n"
            "    void raiseTabWidget();\n"
            "#endif\n",
            1,
        )
        if "Be300HomeWidget *be300Home;" not in htext:
            htext = htext.replace(
                "    LauncherTabWidget *tabs;\n"
                "    QStringList ids;\n"
                "    TaskBar *tb;\n\n"
                "    bool docTabEnabled;\n",
                "    LauncherTabWidget *tabs;\n"
                "    QStringList ids;\n"
                "    TaskBar *tb;\n"
                "#ifdef QT_QWS_CASSIOPEIA\n"
                "    Be300HomeWidget *be300Home;\n"
                "#endif\n\n"
                "    bool docTabEnabled;\n",
                1,
            )
        write_text(hpath, htext)

    path = ROOT / "core/launcher/launcher.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    if "#include <qevent.h>" not in text:
        text = text.replace("#include <qdir.h>\n", "#include <qdir.h>\n#include <qevent.h>\n", 1)
    if "#include <qfile.h>" not in text:
        text = text.replace("#include <qevent.h>\n", "#include <qevent.h>\n#include <qfile.h>\n", 1)
    if "#include <fcntl.h>" not in text:
        text = text.replace("#include <qfile.h>\n", "#include <qfile.h>\n#include <fcntl.h>\n", 1)
    if "#include <unistd.h>" not in text:
        text = text.replace("#include <fcntl.h>\n", "#include <fcntl.h>\n#include <unistd.h>\n", 1)
    if "#include <sys/mman.h>" not in text:
        text = text.replace("#include <fcntl.h>\n", "#include <fcntl.h>\n#include <sys/mman.h>\n", 1)

    if "be300PopulateLauncherDefaults" not in text:
        text = text.replace(
            "static bool isVisibleWindow( int );\n"
            "//===========================================================================\n\n",
            "static bool isVisibleWindow( int );\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "static bool be300LauncherDefaultsPopulated = FALSE;\n"
            "static volatile unsigned char *be300LauncherUart = 0;\n"
            "enum {\n"
            "    BE300_LAUNCHER_UART_PHYS = 0x0a008000,\n"
            "    BE300_LAUNCHER_UART_MAP_SIZE = 0x1000,\n"
            "    BE300_LAUNCHER_UART_MAP_OFF = 0x680,\n"
            "    BE300_LAUNCHER_UART_THR = 0x00,\n"
            "    BE300_LAUNCHER_UART_LSR = 0x05,\n"
            "    BE300_LAUNCHER_UART_LSR_THRE = 0x20\n"
            "};\n"
            "\n"
            "static void be300LauncherUartInit()\n"
            "{\n"
            "    if ( be300LauncherUart )\n"
            "        return;\n"
            "    int fd = ::open( \"/dev/mem\", O_RDWR | O_SYNC );\n"
            "    if ( fd < 0 )\n"
            "        return;\n"
            "    void *map = ::mmap( 0, BE300_LAUNCHER_UART_MAP_SIZE,\n"
            "                        PROT_READ | PROT_WRITE, MAP_SHARED,\n"
            "                        fd, BE300_LAUNCHER_UART_PHYS );\n"
            "    ::close( fd );\n"
            "    if ( map == MAP_FAILED )\n"
            "        return;\n"
            "    be300LauncherUart = (volatile unsigned char *)map + BE300_LAUNCHER_UART_MAP_OFF;\n"
            "}\n"
            "\n"
            "static void be300LauncherPutc( char c )\n"
            "{\n"
            "    be300LauncherUartInit();\n"
            "    if ( !be300LauncherUart )\n"
            "        return;\n"
            "    if ( c == '\\n' )\n"
            "        be300LauncherPutc( '\\r' );\n"
            "    for ( int i = 0; i < 1000000; ++i ) {\n"
            "        if ( be300LauncherUart[BE300_LAUNCHER_UART_LSR] & BE300_LAUNCHER_UART_LSR_THRE )\n"
            "            break;\n"
            "    }\n"
            "    be300LauncherUart[BE300_LAUNCHER_UART_THR] = (unsigned char)c;\n"
            "}\n"
            "\n"
            "static void be300LauncherWrite( const char *s )\n"
            "{\n"
            "    while ( s && *s )\n"
            "        be300LauncherPutc( *s++ );\n"
            "}\n"
            "\n"
            "static void be300LauncherLog( const char *tag, const char *value = 0 )\n"
            "{\n"
            "    (void)tag;\n"
            "    (void)value;\n"
            "}\n"
            "\n"
            "static QString be300QpeBase()\n"
            "{\n"
            "    QStringList bases;\n"
            "    QString qpe = QPEApplication::qpeDir();\n"
            "    if ( !qpe.isEmpty() ) {\n"
            "        if ( qpe.right( 1 ) != \"/\" )\n"
            "            qpe += \"/\";\n"
            "        bases.append( qpe );\n"
            "    }\n"
            "    const char *env = getenv( \"OPIEDIR\" );\n"
            "    if ( env && *env ) {\n"
            "        QString opie = QString( env ).stripWhiteSpace();\n"
            "        if ( !opie.isEmpty() ) {\n"
            "            if ( opie.right( 1 ) != \"/\" )\n"
            "                opie += \"/\";\n"
            "            bases.append( opie );\n"
            "        }\n"
            "    }\n"
            "    bases.append( \"/opt/QtPalmtop/\" );\n"
            "\n"
            "    for ( QStringList::Iterator it = bases.begin(); it != bases.end(); ++it ) {\n"
            "        if ( QFile::exists( *it + \"apps\" ) ) {\n"
            "            be300LauncherLog( \"base\", (*it).latin1() );\n"
            "            return *it;\n"
            "        }\n"
            "    }\n"
            "    be300LauncherLog( \"base\", \"/opt/QtPalmtop/\" );\n"
            "    return \"/opt/QtPalmtop/\";\n"
            "}\n"
            "\n"
            "static LauncherView *be300EnsureLauncherView( LauncherTabWidget *tabs,\n"
            "                                              QStringList *ids,\n"
            "                                              const QString &id,\n"
            "                                              const QString &label )\n"
            "{\n"
            "    LauncherView *view = tabs->view( id );\n"
            "    if ( view ) {\n"
            "        if ( ids && !ids->contains( id ) )\n"
            "            ids->append( id );\n"
            "        return view;\n"
            "    }\n"
            "\n"
            "    QPixmap pm;\n"
            "    view = tabs->newView( id, pm, label );\n"
            "    if ( view ) {\n"
            "        if ( ids && !ids->contains( id ) )\n"
            "            ids->append( id );\n"
            "        view->setUpdatesEnabled( FALSE );\n"
            "        view->setSortEnabled( FALSE );\n"
            "    }\n"
            "    return view;\n"
            "}\n"
            "\n"
            "static void be300AddLauncherApp( LauncherTabWidget *tabs, const QString &base,\n"
            "                                 const QString &type, const QString &rel )\n"
            "{\n"
            "    LauncherView *view = tabs->view( type );\n"
            "    if ( !view ) {\n"
            "        be300LauncherLog( \"no-view\", type.latin1() );\n"
            "        return;\n"
            "    }\n"
            "\n"
            "    QString file = base + rel;\n"
            "    if ( !QFile::exists( file ) ) {\n"
            "        be300LauncherLog( \"missing\", rel.latin1() );\n"
            "        return;\n"
            "    }\n"
            "\n"
            "    AppLnk *lnk = new AppLnk( file );\n"
            "    if ( lnk->exec().isEmpty() ) {\n"
            "        be300LauncherLog( \"empty-exec\", rel.latin1() );\n"
            "        delete lnk;\n"
            "        return;\n"
            "    }\n"
            "\n"
            "    MimeType::registerApp( *lnk );\n"
            "    view->addItem( lnk, FALSE );\n"
            "    be300LauncherLog( \"added\", rel.latin1() );\n"
            "}\n"
            "\n"
            "static void be300RefreshLauncherView( LauncherView *view )\n"
            "{\n"
            "    if ( !view )\n"
            "        return;\n"
            "    view->show();\n"
            "    view->raise();\n"
            "    if ( view->layout() )\n"
            "        view->layout()->activate();\n"
            "    if ( view->iconView() && view->iconView()->viewport() ) {\n"
            "        QIconView *iv = view->iconView();\n"
            "        int iw = view->width();\n"
            "        int ih = view->height();\n"
            "        if ( iw <= 0 )\n"
            "            iw = QApplication::desktop()->width();\n"
            "        if ( ih <= 0 )\n"
            "            ih = QApplication::desktop()->height() - 22;\n"
            "        iv->setGeometry( 0, 0, iw, ih );\n"
            "        iv->viewport()->setGeometry( 0, 0, iw, ih );\n"
            "        iv->show();\n"
            "        iv->viewport()->show();\n"
            "        iv->setContentsPos( 0, 0 );\n"
            "        iv->arrangeItemsInGrid( FALSE );\n"
            "        iv->viewport()->update();\n"
            "        iv->viewport()->repaint( FALSE );\n"
            "        iv->update();\n"
            "    }\n"
            "    view->update();\n"
            "}\n"
            "\n"
            "static void be300PopulateLauncherDefaults( LauncherTabWidget *tabs,\n"
            "                                           QStringList *ids )\n"
            "{\n"
            "    if ( !tabs || be300LauncherDefaultsPopulated )\n"
            "        return;\n"
            "    be300LauncherLog( \"populate\" );\n"
            "\n"
            "    static const char *defs[][2] = {\n"
            "        { \"Settings\", \"apps/Settings/appearance.desktop\" },\n"
            "        { \"Settings\", \"apps/Applications/backup.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/buttonsettings.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/citytime.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/systemtime.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/language.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/launchersettings.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/light-and-power.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/networksettings.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/packagemanager.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/aqpkg.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/calibrate.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/security.desktop\" },\n"
            "        { \"Settings\", \"apps/Settings/quit.desktop\" },\n"
            "        { \"Settings\", \"apps/Applications/sysinfo.desktop\" },\n"
            "        { \"1Pim\", \"apps/1Pim/datebook.desktop\" },\n"
            "        { \"1Pim\", \"apps/1Pim/addressbook.desktop\" },\n"
            "        { \"1Pim\", \"apps/1Pim/todolist.desktop\" },\n"
            "        { \"1Pim\", \"apps/1Pim/opie-notes.desktop\" },\n"
            "        { \"Applications\", \"apps/Applications/calculator.desktop\" },\n"
            "        { \"Applications\", \"apps/Applications/textedit.desktop\" },\n"
            "        { \"Applications\", \"apps/Applications/clock.desktop\" },\n"
            "        { \"Applications\", \"apps/Applications/advancedfm.desktop\" },\n"
            "        { \"Applications\", \"apps/Applications/embeddedkonsole.desktop\" },\n"
            "        { \"Applications\", \"apps/Applications/helpbrowser.desktop\" },\n"
            "        { \"Applications\", \"apps/Unsupported/ubrowser.desktop\" },\n"
            "        { 0, 0 }\n"
            "    };\n"
            "\n"
            "    QString base = be300QpeBase();\n"
            "    be300EnsureLauncherView( tabs, ids, \"1Pim\", \"1\" );\n"
            "    be300EnsureLauncherView( tabs, ids, \"Applications\", \"A\" );\n"
            "    be300EnsureLauncherView( tabs, ids, \"Settings\", \"Settings\" );\n"
            "\n"
            "    for ( int i = 0; defs[i][0]; ++i )\n"
            "        be300AddLauncherApp( tabs, base, defs[i][0], defs[i][1] );\n"
            "\n"
            "    const char *defaultIds[] = { \"1Pim\", \"Applications\", \"Settings\", 0 };\n"
            "    for ( int i = 0; defaultIds[i]; ++i ) {\n"
            "        LauncherView *view = tabs->view( defaultIds[i] );\n"
            "        if ( view ) {\n"
            "            view->setUpdatesEnabled( TRUE );\n"
            "            view->setSortEnabled( TRUE );\n"
            "            be300RefreshLauncherView( view );\n"
            "            view->update();\n"
            "        }\n"
            "    }\n"
            "\n"
            "    if ( tabs->categoryBar->launcherTab( \"Settings\" ) )\n"
            "        tabs->categoryBar->showTab( \"Settings\" );\n"
            "    tabs->raiseTabWidget();\n"
            "    tabs->hide();\n"
            "    be300LauncherDefaultsPopulated = TRUE;\n"
            "}\n"
            "#endif\n"
            "\n"
            "//===========================================================================\n\n",
            1,
        )

    if "class Be300HomeWidget" not in text:
        home_code = r'''struct Be300HomeEntry
{
    const char *tab;
    const char *label;
    const char *exec;
};

static const Be300HomeEntry be300HomeEntries[] = {
    { "Settings", "Buttons", "buttonsettings" },
    { "Settings", "CityTime", "citytime" },
    { "Settings", "Launcher", "launchersettings" },
    { "Settings", "Power", "light-and-power" },
    { "Settings", "Security", "security" },
    { "Settings", "SysInfo", "sysinfo" },
    { "Applications", "Calc", "calculator" },
    { "Applications", "TextEdit", "textedit" },
    { "Applications", "Clock", "clock" },
    { "Applications", "Files", "advancedfm" },
    { "Applications", "Konsole", "embeddedkonsole" },
    { "Applications", "Help", "helpbrowser" },
    { "1Pim", "Calendar", "datebook" },
    { "1Pim", "Contacts", "addressbook" },
    { "1Pim", "Tasks", "todolist" },
    { "1Pim", "Notes", "opie-notes" },
    { 0, 0, 0 }
};

class Be300HomeWidget : public QWidget
{
public:
    Be300HomeWidget( QWidget *parent = 0 )
        : QWidget( parent, "be300Home" ), currentTab( 1 ), pressedTab( -1 ),
          pressedItem( -1 )
    {
        setBackgroundColor( QColor( 216, 231, 245 ) );
        setFocusPolicy( QWidget::StrongFocus );
    }

    void addApp( const QString &, const AppLnk & ) { update(); }

    void ensureVisible()
    {
        setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );
        show();
        raise();
        setFocus();
        repaint( FALSE );
    }

protected:
    void paintEvent( QPaintEvent * )
    {
        QPainter p( this );
        p.fillRect( rect(), QColor( 216, 231, 245 ) );
        drawTabs( p );
        drawItems( p );
        int y = height() - 18;
        p.fillRect( 0, y, width(), 18, QColor( 226, 230, 234 ) );
        p.setPen( black );
        p.drawText( 5, y + 14, "O" );
    }

    void mousePressEvent( QMouseEvent *e )
    {
        pressedTab = tabAt( e->pos() );
        pressedItem = itemAt( e->pos() );
    }

    void mouseReleaseEvent( QMouseEvent *e )
    {
        int tab = tabAt( e->pos() );
        int item = itemAt( e->pos() );
        if ( pressedTab >= 0 && pressedTab == tab ) {
            currentTab = tab;
            update();
        } else if ( pressedItem >= 0 && pressedItem == item ) {
            const Be300HomeEntry *entry = visibleEntryAt( item );
            if ( entry && entry->exec )
                Global::execute( entry->exec );
        }
        pressedTab = -1;
        pressedItem = -1;
    }

private:
    const char *tabName( int tab ) const
    {
        if ( tab == 0 )
            return "Applications";
        if ( tab == 2 )
            return "1Pim";
        return "Settings";
    }

    QString tabLabel( int tab ) const
    {
        if ( tab == 0 )
            return "A";
        if ( tab == 2 )
            return "1";
        return "Settings";
    }

    int tabAt( const QPoint &pos ) const
    {
        if ( pos.y() < 0 || pos.y() > 24 )
            return -1;
        int w = width() / 3;
        int tab = pos.x() / ( w > 0 ? w : 1 );
        return tab >= 0 && tab < 3 ? tab : -1;
    }

    const Be300HomeEntry *visibleEntryAt( int index ) const
    {
        int n = 0;
        const char *tab = tabName( currentTab );
        for ( int i = 0; be300HomeEntries[i].tab; ++i ) {
            if ( QString( be300HomeEntries[i].tab ) != tab )
                continue;
            if ( n == index )
                return &be300HomeEntries[i];
            ++n;
        }
        return 0;
    }

    int visibleEntryCount() const
    {
        int n = 0;
        const char *tab = tabName( currentTab );
        for ( int i = 0; be300HomeEntries[i].tab; ++i )
            if ( QString( be300HomeEntries[i].tab ) == tab )
                ++n;
        return n;
    }

    QRect itemRect( int index ) const
    {
        int cellW = width() / 3;
        return QRect( ( index % 3 ) * cellW + 4,
                      30 + ( index / 3 ) * 58,
                      cellW - 8, 54 );
    }

    int itemAt( const QPoint &pos ) const
    {
        for ( int i = 0; i < visibleEntryCount(); ++i )
            if ( itemRect( i ).contains( pos ) )
                return i;
        return -1;
    }

    void drawTabs( QPainter &p )
    {
        int tabW = width() / 3;
        for ( int i = 0; i < 3; ++i ) {
            QRect r( i * tabW, 0, i == 2 ? width() - i * tabW : tabW, 24 );
            bool active = i == currentTab;
            p.fillRect( r, active ? QColor( 30, 126, 218 ) : QColor( 226, 237, 249 ) );
            p.setPen( QColor( 93, 118, 145 ) );
            p.drawRect( r );
            p.setPen( active ? white : black );
            p.drawText( r, AlignCenter, tabLabel( i ) );
        }
    }

    void drawItems( QPainter &p )
    {
        QFont f = font();
        f.setPointSize( 8 );
        p.setFont( f );
        for ( int i = 0; i < visibleEntryCount(); ++i ) {
            const Be300HomeEntry *entry = visibleEntryAt( i );
            if ( !entry )
                continue;
            QRect r = itemRect( i );
            QRect icon( r.x() + ( r.width() - 28 ) / 2, r.y() + 3, 28, 28 );
            p.setPen( QColor( 45, 93, 151 ) );
            p.setBrush( QColor( 247, 251, 255 ) );
            p.drawRect( icon );
            p.drawText( icon, AlignCenter, QString( entry->label ).left( 1 ) );
            p.setPen( black );
            p.drawText( QRect( r.x(), r.y() + 34, r.width(), r.height() - 34 ),
                        AlignHCenter | WordBreak, entry->label );
        }
    }

    int currentTab;
    int pressedTab;
    int pressedItem;
};
'''
        text = text.replace(
            "static QString be300QpeBase()\n",
            home_code + "\nstatic QString be300QpeBase()\n",
            1,
        )

    text = text.replace(
        "    createDocLoadingWidget();\n"
        "}\n\n"
        "void LauncherTabWidget::createDocLoadingWidget()\n",
        "    Config docCfg( \"Launcher\" );\n"
        "    docCfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    docTabEnabled = docCfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    docTabEnabled = docCfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n"
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
        "    int be300w = width() > 0 ? width() : QApplication::desktop()->width();\n"
        "    int be300h = height() > 0 ? height() : QApplication::desktop()->height();\n"
        "    int be300tabh = categoryBar->height() > 0 ? categoryBar->height() : 22;\n"
        "    if ( be300tabh < 22 )\n"
        "        be300tabh = 22;\n"
        "    categoryBar->setGeometry( 0, 0, be300w, be300tabh );\n"
        "    if ( stack ) {\n"
        "        stack->setGeometry( 0, be300tabh, be300w, be300h - be300tabh );\n"
        "        view->setGeometry( 0, 0, stack->width(), stack->height() );\n"
        "    }\n"
        "    be300RefreshLauncherView( view );\n"
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

    for old, new in (
        (
            "        if ( id == \"Documents\" )\n"
            "            docLoadingWidget->setBackgroundType( (LauncherView::BackgroundType)mode, pixmapOrColor );\n",
            "        if ( id == \"Documents\" && docLoadingWidget )\n"
            "            docLoadingWidget->setBackgroundType( (LauncherView::BackgroundType)mode, pixmapOrColor );\n",
        ),
        (
            "        if ( id == \"Documents\" )\n"
            "            docLoadingWidget->setTextColor( QColor(color) );\n",
            "        if ( id == \"Documents\" && docLoadingWidget )\n"
            "            docLoadingWidget->setTextColor( QColor(color) );\n",
        ),
    ):
        text = text.replace(old, new, 1)

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
        "    QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
        "    // It could add this itself if it handles docs\n"
        "    tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n",
        "    if ( docTabEnabled ) {\n"
        "        QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
        "        // It could add this itself if it handles docs\n"
        "        tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n"
        "    }\n",
        1,
    )

    text = text.replace(
        "    tabs = new LauncherTabWidget( this );\n"
        "    setCentralWidget( tabs );\n",
        "    tabs = new LauncherTabWidget( this );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->hide();\n"
        "    be300Home = new Be300HomeWidget( this );\n"
        "    setCentralWidget( be300Home );\n"
        "#else\n"
        "    setCentralWidget( tabs );\n"
        "#endif\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n"
        "    tabs->layout()->activate();\n"
        "    tabs->hide();\n"
        "    if ( be300Home )\n"
        "        be300Home->ensureVisible();\n"
        "#endif\n",
        1,
    )

    text = text.replace(
        "    tabs = 0;\n"
        "    tb = 0;\n",
        "    tabs = 0;\n"
        "    tb = 0;\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    be300Home = 0;\n"
        "#endif\n",
        1,
    )

    text = text.replace(
        "void Launcher::destroyGUI()\n"
        "{\n"
        "    delete tb;\n"
        "    tb = 0;\n"
        "    delete tabs;\n"
        "    tabs =0;\n"
        "}\n",
        "void Launcher::destroyGUI()\n"
        "{\n"
        "    delete tb;\n"
        "    tb = 0;\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    delete be300Home;\n"
        "    be300Home = 0;\n"
        "#endif\n"
        "    delete tabs;\n"
        "    tabs =0;\n"
        "}\n",
        1,
    )

    text = text.replace(
        "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n"
        "    qApp->setMainWidget( this );\n"
        "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    be300PopulateLauncherDefaults( tabs, &ids );\n"
        "    if ( tabs->categoryBar->launcherTab( \"Settings\" ) )\n"
        "        tabs->categoryBar->showTab( \"Settings\" );\n"
        "    if ( tabs->currentView() )\n"
        "        be300RefreshLauncherView( tabs->currentView() );\n"
        "    tabs->raiseTabWidget();\n"
        "#else\n"
        "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n"
        "#endif\n"
        "    qApp->setMainWidget( this );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->layout()->activate();\n"
        "    showMaximized();\n"
        "    raise();\n"
        "    if ( be300Home )\n"
        "        be300Home->ensureVisible();\n"
        "    repaint( FALSE );\n"
        "#else\n"
        "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
        "#endif\n",
        1,
    )

    text = text.replace(
        "void Launcher::makeVisible()\n"
        "{\n"
        "    showMaximized();\n"
        "}\n",
        "void Launcher::makeVisible()\n"
        "{\n"
        "    showMaximized();\n"
        "}\n"
        "\n"
        "void Launcher::be300PopulateLauncher()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( !tabs )\n"
        "        return;\n"
        "    be300PopulateLauncherDefaults( tabs, &ids );\n"
        "    tabs->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n"
        "    tabs->layout()->activate();\n"
        "    if ( tabs->categoryBar->launcherTab( \"Settings\" ) )\n"
        "        tabs->categoryBar->showTab( \"Settings\" );\n"
        "    else if ( !ids.isEmpty() )\n"
        "        tabs->categoryBar->showTab( *ids.begin() );\n"
        "    tabs->raiseTabWidget();\n"
        "    tabs->hide();\n"
        "    showMaximized();\n"
        "    raise();\n"
        "    if ( be300Home )\n"
        "        be300Home->ensureVisible();\n"
        "    repaint( FALSE );\n"
        "#endif\n"
        "}\n",
        1,
    )

    text = text.replace(
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
        1,
    )
    text = text.replace(
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
        1,
    )
    text = text.replace(
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
        1,
    )
    text = text.replace(
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
        1,
    )
    text = text.replace(
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
        1,
    )
    text = text.replace(
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
        1,
    )
    text = text.replace(
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
        1,
    )
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
        "    LauncherView *view = tabs->view( type );\n"
        "    if ( !view )\n"
        "        view = tabs->newView( type, pixmap, name );\n"
        "    if ( !ids.contains( type ) )\n"
        "        ids.append( type );\n"
        "    /* this will be called in applicationScanningProgress with value 100! */\n"
        "//    tb->refreshStartMenu();\n"
        "\n"
        "    static bool first = TRUE;\n"
        "    if ( first ) {\n"
        "    first = FALSE;\n"
        "        tabs->categoryBar->showTab(type);\n"
        "    }\n"
        "\n"
        "    if ( view ) {\n"
        "        view->setUpdatesEnabled( FALSE );\n"
        "        view->setSortEnabled( FALSE );\n"
        "    }\n"
        "}\n",
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
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    MimeType::registerApp( app );\n"
        "    if ( be300Home ) {\n"
        "        be300Home->addApp( type, app );\n"
        "        be300Home->ensureVisible();\n"
        "    }\n"
        "    return;\n"
        "#endif\n"
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
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "        if ( tabs && tabs->categoryBar && tabs->categoryBar->count() > 0 ) {\n"
        "            QTimer::singleShot( 0, this, SLOT( be300PopulateLauncher() ) );\n"
        "            tabs->raiseTabWidget();\n"
        "            break;\n"
        "        }\n"
        "#endif\n"
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
        "            tb->refreshStartMenu();\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "            QTimer::singleShot( 0, this, SLOT( be300PopulateLauncher() ) );\n"
        "#endif\n"
        "        break;\n"
        "        }\n"
        "        default:\n"
        "            break;\n"
        "    }\n"
        "}\n",
        1,
    )

    text = text.replace(
        "    cfg.setGroup( \"DocTab\" );\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n",
        "    cfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n",
        2,
    )

    text = text.replace(
        " bool Launcher::requiresDocuments() const\n"
        " {\n"
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "    return cfg.readBoolEntry( \"Enable\", true );\n"
        "}\n",
        " bool Launcher::requiresDocuments() const\n"
        " {\n"
        "    Config cfg( \"Launcher\" );\n"
        "    cfg.setGroup( \"DocTab\" );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return cfg.readBoolEntry( \"Enable\", false );\n"
        "#else\n"
        "    return cfg.readBoolEntry( \"Enable\", true );\n"
        "#endif\n"
        "}\n",
        1,
    )

    write_text(path, text)


def patch_launcherview():
    restore_original("core/launcher/launcherview.cpp")

    hpath = ROOT / "core/launcher/launcherview.h"
    if hpath.exists():
        htext = read_text(hpath)
        if "virtual void drawContents( QPainter *p, int cx, int cy, int cw, int ch );" not in htext:
            htext = htext.replace(
                "class QIconViewItem;\n",
                "class QIconViewItem;\n"
                "class QPainter;\n",
                1,
            )
            htext = htext.replace(
                "    virtual void keyPressEvent(QKeyEvent* e);\n",
                "    virtual void keyPressEvent(QKeyEvent* e);\n"
                "    virtual void drawContents( QPainter *p, int cx, int cy, int cw, int ch );\n",
                1,
            )
            write_text(hpath, htext)

    path = ROOT / "core/launcher/launcherview.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    if "BE300 direct icon item paint" not in text:
        text = text.replace(
            "int LauncherIconView::compare(const AppLnk* a, const AppLnk* b)\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "void LauncherIconView::drawContents( QPainter *p, int cx, int cy, int cw, int ch )\n"
            "{\n"
            "    QIconView::drawContents( p, cx, cy, cw, ch );\n"
            "    /* BE300 direct icon item paint: the stock Qt/Embedded 2\n"
            "       QIconView container path can leave visible launcher\n"
            "       items unpainted on LinuxFb even after layout. */\n"
            "    QRect exposed( cx, cy, cw, ch );\n"
            "    QColorGroup cg = colorGroup();\n"
            "    cg.setColor( QColorGroup::Text, black );\n"
            "    cg.setColor( QColorGroup::HighlightedText, white );\n"
            "\n"
            "    int viewWidth = viewport() ? viewport()->width() : width();\n"
            "    if ( viewWidth <= 0 )\n"
            "        viewWidth = QApplication::desktop()->width();\n"
            "    int cols = viewWidth < 180 ? 2 : 3;\n"
            "    int cellW = viewWidth / cols;\n"
            "    if ( cellW < 48 )\n"
            "        cellW = 48;\n"
            "    int cellH = fontMetrics().height() * 2 + 34;\n"
            "    if ( cellH < 56 )\n"
            "        cellH = 56;\n"
            "\n"
            "    int n = 0;\n"
            "    for ( QIconViewItem *item = firstItem(); item; item = item->nextItem(), ++n ) {\n"
            "        QRect cell( ( n % cols ) * cellW, ( n / cols ) * cellH + 4,\n"
            "                    cellW, cellH );\n"
            "        if ( !cell.intersects( exposed ) )\n"
            "            continue;\n"
            "\n"
            "        QPixmap *pm = item->pixmap();\n"
            "        if ( pm && !pm->isNull() ) {\n"
            "            int px = cell.x() + ( cell.width() - pm->width() ) / 2;\n"
            "            p->drawPixmap( px, cell.y() + 2, *pm );\n"
            "        } else {\n"
            "            QRect icon( cell.x() + ( cell.width() - 32 ) / 2, cell.y() + 2, 32, 32 );\n"
            "            p->save();\n"
            "            p->setPen( QColor( 45, 93, 151 ) );\n"
            "            p->setBrush( QColor( 236, 246, 255 ) );\n"
            "            p->drawRect( icon );\n"
            "            p->drawText( icon, AlignCenter, item->text().left( 1 ) );\n"
            "            p->restore();\n"
            "        }\n"
            "\n"
            "        p->save();\n"
            "        p->setPen( cg.text() );\n"
            "        QRect label( cell.x() + 2, cell.y() + 36, cell.width() - 4,\n"
            "                     cell.height() - 36 );\n"
            "        p->drawText( label, AlignHCenter | WordBreak, item->text() );\n"
            "        p->restore();\n"
            "    }\n"
            "}\n"
            "#endif\n"
            "\n"
            "int LauncherIconView::compare(const AppLnk* a, const AppLnk* b)\n",
            1,
        )
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
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    text = text.replace(
        "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n"
        "    d = new DocumentListPrivate( serverGui );\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    appLnkSet = new AppLnkSet();\n"
        "#else\n"
        "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n"
        "#endif\n"
        "    d = new DocumentListPrivate( serverGui );\n",
        1,
    )
    text = text.replace(
        "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n"
        "#else\n"
        "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "void DocumentList::startInitialScan()\n"
        "{\n"
        "    reloadAppLnks();\n"
        "    reloadDocLnks();\n"
        "}\n",
        "void DocumentList::startInitialScan()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( d->serverGui )\n"
        "        d->serverGui->applicationScanningProgress( 100 );\n"
        "    return;\n"
        "#endif\n"
        "    reloadAppLnks();\n"
        "    reloadDocLnks();\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void DocumentList::reloadAppLnks()\n"
        "{\n",
        "void DocumentList::reloadAppLnks()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( d->serverGui )\n"
        "        d->serverGui->applicationScanningProgress( 100 );\n"
        "    return;\n"
        "#endif\n",
        1,
    )
    write_text(path, text)


def patch_regular_documentlist_shell():
    restore_original("core/launcher/documentlist.cpp")


def patch_taskbar():
    path = ROOT / "core/launcher/taskbar.cpp"
    if path.exists():
        text = strip_be300_debug(read_text(path))
        text = re.sub(r"(if \( inputMethods \) ){2,}", "if ( inputMethods ) ", text)
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
        write_text(path, text)

    patch_server()
    patch_serverapp()


def patch_server():
    restore_original("core/launcher/server.cpp")

    path = ROOT / "core/launcher/server.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    text = text.replace(
        "    serverGui = new Launcher;\n"
        "    serverGui->createGUI();\n",
        "    serverGui = new Launcher;\n"
        "    serverGui->createGUI();\n"
        "\n",
        1,
    )
    text = text.replace(
        "    last_today_show = QDate::currentDate();\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    last_today_show = QDate( 2000, 1, 1 );\n"
        "#else\n"
        "    last_today_show = QDate::currentDate();\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    appLauncher = new AppLauncher(this);\n"
        "    connect(appLauncher, SIGNAL(launched(int,const QString&)), this, SLOT(applicationLaunched(int,const QString&)) );\n"
        "    connect(appLauncher, SIGNAL(terminated(int,const QString&)), this, SLOT(applicationTerminated(int,const QString&)) );\n"
        "    connect(appLauncher, SIGNAL(connected(const QString&)), this, SLOT(applicationConnected(const QString&)) );\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    appLauncher = new AppLauncher(this);\n"
        "    connect(appLauncher, SIGNAL(launched(int,const QString&)), this, SLOT(applicationLaunched(int,const QString&)) );\n"
        "    connect(appLauncher, SIGNAL(terminated(int,const QString&)), this, SLOT(applicationTerminated(int,const QString&)) );\n"
        "    connect(appLauncher, SIGNAL(connected(const QString&)), this, SLOT(applicationConnected(const QString&)) );\n"
        "#else\n"
        "    appLauncher = 0;\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    soundServerExited();\n\n"
        "    // start services\n"
        "    startTransferServer();\n"
        "    (void) new IrServer( this );\n\n"
        "    packageHandler = new PackageHandler( this );\n"
        "    connect(qApp, SIGNAL(activate(const Opie::Core::ODeviceButton*,bool)),\n"
        "            this,SLOT(activate(const Opie::Core::ODeviceButton*,bool)));\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    soundServerExited();\n\n"
        "    // start services\n"
        "    startTransferServer();\n"
        "    (void) new IrServer( this );\n\n"
        "    packageHandler = new PackageHandler( this );\n"
        "    connect(qApp, SIGNAL(activate(const Opie::Core::ODeviceButton*,bool)),\n"
        "            this,SLOT(activate(const Opie::Core::ODeviceButton*,bool)));\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    preloadApps();\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    preloadApps();\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "void Server::show()\n"
        "{\n"
        "    ServerApplication::login(TRUE);\n"
        "    QWidget::show();\n"
        "}\n",
        "void Server::show()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    hide();\n"
        "    return;\n"
        "#else\n"
        "    ServerApplication::login(TRUE);\n"
        "    QWidget::show();\n"
        "#endif\n"
        "}\n",
        1,
    )
    write_text(path, text)


def patch_regular_server_shell():
    restore_original("core/launcher/server.cpp")

    path = ROOT / "core/launcher/server.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    text = text.replace(
        "    serverGui = new Launcher;\n"
        "    serverGui->createGUI();\n",
        "    serverGui = new Launcher;\n"
        "    serverGui->createGUI();\n"
        "\n",
        1,
    )
    text = text.replace(
        "    last_today_show = QDate::currentDate();\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    last_today_show = QDate( 2000, 1, 1 );\n"
        "#else\n"
        "    last_today_show = QDate::currentDate();\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    soundServerExited();\n\n"
        "    // start services\n"
        "    startTransferServer();\n"
        "    (void) new IrServer( this );\n\n"
        "    packageHandler = new PackageHandler( this );\n"
        "    connect(qApp, SIGNAL(activate(const Opie::Core::ODeviceButton*,bool)),\n"
        "            this,SLOT(activate(const Opie::Core::ODeviceButton*,bool)));\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    soundServerExited();\n\n"
        "    // start services\n"
        "    startTransferServer();\n"
        "    (void) new IrServer( this );\n\n"
        "    packageHandler = new PackageHandler( this );\n"
        "    connect(qApp, SIGNAL(activate(const Opie::Core::ODeviceButton*,bool)),\n"
        "            this,SLOT(activate(const Opie::Core::ODeviceButton*,bool)));\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    preloadApps();\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    preloadApps();\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "void Server::show()\n"
        "{\n"
        "    ServerApplication::login(TRUE);\n"
        "    QWidget::show();\n"
        "}\n",
        "void Server::show()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    hide();\n"
        "    return;\n"
        "#else\n"
        "    ServerApplication::login(TRUE);\n"
        "    QWidget::show();\n"
        "#endif\n"
        "}\n",
        1,
    )
    write_text(path, text)


def patch_serverapp():
    restore_original("core/launcher/serverapp.cpp")

    path = ROOT / "core/launcher/serverapp.cpp"
    if not path.exists():
        return

    text = strip_be300_debug(read_text(path))
    text = text.replace(
        "    m_ps = new PowerStatus;\n"
        "    m_ps_last = new PowerStatus;\n"
        "    pa = new DesktopPowerAlerter( 0 );\n",
        "    m_ps = new PowerStatus;\n"
        "    m_ps_last = new PowerStatus;\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    pa = new DesktopPowerAlerter( 0 );\n"
        "#else\n"
        "    pa = 0;\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    m_screensaver = new OpieScreenSaver();\n"
        "    m_screensaver->setInterval( -1 );\n"
        "    QWSServer::setScreenSaver( m_screensaver );\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    m_screensaver = new OpieScreenSaver();\n"
        "    m_screensaver->setInterval( -1 );\n"
        "    QWSServer::setScreenSaver( m_screensaver );\n"
        "#else\n"
        "    m_screensaver = 0;\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    apmTimeout();\n"
        "    grabKeyboard();\n\n"
        "    /* make sure the event filter is installed */  /* std::limits<short>::max() when you've stdc++ */\n"
        "    const ODeviceButton* but = ODevice::inst()->buttonForKeycode( SHRT_MAX );\n"
        "    Q_CONST_UNUSED( but )\n",
        "    apmTimeout();\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    grabKeyboard();\n\n"
        "    /* make sure the event filter is installed */  /* std::limits<short>::max() when you've stdc++ */\n"
        "    const ODeviceButton* but = ODevice::inst()->buttonForKeycode( SHRT_MAX );\n"
        "    Q_CONST_UNUSED( but )\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "void ServerApplication::systemMessage( const QCString& msg,\n"
        "                                       const QByteArray& data )\n"
        "{\n"
        "    QDataStream stream ( data, IO_ReadOnly );\n\n",
        "void ServerApplication::systemMessage( const QCString& msg,\n"
        "                                       const QByteArray& data )\n"
        "{\n"
        "    QDataStream stream ( data, IO_ReadOnly );\n\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( !m_screensaver &&\n"
        "         ( msg == \"setScreenSaverInterval(int)\" ||\n"
        "           msg == \"setScreenSaverIntervals(int,int,int)\" ||\n"
        "           msg == \"setBacklight(int)\" ||\n"
        "           msg == \"incBacklight()\" ||\n"
        "           msg == \"decBacklight()\" ||\n"
        "           msg == \"setScreenSaverMode(int)\" ||\n"
        "           msg == \"setDisplayState(int)\" ) )\n"
        "        return;\n"
        "#endif\n\n",
        1,
    )
    text = text.replace(
        "void ServerApplication::apmTimeout()\n"
        "{\n",
        "void ServerApplication::apmTimeout()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return;\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "void ServerApplication::reloadPowerWarnSettings ( )\n"
        "{\n",
        "void ServerApplication::reloadPowerWarnSettings ( )\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( m_apm_timer )\n"
        "        m_apm_timer->stop();\n"
        "    m_powerVeryLow = 10;\n"
        "    m_powerCritical = 5;\n"
        "    return;\n"
        "#endif\n",
        1,
    )
    write_text(path, text)


def patch_opie_application():
    path = ROOT / "libopie2/opiecore/oapplication.cpp"
    if path.exists():
        write_text(path, strip_be300_debug(read_text(path)))

    applnk_path = ROOT / "library/applnk.cpp"
    if applnk_path.exists():
        restore_original("library/applnk.cpp")
        text = strip_be300_debug(read_text(applnk_path))
        text = text.replace(
            "        QImage unscaledIcon = Resource::loadImage( that->mIconFile );\n"
            "        if ( unscaledIcon.isNull() ) {\n"
            "           //  qDebug( \"Cannot find icon: %s\", that->mIconFile.latin1() );\n"
            "            that->d->mPixmaps[pos].convertFromImage(\n"
            "                Resource::loadImage(\"UnknownDocument\")\n"
            "                .smoothScale( size, size ) );\n"
            "        } else {\n"
            "            that->d->mPixmaps[0].convertFromImage( unscaledIcon.smoothScale( smallSize, smallSize ) );\n"
            "            that->d->mPixmaps[1].convertFromImage( unscaledIcon.smoothScale( bigSize, bigSize ) );\n"
            "        }\n"
            "        return that->d->mPixmaps[pos];\n",
            "        QImage unscaledIcon = Resource::loadImage( that->mIconFile );\n"
            "        if ( unscaledIcon.isNull() ) {\n"
            "           //  qDebug( \"Cannot find icon: %s\", that->mIconFile.latin1() );\n"
            "            QImage unknownIcon = Resource::loadImage(\"UnknownDocument\");\n"
            "            if ( !unknownIcon.isNull() &&\n"
            "                 ( unknownIcon.width() != size || unknownIcon.height() != size ) )\n"
            "                unknownIcon = unknownIcon.smoothScale( size, size );\n"
            "            that->d->mPixmaps[pos].convertFromImage( unknownIcon );\n"
            "        } else {\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "            QImage sizedIcon = unscaledIcon;\n"
            "            if ( sizedIcon.width() != size || sizedIcon.height() != size )\n"
            "                sizedIcon = sizedIcon.smoothScale( size, size );\n"
            "            that->d->mPixmaps[pos].convertFromImage( sizedIcon );\n"
            "#else\n"
            "            that->d->mPixmaps[0].convertFromImage( unscaledIcon.smoothScale( smallSize, smallSize ) );\n"
            "            that->d->mPixmaps[1].convertFromImage( unscaledIcon.smoothScale( bigSize, bigSize ) );\n"
            "#endif\n"
            "        }\n"
            "        return that->d->mPixmaps[pos];\n",
            1,
        )
        write_text(applnk_path, text)


def patch_launcher_main():
    rel = "core/launcher/main.cpp"
    path = ROOT / rel
    if not path.exists():
        return

    text = original_source(rel) or read_text(path)
    if "#include <fcntl.h>" not in text:
        text = text.replace(
            "#include <stdio.h>\n",
            "#include <stdio.h>\n#include <fcntl.h>\n#include <sys/mman.h>\n",
            1,
        )
    if "be300_qpe_stage" not in text:
        text = text.replace(
            "void create_pidfile();\nvoid remove_pidfile();\n",
            "void create_pidfile();\nvoid remove_pidfile();\n\n"
            "static const char *be300_qpe_stage = \"startup\";\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "#define BE300_UART_MAP_PHYS 0x0a008000UL\n"
            "#define BE300_UART_MAP_SIZE 0x1000UL\n"
            "#define BE300_UART_MAP_OFF 0x680UL\n"
            "#define BE300_UART_THR 0x00\n"
            "#define BE300_UART_LSR 0x14\n"
            "#define BE300_UART_LSR_THRE 0x20\n"
            "static volatile unsigned char *be300_qpe_uart = 0;\n"
            "static void be300_qpe_uart_init()\n"
            "{\n"
            "    int fd;\n"
            "    void *map;\n"
            "    if ( be300_qpe_uart )\n"
            "        return;\n"
            "    fd = ::open( \"/dev/mem\", O_RDWR | O_SYNC );\n"
            "    if ( fd < 0 )\n"
            "        return;\n"
            "    map = ::mmap( 0, BE300_UART_MAP_SIZE, PROT_READ | PROT_WRITE,\n"
            "                  MAP_SHARED, fd, BE300_UART_MAP_PHYS );\n"
            "    ::close( fd );\n"
            "    if ( map == MAP_FAILED )\n"
            "        return;\n"
            "    be300_qpe_uart = (volatile unsigned char *)map + BE300_UART_MAP_OFF;\n"
            "}\n"
            "static void be300_qpe_uart_raw( char c )\n"
            "{\n"
            "    int i;\n"
            "    be300_qpe_uart_init();\n"
            "    if ( !be300_qpe_uart )\n"
            "        return;\n"
            "    for ( i = 0; i < 100000; ++i ) {\n"
            "        if ( be300_qpe_uart[BE300_UART_LSR] & BE300_UART_LSR_THRE )\n"
            "            break;\n"
            "    }\n"
            "    be300_qpe_uart[BE300_UART_THR] = (unsigned char)c;\n"
            "}\n"
            "static void be300_qpe_uart_putc( char c )\n"
            "{\n"
            "    if ( c == '\\n' )\n"
            "        be300_qpe_uart_raw( '\\r' );\n"
            "    be300_qpe_uart_raw( c );\n"
            "}\n"
            "static void be300_qpe_uart_write( const char *s )\n"
            "{\n"
            "    while ( s && *s )\n"
            "        be300_qpe_uart_putc( *s++ );\n"
            "}\n"
            "static void be300_qpe_stage_print( const char *s )\n"
            "{\n"
            "    be300_qpe_uart_write( \"[be300-qpe] \" );\n"
            "    be300_qpe_uart_write( s );\n"
            "    be300_qpe_uart_write( \"\\n\" );\n"
            "}\n"
            "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); be300_qpe_stage_print( be300_qpe_stage ); } while (0)\n"
            "#else\n"
            "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); } while (0)\n"
            "#endif\n",
            1,
        )
    text = text.replace(
        "    Config config(\"locale\");\n",
        "    BE300_QPE_STAGE(\"init.locale_ctor\");\n"
        "    Config config(\"locale\");\n",
        1,
    )
    text = text.replace(
        "    config.setGroup( \"Location\" );\n",
        "    BE300_QPE_STAGE(\"init.locale_setGroup\");\n"
        "    config.setGroup( \"Location\" );\n",
        1,
    )
    text = text.replace(
        "    QString tz = config.readEntry( \"Timezone\", getenv(\"TZ\") ).stripWhiteSpace();\n",
        "    BE300_QPE_STAGE(\"init.tz_read\");\n"
        "    QString tz = config.readEntry( \"Timezone\", getenv(\"TZ\") ).stripWhiteSpace();\n",
        1,
    )
    text = text.replace(
        "    if (tz.isNull() || tz.isEmpty()) tz = \"America/New_York\";\n",
        "    BE300_QPE_STAGE(\"init.tz_default_check\");\n"
        "    if (tz.isNull() || tz.isEmpty()) tz = \"America/New_York\";\n",
        1,
    )
    text = text.replace(
        "    setenv( \"TZ\", tz, 1 );\n",
        "    BE300_QPE_STAGE(\"init.tz_setenv\");\n"
        "    setenv( \"TZ\", tz, 1 );\n",
        1,
    )
    text = text.replace(
        "    config.writeEntry( \"Timezone\", tz);\n",
        "    BE300_QPE_STAGE(\"init.tz_writeEntry\");\n"
        "    config.writeEntry( \"Timezone\", tz);\n",
        1,
    )
    text = text.replace(
        "    config.setGroup( \"Language\" );\n",
        "    BE300_QPE_STAGE(\"init.lang_setGroup\");\n"
        "    config.setGroup( \"Language\" );\n",
        1,
    )
    text = text.replace(
        "    QString lang = config.readEntry( \"Language\", getenv(\"LANG\") ).stripWhiteSpace();\n",
        "    BE300_QPE_STAGE(\"init.lang_read\");\n"
        "    QString lang = config.readEntry( \"Language\", getenv(\"LANG\") ).stripWhiteSpace();\n",
        1,
    )
    text = text.replace(
        "    if( lang.isNull() || lang.isEmpty()) lang = \"en_US\";\n",
        "    BE300_QPE_STAGE(\"init.lang_default_check\");\n"
        "    if( lang.isNull() || lang.isEmpty()) lang = \"en_US\";\n",
        1,
    )
    text = text.replace(
        "    setenv( \"LANG\", lang, 1 );\n",
        "    BE300_QPE_STAGE(\"init.lang_setenv\");\n"
        "    setenv( \"LANG\", lang, 1 );\n",
        1,
    )
    text = text.replace(
        "    config.writeEntry(\"Language\", lang);\n",
        "    BE300_QPE_STAGE(\"init.lang_writeEntry\");\n"
        "    config.writeEntry(\"Language\", lang);\n",
        1,
    )
    text = text.replace(
        "    config.write();\n",
        "    BE300_QPE_STAGE(\"init.config_write\");\n"
        "    config.write();\n",
        1,
    )
    text = text.replace(
        "    int t = ODevice::inst()->rotation();\n"
        "    odebug << \"ODevice reports transformation to be \" << t << oendl;\n",
        "    BE300_QPE_STAGE(\"init.odevice_inst1\");\n"
        "    int t = ODevice::inst()->rotation();\n"
        "    BE300_QPE_STAGE(\"init.skip_odebug_rotation\");\n",
        1,
    )
    text = text.replace(
        "    QString env( getenv(\"QWS_DISPLAY\") );\n",
        "    BE300_QPE_STAGE(\"init.qws_getenv\");\n"
        "    QString env( getenv(\"QWS_DISPLAY\") );\n",
        1,
    )
    text = text.replace(
        "            int rot = ODevice::inst()->rotation() * 90;\n"
        "            QString qws_display = QString( \"%1:Rot%2:0\").arg(ODevice::inst()->qteDriver()).arg(rot);\n"
        "            odebug << \"setting QWS_DISPLAY to '\" << qws_display << \"'\" << oendl;\n"
        "            setenv(\"QWS_DISPLAY\", (const char*) qws_display, 1);\n",
        "            BE300_QPE_STAGE(\"init.odevice_rotation2\");\n"
        "            int rot = ODevice::inst()->rotation() * 90;\n"
        "            BE300_QPE_STAGE(\"init.qte_driver\");\n"
        "            QString qws_display = QString( \"%1:Rot%2:0\").arg(ODevice::inst()->qteDriver()).arg(rot);\n"
        "            BE300_QPE_STAGE(\"init.skip_odebug_qws_new\");\n"
        "            BE300_QPE_STAGE(\"init.qws_setenv\");\n"
        "            setenv(\"QWS_DISPLAY\", (const char*) qws_display, 1);\n",
        1,
    )
    text = text.replace(
        "    else\n"
        "        odebug << \"QWS_DISPLAY already set as '\" << env << \"' - overriding ODevice transformation\" << oendl;\n\n"
        "    QPEApplication::defaultRotation(); /* to ensure deforient matches reality */\n",
        "    else\n"
        "        BE300_QPE_STAGE(\"init.skip_odebug_qws_existing\");\n\n"
        "    BE300_QPE_STAGE(\"init.qpeapp_defaultRotation\");\n"
        "    QPEApplication::defaultRotation(); /* to ensure deforient matches reality */\n"
        "    BE300_QPE_STAGE(\"init.exit\");\n",
        1,
    )
    if "BE300 skips OPIE first-use wizard" not in text:
        text = text.replace(
            "static bool firstUse()\n{\n",
            "static bool firstUse()\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 skips OPIE first-use wizard; the image ships\n"
            "       calibrated input defaults and should land directly on\n"
            "       the launcher. */\n"
            "    return FALSE;\n"
            "#endif\n",
            1,
        )
    text = text.replace(
        "    cleanup();\n    initEnvironment();\n",
        "    BE300_QPE_STAGE(\"cleanup\");\n"
        "    cleanup();\n"
        "    BE300_QPE_STAGE(\"initEnvironment\");\n"
        "    initEnvironment();\n",
        1,
    )
    text = text.replace(
        "#ifdef QWS\n    QWSServer::setDesktopBackground( QImage() );\n#endif\n    ServerApplication a",
        "#ifdef QWS\n"
        "    BE300_QPE_STAGE(\"setDesktopBackground\");\n"
        "    QWSServer::setDesktopBackground( QImage() );\n"
        "#endif\n"
        "    BE300_QPE_STAGE(\"ServerApplication\");\n"
        "    ServerApplication a",
        1,
    )
    text = text.replace(
        "    initKeyboard();\n\n    bool firstUseShown = firstUse();\n",
        "    BE300_QPE_STAGE(\"initKeyboard\");\n"
        "    initKeyboard();\n\n"
        "    BE300_QPE_STAGE(\"firstUse\");\n"
        "    bool firstUseShown = firstUse();\n",
        1,
    )
    text = text.replace(
        "        QCopEnvelope e(\"QPE/System\", \"setBacklight(int)\" );\n",
        "        BE300_QPE_STAGE(\"setBacklight\");\n"
        "        QCopEnvelope e(\"QPE/System\", \"setBacklight(int)\" );\n",
        1,
    )
    text = text.replace(
        "    AlarmServer::initialize();\n"
        "    Server *s = new Server();\n"
        "    new SysFileMonitor(s);\n"
        "#ifdef QWS\n"
        "    Network::createServer(s);\n"
        "#endif\n"
        "    s->show();\n",
        "    BE300_QPE_STAGE(\"AlarmServer::initialize\");\n"
        "    AlarmServer::initialize();\n"
        "    BE300_QPE_STAGE(\"new Server\");\n"
        "    Server *s = new Server();\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    BE300_QPE_STAGE(\"new SysFileMonitor\");\n"
        "    new SysFileMonitor(s);\n"
        "#else\n"
        "    BE300_QPE_STAGE(\"skip SysFileMonitor\");\n"
        "#endif\n"
        "#ifdef QWS\n"
        "    BE300_QPE_STAGE(\"Network::createServer\");\n"
        "    Network::createServer(s);\n"
        "#endif\n"
        "    BE300_QPE_STAGE(\"server show\");\n"
        "    s->show();\n",
        1,
    )
    if "BE300 skips invalid-date prompt" not in text:
        text = text.replace(
            "    if ( !firstUseShown ) {\n        Config config( \"qpe\" );\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    if ( !firstUseShown ) {\n        Config config( \"qpe\" );\n",
            1,
        )
        text = text.replace(
            "    }\n\n    create_pidfile();\n",
            "    }\n"
            "#else\n"
            "    /* BE300 skips invalid-date prompt; RTC handoff is emulator\n"
            "       dependent and should not block the desktop at boot. */\n"
            "#endif\n\n"
            "    BE300_QPE_STAGE(\"create_pidfile\");\n"
            "    create_pidfile();\n",
            1,
        )
    text = text.replace(
        "    odebug << \"--> mainloop in\" << oendl;\n    int rv = a.exec();\n",
        "    BE300_QPE_STAGE(\"mainloop\");\n"
        "    odebug << \"--> mainloop in\" << oendl;\n"
        "    int rv = a.exec();\n",
        1,
    )
    old_handler = (
        "void handle_sigterm( int sig )\n"
        "{\n"
        "    qDebug( \"D'oh! QPE Server process got SIGNAL %d. Trying to exit gracefully...\", sig );\n"
        "    ::signal( SIGCHLD, SIG_IGN );\n"
        "    ::signal( SIGSEGV, SIG_IGN );\n"
        "    ::signal( SIGBUS, SIG_IGN );\n"
        "    ::signal( SIGILL, SIG_IGN );\n"
        "    ::signal( SIGTERM, SIG_IGN );\n"
        "    ::signal ( SIGINT, SIG_IGN );\n"
        "    if ( qApp ) qApp->quit();\n"
        "}\n"
    )
    new_handler = (
        "void handle_sigterm( int sig )\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    char buf[128];\n"
        "    ::snprintf( buf, sizeof(buf),\n"
        "                \"D'oh! qpe got SIGNAL %d at stage %s\\n\",\n"
        "                sig, be300_qpe_stage );\n"
        "    be300_qpe_uart_write( buf );\n"
        "#else\n"
        "    qDebug( \"D'oh! QPE Server process got SIGNAL %d. Trying to exit gracefully...\", sig );\n"
        "#endif\n"
        "    ::signal( SIGCHLD, SIG_IGN );\n"
        "    ::signal( SIGSEGV, SIG_IGN );\n"
        "    ::signal( SIGBUS, SIG_IGN );\n"
        "    ::signal( SIGILL, SIG_IGN );\n"
        "    ::signal( SIGTERM, SIG_IGN );\n"
        "    ::signal ( SIGINT, SIG_IGN );\n"
        "    if ( qApp ) qApp->quit();\n"
        "}\n"
    )
    text = text.replace(old_handler, new_handler, 1)
    text = text.replace(
        "    ::signal( SIGCHLD, SIG_IGN );\n"
        "    ::signal( SIGSEGV, handle_sigterm );\n"
        "    ::signal( SIGBUS, handle_sigterm );\n"
        "    ::signal( SIGILL, handle_sigterm );\n"
        "    ::signal( SIGTERM, handle_sigterm );\n",
        "    ::signal( SIGCHLD, SIG_IGN );\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    ::signal( SIGSEGV, handle_sigterm );\n"
        "    ::signal( SIGBUS, handle_sigterm );\n"
        "    ::signal( SIGILL, handle_sigterm );\n"
        "#endif\n"
        "    ::signal( SIGTERM, handle_sigterm );\n",
        1,
    )
    write_text(path, text)


def patch_config_write():
    path = ROOT / "library/config.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "void Config::write( const QString &fn )\n"
        "{\n"
        "    QString oldGroup = git.key();\n"
    )
    new = (
        "void Config::write( const QString &fn )\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_CONFIG_WRITE_DISABLED\n"
        "       Avoid QFile/QMap writeback paths during 16 MiB OPIE startup. */\n"
        "    changed = false;\n"
        "    return;\n"
        "#endif\n"
        "    QString oldGroup = git.key();\n"
    )
    if old in text and "BE300_CONFIG_WRITE_DISABLED" not in text:
        text = text.replace(old, new, 1)
    text = text.replace(
        '    if ( !f.open( IO_WriteOnly|IO_Raw ) ) {\n'
        '\tqWarning( "could not open for writing `%s\'", strNewFile.latin1() );\n'
        '\tgit = groups.end();\n'
        '\treturn;\n'
        '    }\n',
        '    if ( !f.open( IO_WriteOnly|IO_Raw ) ) {\n'
        '#ifdef QT_QWS_CASSIOPEIA\n'
        '\tqWarning( "could not open config for writing" );\n'
        '#else\n'
        '\tqWarning( "could not open for writing `%s\'", strNewFile.latin1() );\n'
        '#endif\n'
        '\tgit = groups.end();\n'
        '\treturn;\n'
        '    }\n',
    )
    text = text.replace(
        '    if ( rename( strNewFile, filename ) < 0 ) {\n'
        '\tqWarning( "problem renaming the file %s to %s", strNewFile.latin1(),\n'
        '\t\t  filename.latin1() );\n'
        '        QFile::remove( strNewFile );\n'
        '        return;\n'
        '    }\n',
        '    if ( rename( strNewFile, filename ) < 0 ) {\n'
        '#ifdef QT_QWS_CASSIOPEIA\n'
        '\tqWarning( "problem renaming config file" );\n'
        '#else\n'
        '\tqWarning( "problem renaming the file %s to %s", strNewFile.latin1(),\n'
        '\t\t  filename.latin1() );\n'
        '#endif\n'
        '        QFile::remove( strNewFile );\n'
        '        return;\n'
        '    }\n',
    )
    text = text.replace(
        '    if ( rename( strNewFile, filename ) < 0 ) {\n'
        '#ifdef QT_QWS_CASSIOPEIA\n'
        '\tqWarning( "problem renaming config file" );\n'
        '#else\n'
        '\tqWarning( "problem renaming the file %s to %s", strNewFile.latin1(),\n'
        '\t\t  filename.latin1() );\n'
        '#endif\n'
        '        QFile::remove( strNewFile );\n'
        '        return;\n'
        '    }\n',
        '    if ( rename( strNewFile, filename ) < 0 ) {\n'
        '#ifdef QT_QWS_CASSIOPEIA\n'
        '\tqWarning( "problem renaming config file" );\n'
        '#else\n'
        '\tqWarning( "problem renaming the file %s to %s", strNewFile.latin1(),\n'
        '\t\t  filename.latin1() );\n'
        '#endif\n'
        '        QFile::remove( strNewFile );\n'
        '        return;\n'
        '    }\n',
    )
    text = text.replace(
        '#ifdef QT_QWS_CASSIOPEIA\n'
        '    QCString strNewFile8 = strNewFile.latin1();\n'
        '    QCString filename8 = filename.latin1();\n'
        '    if ( ::rename( strNewFile8.data(), filename8.data() ) < 0 ) {\n'
        '\tqWarning( "problem renaming config file" );\n'
        '#else\n'
        '    if ( rename( strNewFile, filename ) < 0 ) {\n'
        '\tqWarning( "problem renaming the file %s to %s", strNewFile.latin1(),\n'
        '\t\t  filename.latin1() );\n'
        '#endif\n'
        '        QFile::remove( strNewFile );\n'
        '        return;\n'
        '    }\n',
        '    if ( rename( strNewFile, filename ) < 0 ) {\n'
        '#ifdef QT_QWS_CASSIOPEIA\n'
        '\tqWarning( "problem renaming config file" );\n'
        '#else\n'
        '\tqWarning( "problem renaming the file %s to %s", strNewFile.latin1(),\n'
        '\t\t  filename.latin1() );\n'
        '#endif\n'
        '        QFile::remove( strNewFile );\n'
        '        return;\n'
        '    }\n',
    )
    write_text(path, text)


def patch_config_raw_read():
    path = ROOT / "library/config.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "    QFile f( readFilename );\n"
        "    if ( !f.open( IO_ReadOnly ) ) {\n"
        "        git = groups.end();\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    if (f.getch()!='[') {\n"
        "        git = groups.end();\n"
        "        return;\n"
        "    }\n"
        "    f.ungetch('[');\n"
    )
    new = (
        "    QFile f( readFilename );\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( !f.open( IO_ReadOnly|IO_Raw ) ) {\n"
        "        git = groups.end();\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    char first = 0;\n"
        "    if ( f.readBlock( &first, 1 ) != 1 || first != '[' || !f.at( 0 ) ) {\n"
        "        git = groups.end();\n"
        "        return;\n"
        "    }\n"
        "#else\n"
        "    if ( !f.open( IO_ReadOnly ) ) {\n"
        "        git = groups.end();\n"
        "        return;\n"
        "    }\n"
        "\n"
        "    if (f.getch()!='[') {\n"
        "        git = groups.end();\n"
        "        return;\n"
        "    }\n"
        "    f.ungetch('[');\n"
        "#endif\n"
    )
    if old in text and new not in text:
        text = text.replace(old, new, 1)
    write_text(path, text)


def patch_config_direct_read_entry():
    path = ROOT / "library/config.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "QString Config::readEntry( const QString &key, const QString &deflt )\n"
        "{\n"
        "    QString r;\n"
    )
    new = (
        "QString Config::readEntry( const QString &key, const QString &deflt )\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return readEntryDirect( key, deflt );\n"
        "#else\n"
        "    QString r;\n"
    )
    if old in text and new not in text:
        text = text.replace(old, new, 1)

    old = (
        "    r = readEntryDirect( key, deflt );\n"
        "    return r;\n"
        "}\n"
    )
    new = (
        "    r = readEntryDirect( key, deflt );\n"
        "    return r;\n"
        "#endif\n"
        "}\n"
    )
    marker = "#ifdef QT_QWS_CASSIOPEIA\n    return readEntryDirect( key, deflt );"
    if marker in text and "#endif\n}\n\n/*!\n  \\fn QString Config::readEntryCrypt" not in text:
        text = text.replace(old, new, 1)
    write_text(path, text)


def patch_config_disable_cache():
    path = ROOT / "library/config.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "void ConfigCache::insert( const QString& fileName, const ConfigGroupMap& cfg,\n"
        "                          const ConfigPrivate* _priv ) {\n"
        "\n"
        "\n"
        "    struct stat sbuf;\n"
    )
    new = (
        "void ConfigCache::insert( const QString& fileName, const ConfigGroupMap& cfg,\n"
        "                          const ConfigPrivate* _priv ) {\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return;\n"
        "#endif\n"
        "\n"
        "    struct stat sbuf;\n"
    )
    if old in text and "BE300_CONFIG_CACHE_DISABLED" not in text:
        text = text.replace(old, new.replace("#endif\n", "#endif /* BE300_CONFIG_CACHE_DISABLED */\n"), 1)

    old = (
        "bool ConfigCache::find( const QString& fileName, ConfigGroupMap& cfg,\n"
        "                        ConfigPrivate **ppriv ) {\n"
        "    QMap<QString, ConfigData>::Iterator it = m_cached.find(fileName);\n"
    )
    new = (
        "bool ConfigCache::find( const QString& fileName, ConfigGroupMap& cfg,\n"
        "                        ConfigPrivate **ppriv ) {\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return false;\n"
        "#endif /* BE300_CONFIG_CACHE_DISABLED */\n"
        "    QMap<QString, ConfigData>::Iterator it = m_cached.find(fileName);\n"
    )
    if old in text and "#endif /* BE300_CONFIG_CACHE_DISABLED */\n    QMap<QString, ConfigData>::Iterator it" not in text:
        text = text.replace(old, new, 1)

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
    patch_regular_launcher_shell()
    patch_launcherview()
    patch_launchertab()
    patch_documentlist()
    patch_regular_documentlist_shell()
    patch_taskbar()
    patch_regular_server_shell()
    patch_opie_application()
    patch_launcher_main()
    patch_config_write()
    patch_config_raw_read()
    patch_config_disable_cache()
    patch_config_direct_read_entry()
    patch_backup()


if __name__ == "__main__":
    main()
