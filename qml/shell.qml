// Calendar viewer for ICS feeds configured in ~/.config/quickcalendar/calendars.txt.
// Reads events via `quickcalendar-sync list --json` (same parser the alert daemon uses)
// and renders a week grid. The FAB opens a picker that punts to the browser to
// actually create the event in the owning calendar's web UI.
//
// Run via the `quickcalendar` launcher, or directly:
//   quickshell -p ~/.local/share/quickcalendar/shell.qml

import QtQml
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

FloatingWindow {
    id: root
    title: "Calendar View"
    color: surface
    minimumSize: Qt.size(760, 520)
    // Hint a sensible initial size; whoever's hosting the window (Hyprland,
    // user-resize) gets to override. The grid below is responsive so the
    // app adapts to whatever it ends up at.
    implicitWidth: 1180
    implicitHeight: 780

    // ---- theme ----
    readonly property color surface: "#fbfbfd"
    readonly property color card: "#ffffff"
    readonly property color border: "#e5e5ec"
    readonly property color borderStrong: "#d4d4dc"
    readonly property color text: "#1c1c1e"
    readonly property color textMuted: "#6b7280"
    readonly property color textFaint: "#9ca3af"
    readonly property color accent: "#3b82f6"
    readonly property color todayTint: "#eff6ff"
    readonly property color nowLine: "#ef4444"
    readonly property color newEventBtnColor: "#ff5a3c"
    readonly property color newEventBtnHoverColor: "#ff7259"

    // ---- state ----
    property var calendars: []
    property var events: []
    property string lastSync: ""
    property bool loading: false
    property bool newEventMenuOpen: false
    property var selectedEvent: null  // non-null while details modal is open
    // Anchor = Monday of the displayed week, at local midnight.
    property var weekAnchor: mondayOf(new Date())

    // ---- live clock + midnight rollover ----
    // A single reactive "now", ticked every 30s, that every date-dependent
    // binding reads (today highlight, now-line). A bare `new Date()` inside a
    // binding is computed once and never re-runs, which is why an app left
    // open past midnight kept highlighting yesterday — and why the Today
    // button couldn't shift it (it's a no-op when the stale week already
    // equals the current week, so nothing re-evaluated).
    property date now: new Date()
    Timer {
        interval: 30 * 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }
    // The calendar day `now` was last on. When a tick lands on a new day we
    // snap the view back to the current week and re-pull events, so a window
    // left open overnight reads correctly by morning. The 30s tick also fires
    // right after the machine wakes, so this catches a midnight that elapsed
    // during sleep: within 30s of unlocking you're back on the current week.
    property var _viewDay: startOfDay(new Date())
    onNowChanged: {
        if (!sameDay(now, _viewDay)) {
            _viewDay = startOfDay(now);
            weekAnchor = mondayOf(now);
            reload();
        }
    }

    // ---- text zoom ----
    // Browser-style Ctrl+= / Ctrl+- / Ctrl+0 drive this; every font.pixelSize
    // (and any box sized to hold text — gutter width, header height, today
    // pill) reads through fs() so layouts stretch in proportion. The scale
    // persists across launches via ~/.config/quickcalendar/font-scale; see
    // scaleReadProc / scaleSaveTimer / scaleWriteProc below.
    property real fontScale: 1.0
    readonly property real fontScaleMin: 0.7
    readonly property real fontScaleMax: 2.5
    readonly property real fontScaleStep: 0.1
    // Stays false until the persisted value has been loaded — keeps the
    // first onFontScaleChanged from racing the read and overwriting the
    // saved file with the default 1.0 before the read returns.
    property bool _fontScaleLoaded: false
    function fs(base) { return Math.round(base * fontScale); }
    function bumpFontScale(delta) {
        var v = Math.round((fontScale + delta) * 10) / 10;
        fontScale = Math.max(fontScaleMin, Math.min(fontScaleMax, v));
    }
    onFontScaleChanged: { if (_fontScaleLoaded) scaleSaveTimer.restart(); }

    // Calendars eligible for the "new event" picker. Readonly subscriptions
    // (F1, UFC, etc.) are filtered out — you can't add events to a feed
    // you don't own. Remaining calendars sharing (add_group, add_url) are
    // collapsed into one row, e.g. all iCloud feeds → one "iCloud" entry.
    readonly property var groupedCalendars: {
        var groups = {};
        var order = [];
        for (var i = 0; i < calendars.length; i++) {
            var c = calendars[i];
            if (c.readonly) continue;
            var groupKey = c.add_group
                ? "g::" + c.add_group + "||" + c.add_url
                : "u::" + i;
            if (!groups[groupKey]) {
                groups[groupKey] = {
                    label: c.add_group || c.label,
                    add_url: c.add_url,
                    urls: [],
                    is_group: !!c.add_group,
                };
                order.push(groupKey);
            }
            groups[groupKey].urls.push(c.url);
        }
        return order.map(function(k) { return groups[k]; });
    }

    // ---- date helpers ----
    function startOfDay(d) {
        var x = new Date(d);
        x.setHours(0, 0, 0, 0);
        return x;
    }
    function mondayOf(d) {
        var x = startOfDay(d);
        // JS: Sunday=0..Saturday=6. We want Monday=0..Sunday=6.
        var dow = (x.getDay() + 6) % 7;
        x.setDate(x.getDate() - dow);
        return x;
    }
    function addDays(d, n) {
        var x = new Date(d);
        x.setDate(x.getDate() + n);
        return x;
    }
    function sameDay(a, b) {
        return a.getFullYear() === b.getFullYear()
            && a.getMonth() === b.getMonth()
            && a.getDate() === b.getDate();
    }
    // Number of whole local-calendar days from a to b (b - a), independent of
    // timezone offsets. Subtracting JS Dates directly gives UTC milliseconds,
    // which trips over BST/GMT for all-day events whose ICS DTEND is a
    // naive UTC midnight — the off-by-one we hit on "Jen UWE summer ball".
    function localDayDiff(a, b) {
        var d1 = new Date(a.getFullYear(), a.getMonth(), a.getDate());
        var d2 = new Date(b.getFullYear(), b.getMonth(), b.getDate());
        return Math.round((d2 - d1) / 86400000);
    }
    function fmtTime(d) { return Qt.formatTime(d, "HH:mm"); }
    function fmtRange(a, b) {
        if (sameDay(a, b)) return fmtTime(a) + "–" + fmtTime(b);
        return Qt.formatDateTime(a, "ddd HH:mm") + "–" + Qt.formatDateTime(b, "ddd HH:mm");
    }

    // ---- per-calendar colour ----
    //
    // Source of truth: each calendar from calendars.txt can declare an explicit
    // `# colour: #hex` tag. When set, we derive the bg/stripe/text/dot from
    // *its* hue+saturation; only the lightness changes between roles. When no
    // colour is set, hash the URL into a hue so the same feed keeps the same
    // tint across runs without any config.
    readonly property var calsByUrl: {
        var m = {};
        for (var i = 0; i < calendars.length; i++) m[calendars[i].url] = calendars[i];
        return m;
    }

    function _hashHue(s) {
        var h = 0;
        for (var i = 0; i < (s || "").length; i++) {
            h = ((h << 5) - h + s.charCodeAt(i)) | 0;
        }
        return Math.abs(h) % 360;
    }

    function _hexToHsl(hex) {
        var s = String(hex).replace("#", "").trim();
        if (s.length === 3)
            s = s[0]+s[0] + s[1]+s[1] + s[2]+s[2];
        var r = parseInt(s.substring(0, 2), 16) / 255;
        var g = parseInt(s.substring(2, 4), 16) / 255;
        var b = parseInt(s.substring(4, 6), 16) / 255;
        if (isNaN(r) || isNaN(g) || isNaN(b)) return null;
        var mx = Math.max(r, g, b), mn = Math.min(r, g, b);
        var l = (mx + mn) / 2;
        var h = 0, sat = 0;
        if (mx !== mn) {
            var d = mx - mn;
            sat = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
            if      (mx === r) h = (g - b) / d + (g < b ? 6 : 0);
            else if (mx === g) h = (b - r) / d + 2;
            else               h = (r - g) / d + 4;
            h /= 6;
        }
        return { h: h, s: sat, l: l };
    }

    function _calHs(url) {
        var cal = calsByUrl[url];
        if (cal && cal.color) {
            var h = _hexToHsl(cal.color);
            // Floor saturation so configured-but-near-grey colours still
            // produce a visible chip.
            if (h) return { h: h.h, s: Math.max(0.35, h.s) };
        }
        return { h: _hashHue(url) / 360, s: 0.55 };
    }

    function calBg(url)     { var c = _calHs(url); return Qt.hsla(c.h, Math.max(0.4, c.s * 0.85), 0.93, 1); }
    function calStripe(url) { var c = _calHs(url); return Qt.hsla(c.h, c.s, 0.46, 1); }
    function calText(url)   { var c = _calHs(url); return Qt.hsla(c.h, Math.min(0.8, c.s), 0.22, 1); }
    function calDot(url)    { var c = _calHs(url); return Qt.hsla(c.h, c.s, 0.50, 1); }

    // ---- header label for the visible week ----
    function weekTitle() {
        var a = weekAnchor;
        var b = addDays(a, 6);
        if (a.getMonth() === b.getMonth())
            return Qt.formatDate(a, "MMMM yyyy");
        if (a.getFullYear() === b.getFullYear())
            return Qt.formatDate(a, "MMM") + " – " + Qt.formatDate(b, "MMM yyyy");
        return Qt.formatDate(a, "MMM yyyy") + " – " + Qt.formatDate(b, "MMM yyyy");
    }

    // ---- data loading ----
    function reload() {
        if (loading) return;
        loading = true;
        eventsProc.running = false;
        eventsProc.running = true;
    }
    function refresh() {
        // Force a re-fetch of the ICS feeds, then reload.
        refreshProc.running = false;
        refreshProc.running = true;
    }
    function openInBrowser(url) {
        openProc.command = ["xdg-open", url];
        openProc.running = false;
        openProc.running = true;
    }
    function openEventDetails(e) { selectedEvent = e; }
    function closeEventDetails() { selectedEvent = null; }

    // Triggered by the digit shortcuts (1-9) while the FAB menu is open, and
    // also by mouse clicks on the menu rows. Closes the menu and dispatches
    // the calendar's add-URL through the focused-browser opener.
    function selectCalendar(idx) {
        if (idx < 0 || idx >= groupedCalendars.length) return;
        var cal = groupedCalendars[idx];
        newEventMenuOpen = false;
        openInBrowser(cal.add_url);
    }

    // Cached hash of the last reload's actual content (calendars + events,
    // minus the generated_at timestamp). If the next reload computes the
    // same hash, we skip reassigning root.events entirely — no Repeater
    // rebuild, no relayout pass, no risk of a single-frame visual artefact.
    // The most common "refresh" — quickcalendar-sync.timer touching the cache
    // every minute with identical content — becomes a true no-op.
    property string _lastContentKey: ""

    Process {
        id: eventsProc
        // 60-day lookahead, 30-day lookback covers ±4 weeks of navigation.
        // quickcalendar-sync is fast on cached ICS so the wide window is cheap.
        command: ["quickcalendar-sync", "list", "1440", "--back", "720", "--json"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var d = JSON.parse(text);
                    root.lastSync = d.generated_at || "";

                    // Build a compact canonical signature of the bits that
                    // actually drive the UI. Skipping description here is
                    // deliberate: it can be a megabyte of HTML and changing
                    // it doesn't move any chip on the grid. The modal pulls
                    // description fresh from root.events when opened, so a
                    // body-only edit will surface next time you click in.
                    var key = JSON.stringify({
                        cs: (d.calendars || []).map(function(c) {
                            return [c.url, c.label, c.color || ""];
                        }),
                        es: (d.events || []).map(function(e) {
                            return [
                                e.uid, e.occ_key, e.start, e.end,
                                e.summary, e.location || "",
                                e.meet_url || "", !!e.recurring,
                                e.calendar_url,
                                (e.alarms || []).length,
                            ];
                        }),
                    });
                    if (key === root._lastContentKey) {
                        root.loading = false;
                        return;
                    }
                    root._lastContentKey = key;

                    root.calendars = d.calendars || [];
                    root.events = (d.events || []).map(function(e) {
                        e._start = new Date(e.start);
                        e._end = new Date(e.end);
                        return e;
                    });
                } catch (e) {
                    console.warn("quickcalendar: failed to parse json:", e);
                }
                root.loading = false;
            }
        }
        stderr: StdioCollector {
            onStreamFinished: { if (text.length > 0) console.warn("quickcalendar-sync:", text); }
        }
    }

    Process {
        id: refreshProc
        command: ["quickcalendar-sync", "refresh"]
        running: false
        onExited: root.reload()
    }

    Process {
        id: openProc
        command: ["true"]
        running: false
    }

    // ---- font-scale persistence ----
    // Read once at startup. On first launch the file doesn't exist; cat
    // prints nothing and we stay at the default. A bad/garbled value also
    // falls back to default. After this returns we flip _fontScaleLoaded so
    // user edits start triggering writes.
    Process {
        id: scaleReadProc
        command: ["sh", "-c", "cat ${XDG_CONFIG_HOME:-$HOME/.config}/quickcalendar/font-scale 2>/dev/null"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var v = parseFloat(text);
                if (!isNaN(v) && v >= root.fontScaleMin && v <= root.fontScaleMax) {
                    root.fontScale = Math.round(v * 10) / 10;
                }
                root._fontScaleLoaded = true;
            }
        }
    }

    // Debounce writes so a flurry of Ctrl++ presses produces one write.
    Timer {
        id: scaleSaveTimer
        interval: 400
        repeat: false
        onTriggered: {
            scaleWriteProc.command = [
                "sh", "-c",
                'mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/quickcalendar" && '
                + 'printf "%s" "$0" > "${XDG_CONFIG_HOME:-$HOME/.config}/quickcalendar/font-scale"',
                String(root.fontScale),
            ];
            scaleWriteProc.running = false;
            scaleWriteProc.running = true;
        }
    }
    Process { id: scaleWriteProc; command: ["true"]; running: false }

    // ---- file-watch auto-reload ----
    // `quickcalendar-sync paths` prints, one per line, every path that should
    // re-trigger a reload when it changes: calendars.txt first, then each
    // feed's cache .ics. Run it at startup AND whenever calendars.txt
    // itself changes (so a newly-added feed immediately gets its watcher).
    property var watchPaths: []
    Process {
        id: pathsProc
        command: ["quickcalendar-sync", "paths"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = text.split("\n").filter(function(p) { return p.length > 0; });
                root.watchPaths = lines;
            }
        }
    }

    // Coalesce a flurry of fs events (quickcalendar-sync refresh writes every
    // cache file in quick succession) into a single reload(). 250ms is short
    // enough to feel instant but long enough to swallow the burst.
    Timer {
        id: reloadDebounce
        interval: 250
        repeat: false
        onTriggered: root.reload()
    }

    // One FileView per watched path. We never call text()/data() — only the
    // fileChanged signal is interesting — so the file content isn't loaded
    // into memory. blockAllReads + an empty default keeps it lazy.
    Instantiator {
        model: root.watchPaths
        delegate: FileView {
            path: modelData
            watchChanges: true
            blockAllReads: true
            printErrors: false
            onFileChanged: {
                reloadDebounce.restart();
                // calendars.txt changing means the set of feeds may have
                // shifted — re-fetch the path list so a newly-added cache
                // file gets its own watcher attached.
                if (String(modelData).endsWith("/calendars.txt")) {
                    pathsProc.running = true;
                }
            }
        }
    }

    Component.onCompleted: {
        scaleReadProc.running = true;
        pathsProc.running = true;
        reload();
    }

    // ---- keybinds ----
    Shortcut {
        sequence: "Escape"
        // Esc closes whichever popup is open. It deliberately does NOT close
        // the window — that's Super+Q's job (less risk of an accidental hit
        // killing the calendar mid-task).
        onActivated: {
            if (root.selectedEvent) root.selectedEvent = null;
            else if (root.newEventMenuOpen) root.newEventMenuOpen = false;
        }
    }
    Shortcut { sequence: "T"; onActivated: { root.weekAnchor = root.mondayOf(new Date()); } }

    // Browser-style text zoom. Ctrl+= is the unshifted "+", Ctrl++ catches
    // keyboards that report Shift+= as a real "+", Ctrl+- shrinks, Ctrl+0
    // resets — same triad every Linux browser uses.
    Shortcut { sequences: ["Ctrl+=", "Ctrl++"]; onActivated: root.bumpFontScale(root.fontScaleStep) }
    Shortcut { sequence: "Ctrl+-"; onActivated: root.bumpFontScale(-root.fontScaleStep) }
    Shortcut { sequence: "Ctrl+0"; onActivated: root.fontScale = 1.0 }
    Shortcut { sequences: ["Left", "H"]; onActivated: { root.weekAnchor = root.addDays(root.weekAnchor, -7); } }
    Shortcut { sequences: ["Right", "L"]; onActivated: { root.weekAnchor = root.addDays(root.weekAnchor, 7); } }
    Shortcut { sequence: "N"; onActivated: { if (root.calendars.length > 0) root.newEventMenuOpen = !root.newEventMenuOpen; } }

    // After N opens the menu, 1-9 picks a calendar. The shortcuts are gated
    // on newEventMenuOpen so the digits don't steal keys at any other time. The
    // FAB menu rarely has more than 4 entries, but supporting up to 9 keeps
    // things future-proof without much cost.
    Shortcut { sequence: "1"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 1; onActivated: root.selectCalendar(0) }
    Shortcut { sequence: "2"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 2; onActivated: root.selectCalendar(1) }
    Shortcut { sequence: "3"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 3; onActivated: root.selectCalendar(2) }
    Shortcut { sequence: "4"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 4; onActivated: root.selectCalendar(3) }
    Shortcut { sequence: "5"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 5; onActivated: root.selectCalendar(4) }
    Shortcut { sequence: "6"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 6; onActivated: root.selectCalendar(5) }
    Shortcut { sequence: "7"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 7; onActivated: root.selectCalendar(6) }
    Shortcut { sequence: "8"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 8; onActivated: root.selectCalendar(7) }
    Shortcut { sequence: "9"; enabled: root.newEventMenuOpen && root.groupedCalendars.length >= 9; onActivated: root.selectCalendar(8) }

    // ---- layout ----
    Item {
        anchors.fill: parent

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            // ============================== HEADER ==============================
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.fs(64)
                color: root.card
                border.color: root.border
                border.width: 0

                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1; color: root.border
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 24
                    anchors.rightMargin: 24
                    spacing: 16

                    Text {
                        text: root.weekTitle()
                        font.pixelSize: root.fs(22)
                        font.weight: Font.DemiBold
                        color: root.text
                    }

                    Item { Layout.fillWidth: true }

                    // Nav cluster: ‹  Today  ›
                    Row {
                        spacing: 4
                        NavButton { glyph: "‹"; onClicked: { root.weekAnchor = root.addDays(root.weekAnchor, -7); } }
                        TodayButton { onClicked: { root.weekAnchor = root.mondayOf(new Date()); } }
                        NavButton { glyph: "›"; onClicked: { root.weekAnchor = root.addDays(root.weekAnchor, 7); } }
                    }

                    // Refresh button
                    IconButton {
                        glyph: root.loading ? "⏳" : "⟳"
                        tooltip: "Refresh (R)"
                        onClicked: root.refresh()
                    }
                }
            }

            // ============================== WEEK GRID ==============================
            WeekGrid {
                id: grid
                Layout.fillWidth: true
                Layout.fillHeight: true
                theme: root
                weekAnchor: root.weekAnchor
                events: root.events
            }

            // ============================== STATUS BAR ==============================
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.fs(32)
                color: root.card

                Rectangle {
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1; color: root.border
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 18

                    ShortcutHint { keys: ["‹", "›"]; label: "week" }
                    ShortcutHint { keys: ["T"]; label: "today" }
                    ShortcutHint { keys: ["N"]; label: "new event" }
                    ShortcutHint { keys: ["⌃+", "⌃−"]; label: "zoom" }

                    Item { Layout.fillWidth: true }

                    // ---- calendar legend ----
                    // Coloured dot + label per configured calendar, with a
                    // subtle vertical separator between entries. All calendars
                    // listed including readonly ones (F1/UFC) so the legend
                    // explains every colour you'll see in the grid.
                    Row {
                        spacing: 10
                        Layout.alignment: Qt.AlignVCenter
                        Repeater {
                            model: root.calendars
                            delegate: Row {
                                spacing: 10
                                Rectangle {
                                    width: 1; height: 12
                                    color: root.border
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: index > 0
                                }
                                Rectangle {
                                    width: 8; height: 8; radius: 4
                                    color: root.calDot(modelData.url)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: modelData.label
                                    color: root.textMuted
                                    font.pixelSize: root.fs(11)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: {
                            if (root.loading) return "syncing…";
                            if (!root.lastSync) return "";
                            var d = new Date(root.lastSync);
                            return "last sync " + Qt.formatDateTime(d, "HH:mm:ss");
                        }
                        color: root.textFaint
                        font.pixelSize: root.fs(11)
                    }
                }
            }
        }

        // ============================== FAB ==============================
        Rectangle {
            id: newEventBtn
            width: 56; height: 56
            radius: 28
            color: newEventBtnMouse.containsMouse ? root.newEventBtnHoverColor : root.newEventBtnColor
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 28
            anchors.bottomMargin: 44   // sit above the status bar
            border.width: 0

            // Soft drop shadow approximation: a slightly larger, translucent
            // sibling underneath. Qt's DropShadow effect needs an extra plugin
            // and tends to look fuzzy at small radii — a flat halo reads cleaner.
            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -4
                radius: parent.radius + 4
                color: Qt.rgba(0, 0, 0, 0.12)
            }

            Text {
                anchors.centerIn: parent
                text: "+"
                color: "#ffffff"
                font.pixelSize: root.fs(28)
                font.weight: Font.Medium
                // Optical centering: the "+" glyph sits slightly above the
                // visual centre, so nudge it down a hair.
                anchors.verticalCenterOffset: 1
            }

            MouseArea {
                id: newEventBtnMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.newEventMenuOpen = !root.newEventMenuOpen
            }

            Behavior on color { ColorAnimation { duration: 100 } }
        }

        // ============================== FAB MENU ==============================
        // Click-catcher behind the menu — clicking outside closes it.
        MouseArea {
            anchors.fill: parent
            visible: root.newEventMenuOpen
            onClicked: root.newEventMenuOpen = false
            // Don't intercept clicks on the menu itself: it sits above this.
        }

        // ============================== DETAILS MODAL ==============================
        DetailsModal {
            theme: root
            event: root.selectedEvent
            onClosed: root.selectedEvent = null
            onOpenUrl: function(url) { root.openInBrowser(url); root.selectedEvent = null; }
        }

        Rectangle {
            id: newEventMenu
            visible: root.newEventMenuOpen
            width: Math.max(240, menuCol.implicitWidth + 24)
            height: menuCol.implicitHeight + 16
            radius: 12
            color: root.card
            border.color: root.border
            border.width: 1

            // Anchor above-left of FAB so the menu grows up-and-left
            // (the FAB is in the bottom-right corner).
            anchors.right: newEventBtn.right
            anchors.bottom: newEventBtn.top
            anchors.bottomMargin: 12

            Rectangle {
                z: -1
                anchors.fill: parent
                anchors.margins: -3
                radius: parent.radius + 3
                color: Qt.rgba(0, 0, 0, 0.10)
            }

            ColumnLayout {
                id: menuCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 2

                Text {
                    text: "Add to calendar"
                    font.pixelSize: root.fs(11)
                    font.weight: Font.DemiBold
                    color: root.textFaint
                    Layout.leftMargin: 8
                    Layout.topMargin: 4
                    Layout.bottomMargin: 4
                }

                Repeater {
                    model: root.groupedCalendars
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.fs(36)
                        radius: 8
                        color: rowMouse.containsMouse ? root.surface : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10

                            // Colour dot — single colour for ungrouped, a small
                            // row of dots for a grouped entry so you see which
                            // feeds it covers.
                            Item {
                                width: 10 + Math.max(0, modelData.urls.length - 1) * 8
                                height: 10
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: -2
                                    Repeater {
                                        model: modelData.urls
                                        delegate: Rectangle {
                                            width: 10; height: 10; radius: 5
                                            color: root.calDot(modelData)
                                            border.color: root.card
                                            border.width: 1
                                        }
                                    }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: modelData.label
                                color: root.text
                                font.pixelSize: root.fs(13)
                                elide: Text.ElideRight
                            }
                            // Keyboard hint — press this digit (after N) to
                            // pick the calendar without leaving the keyboard.
                            KbdBadge {
                                label: String(index + 1)
                                visible: index < 9
                            }
                        }

                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.newEventMenuOpen = false;
                                root.openInBrowser(modelData.add_url);
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- small reusable button components ----
    component NavButton: Rectangle {
        property string glyph: ""
        signal clicked()
        width: root.fs(32); height: root.fs(32); radius: 8
        color: navMouse.containsMouse ? root.surface : "transparent"
        border.color: root.border
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: parent.glyph
            color: root.text
            font.pixelSize: root.fs(16)
            anchors.verticalCenterOffset: -1
        }
        MouseArea {
            id: navMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    component TodayButton: Rectangle {
        signal clicked()
        height: root.fs(32)
        width: todayLabel.implicitWidth + 22
        radius: 8
        color: todayMouse.containsMouse ? root.surface : "transparent"
        border.color: root.border
        border.width: 1
        Text {
            id: todayLabel
            anchors.centerIn: parent
            text: "Today"
            color: root.text
            font.pixelSize: root.fs(12)
            font.weight: Font.Medium
        }
        MouseArea {
            id: todayMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
        }
    }

    // Small keyboard-key looking badge for the status bar and the picker rows.
    // Reads "this key triggers the action sitting next to it."
    component KbdBadge: Rectangle {
        property string label: ""
        implicitHeight: root.fs(18)
        implicitWidth: Math.max(root.fs(20), badgeText.implicitWidth + 10)
        radius: 4
        color: root.surface
        border.color: root.borderStrong
        border.width: 1
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: parent.label
            font.pixelSize: root.fs(10)
            font.family: "monospace"
            color: root.text
        }
    }

    // A keyboard hint = one or more KbdBadges followed by a label describing
    // what the keys do. Wrapping this in a row component keeps the status-bar
    // layout readable.
    component ShortcutHint: Row {
        property var keys: []
        property string label: ""
        spacing: 6
        Row {
            spacing: 2
            Repeater {
                model: parent.parent.keys
                delegate: KbdBadge { label: modelData }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.label
            color: root.textMuted
            font.pixelSize: root.fs(11)
            leftPadding: 2
        }
    }

    component IconButton: Rectangle {
        property string glyph: ""
        property string tooltip: ""
        signal clicked()
        width: root.fs(32); height: root.fs(32); radius: 8
        color: iconMouse.containsMouse ? root.surface : "transparent"
        border.color: root.border
        border.width: 1
        Text {
            anchors.centerIn: parent
            text: parent.glyph
            color: root.text
            font.pixelSize: root.fs(15)
        }
        MouseArea {
            id: iconMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.clicked()
            ToolTip.text: parent.tooltip
            ToolTip.visible: parent.tooltip !== "" && containsMouse
            ToolTip.delay: 600
        }
    }
}
