// 7-day grid: day-of-week headers, optional all-day row, scrollable hourly grid,
// per-day overlap-aware event packing, today highlight, and a current-time line.

import QtQuick
import QtQuick.Layouts

Item {
    id: grid

    // ---- inputs ----
    property var theme        // the FloatingWindow root — provides colors + helpers
    property date weekAnchor  // Monday of the visible week (local midnight)
    property var events       // array of event objects from quickcalendar-sync --json

    // ---- visual config ----
    // hourHeight stretches with the viewport so the day always overflows the
    // visible area enough for "8am at top" to land cleanly. If the window is
    // tall enough that 24 fixed-height rows (24 × 52 = 1248 px) all fit at
    // once, the Flickable would clamp contentY to 0 and the initial-scroll
    // becomes a no-op — that's the bug ws1-dashboard exposed.
    //
    // Sizing math: for 8am to be paintable at the top we need
    //   contentHeight - viewportHeight ≥ 8 × hourHeight
    //   24 × hh - vp ≥ 8 × hh  →  hh ≥ vp / 16
    // We use grid.height (the whole WeekGrid) as a proxy for vp; the
    // estimate is fine since the chrome (header + all-day row) is small
    // relative to a tall window, and the extra +4 keeps us off the boundary.
    readonly property int hourHeightMin: theme ? theme.fs(52) : 52
    readonly property int hourHeightMax: theme ? theme.fs(120) : 120
    readonly property int hourHeight: {
        if (grid.height <= 0) return hourHeightMin;
        var needed = Math.ceil(grid.height / 16) + 4;
        return Math.min(hourHeightMax, Math.max(hourHeightMin, needed));
    }
    onHourHeightChanged: relayout()

    property int timeGutterWidth: theme ? theme.fs(56) : 56
    property int dayHeaderHeight: theme ? theme.fs(60) : 60

    // ---- derived ----
    readonly property real dayColumnWidth: Math.max(60, (width - timeGutterWidth) / 7)
    readonly property var weekDays: {
        var arr = [];
        for (var i = 0; i < 7; i++) arr.push(theme.addDays(weekAnchor, i));
        return arr;
    }
    readonly property real gridContentHeight: 24 * hourHeight

    // Populated by relayout(). Bindings inside derived `readonly property var`
    // bodies were being cached past `events` changes — driving the lists from
    // a single function avoids the staleness.
    property var timedEvents: []
    property var allDayEvents: []

    // ---- now line ----
    // Reads the root's shared live clock (theme.now) so the now-line and the
    // today-highlight all advance off the one 30s tick that also drives the
    // midnight rollover in shell.qml — no second timer, no stale `new Date()`.
    readonly property date currentTime: grid.theme ? grid.theme.now : new Date()

    // ---- visual config (extra all-day) ----
    readonly property int allDayChipHeight: theme ? theme.fs(22) : 22
    readonly property int allDayChipGap: 3
    readonly property int allDayRowPadding: 5

    // ---- event packing (overlap-aware lane assignment) ----
    property var laidOutTimed: []
    property var laidOutAllDay: []   // [{event, x, w, lane}]
    property int allDayLanes: 1

    function relayout() {
        if (!theme || !events) { laidOutTimed = []; timedEvents = []; allDayEvents = []; return; }

        var winStart = weekAnchor;
        var winEnd = theme.addDays(weekAnchor, 7);

        var we = events.filter(function(ev) { return ev._end > winStart && ev._start < winEnd; });
        var te = [];
        var ad = [];
        for (var k = 0; k < we.length; k++) {
            if (we[k].all_day === true) ad.push(we[k]);
            else                        te.push(we[k]);
        }
        timedEvents = te;
        allDayEvents = ad;

        // Stack all-day events into vertical lanes so multi-day events
        // (e.g. a week-long "Rich here") don't paint under shorter ones.
        // Sort by start ascending, then by span descending so the longest
        // event tends to land on lane 0 — this matches the macOS Calendar /
        // Fantastical look where the long bar reads at the bottom and the
        // short chips sit above it.
        var W2 = dayColumnWidth;
        var laidAd = [];
        var items = ad.map(function(e) {
            var sd = Math.max(0, theme.localDayDiff(weekAnchor, e._start));
            var ed = Math.min(7, theme.localDayDiff(weekAnchor, e._end));
            return { event: e, startDay: sd, endDay: ed, span: Math.max(1, ed - sd), lane: 0 };
        });
        items.sort(function(a, b) {
            return (a.startDay - b.startDay) || (b.span - a.span);
        });

        var laneEndsAd = [];
        for (var m = 0; m < items.length; m++) {
            var it = items[m];
            var lane = -1;
            for (var ln = 0; ln < laneEndsAd.length; ln++) {
                if (laneEndsAd[ln] <= it.startDay) { lane = ln; break; }
            }
            if (lane < 0) { lane = laneEndsAd.length; laneEndsAd.push(0); }
            laneEndsAd[lane] = it.endDay;
            it.lane = lane;
            laidAd.push({
                event: it.event,
                x: timeGutterWidth + it.startDay * W2 + 3,
                w: it.span * W2 - 6,
                lane: lane,
            });
        }
        laidOutAllDay = laidAd;
        allDayLanes = Math.max(1, laneEndsAd.length);

        var out = [];
        var W = dayColumnWidth;
        var hh = hourHeight;
        for (var day = 0; day < 7; day++) {
            var dayStart = theme.addDays(weekAnchor, day);
            var dayEnd = theme.addDays(weekAnchor, day + 1);

            var items = [];
            for (var i = 0; i < te.length; i++) {
                var ev = te[i];
                if (ev._end <= dayStart || ev._start >= dayEnd) continue;
                var s = ev._start < dayStart ? dayStart : ev._start;
                var en = ev._end > dayEnd ? dayEnd : ev._end;
                var startMin = (s - dayStart) / 60000;
                var endMin = (en - dayStart) / 60000;
                // Minimum visual height so 5-minute events are still tappable.
                if (endMin - startMin < 15) endMin = startMin + 15;
                items.push({ e: ev, startMin: startMin, endMin: endMin, lane: 0, lanes: 1 });
            }
            items.sort(function(a, b) {
                return (a.startMin - b.startMin) || (a.endMin - b.endMin);
            });

            // Greedy lane packing within overlap clusters. A cluster ends when
            // the next event starts past every active lane's end.
            var clusters = [];
            var laneEnds = [];
            var curCluster = [];
            var clusterEnd = -Infinity;
            for (var j = 0; j < items.length; j++) {
                var it = items[j];
                if (it.startMin >= clusterEnd) {
                    if (curCluster.length > 0) clusters.push(curCluster);
                    curCluster = [j];
                    laneEnds = [it.endMin];
                    it.lane = 0;
                    clusterEnd = it.endMin;
                    continue;
                }
                var placed = false;
                for (var ln = 0; ln < laneEnds.length; ln++) {
                    if (laneEnds[ln] <= it.startMin) {
                        it.lane = ln;
                        laneEnds[ln] = it.endMin;
                        placed = true;
                        break;
                    }
                }
                if (!placed) {
                    it.lane = laneEnds.length;
                    laneEnds.push(it.endMin);
                }
                curCluster.push(j);
                clusterEnd = Math.max(clusterEnd, it.endMin);
            }
            if (curCluster.length > 0) clusters.push(curCluster);

            for (var c = 0; c < clusters.length; c++) {
                var maxLane = 0;
                for (var k = 0; k < clusters[c].length; k++)
                    maxLane = Math.max(maxLane, items[clusters[c][k]].lane);
                var lanes = maxLane + 1;
                for (var k2 = 0; k2 < clusters[c].length; k2++)
                    items[clusters[c][k2]].lanes = lanes;
            }

            for (var i2 = 0; i2 < items.length; i2++) {
                var it2 = items[i2];
                var laneW = W / it2.lanes;
                out.push({
                    event: it2.e,
                    x: timeGutterWidth + day * W + it2.lane * laneW + 2,
                    y: it2.startMin / 60 * hh,
                    w: Math.max(0, laneW - 4),
                    h: Math.max(20, (it2.endMin - it2.startMin) / 60 * hh - 2),
                });
            }
        }
        laidOutTimed = out;
    }

    onWidthChanged: relayout()
    onEventsChanged: { relayout(); tryInitialScroll(); }
    onWeekAnchorChanged: relayout()

    // Event x/y/w/h are snapshotted into laidOutTimed/laidOutAllDay — those
    // numbers don't re-derive when the gutter and column widths shift. Force
    // a relayout when the theme's font scale changes so blocks stay aligned
    // with their day columns after Ctrl++/Ctrl+-.
    Connections {
        target: grid.theme
        function onFontScaleChanged() { grid.relayout(); }
    }
    Component.onCompleted: {
        relayout();
        // Defer the initial scroll past the current layout pass: in
        // standalone launch the Flickable already has a usable height by
        // now, but when ws1-dashboard tiles us into a workspace the height
        // is still ~0 here. The Flickable's own onHeightChanged below
        // catches the tiled case.
        Qt.callLater(tryInitialScroll);
    }

    // Park 8am at the top on the *first* time the Flickable becomes properly
    // sized AND events have loaded, then stop touching contentY so the user
    // can scroll freely. Without the "events loaded" gate, the initial scroll
    // can win the race against the first relayout — height looks fine but
    // the all-day row is about to appear and push the Flickable down.
    property bool _initialScrollDone: false
    function tryInitialScroll() {
        if (_initialScrollDone) return;
        if (!flick || flick.height < 100) return;
        if (!events || events.length === 0) return;
        flick.contentY = 8 * hourHeight;
        _initialScrollDone = true;
    }

    // ============================== BACKGROUND ==============================
    Rectangle { anchors.fill: parent; color: theme.surface }

    // ============================== DAY HEADER ROW ==============================
    Item {
        id: headerRow
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: grid.dayHeaderHeight
        z: 3

        Rectangle { anchors.fill: parent; color: theme.card }

        // gutter spacer (matches the time-gutter width in the grid below)
        Rectangle {
            x: 0; y: 0; width: grid.timeGutterWidth; height: parent.height
            color: theme.card
            Rectangle {
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: 1; color: theme.border
            }
        }

        Repeater {
            model: 7
            delegate: Item {
                id: dayHeader
                x: grid.timeGutterWidth + index * grid.dayColumnWidth
                y: 0
                width: grid.dayColumnWidth
                height: grid.dayHeaderHeight
                property var date: grid.weekDays[index]
                property bool isToday: grid.theme.sameDay(date, grid.currentTime)

                Column {
                    anchors.centerIn: parent
                    spacing: 4
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDate(dayHeader.date, "ddd").toUpperCase()
                        font.pixelSize: grid.theme.fs(11)
                        font.weight: Font.DemiBold
                        font.letterSpacing: 0.6
                        color: dayHeader.isToday ? grid.theme.accent : grid.theme.textMuted
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: grid.theme.fs(32); height: grid.theme.fs(32); radius: grid.theme.fs(16)
                        color: dayHeader.isToday ? grid.theme.accent : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: dayHeader.date.getDate()
                            font.pixelSize: grid.theme.fs(16)
                            font.weight: dayHeader.isToday ? Font.DemiBold : Font.Normal
                            color: dayHeader.isToday ? "#ffffff" : grid.theme.text
                        }
                    }
                }

                // left edge divider
                Rectangle {
                    x: 0; y: 8; width: 1; height: dayHeader.height - 16
                    color: grid.theme.border
                }
            }
        }

        // bottom border
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1; color: theme.border
        }
    }

    // ============================== ALL-DAY ROW ==============================
    Item {
        id: allDayRow
        anchors { left: parent.left; right: parent.right; top: headerRow.bottom }
        visible: grid.laidOutAllDay.length > 0
        // Height grows with the number of lanes so overlapping multi-day
        // events stack vertically instead of painting on top of each other.
        height: visible
                ? grid.allDayLanes * grid.allDayChipHeight
                  + Math.max(0, grid.allDayLanes - 1) * grid.allDayChipGap
                  + grid.allDayRowPadding * 2
                : 0
        z: 2

        Rectangle { anchors.fill: parent; color: theme.card }

        Text {
            x: 8
            anchors.top: parent.top
            anchors.topMargin: grid.allDayRowPadding + 3
            text: "all-day"
            font.pixelSize: grid.theme.fs(10)
            color: grid.theme.textFaint
        }

        // column dividers
        Repeater {
            model: 7
            delegate: Rectangle {
                x: grid.timeGutterWidth + index * grid.dayColumnWidth
                y: 4; width: 1; height: parent.height - 8
                color: grid.theme.border
            }
        }

        // all-day event chips, positioned by the relayout() lane assignment
        Repeater {
            model: grid.laidOutAllDay
            delegate: EventBlock {
                theme: grid.theme
                event: modelData.event
                compact: true
                x: modelData.x
                y: grid.allDayRowPadding + modelData.lane * (grid.allDayChipHeight + grid.allDayChipGap)
                width: modelData.w
                height: grid.allDayChipHeight
                onClicked: grid.theme.openEventDetails(modelData.event)
            }
        }

        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1; color: theme.border
        }
    }

    // ============================== HOUR GRID (scrollable) ==============================
    Flickable {
        id: flick
        anchors {
            left: parent.left; right: parent.right
            top: allDayRow.visible ? allDayRow.bottom : headerRow.bottom
            bottom: parent.bottom
        }
        contentHeight: grid.gridContentHeight
        contentWidth: width
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        // When a tiling compositor sizes the window *after*
        // Component.onCompleted (rather than at creation), this handler
        // catches the moment the Flickable becomes usefully tall and pins
        // 8am to the top.
        onHeightChanged: grid.tryInitialScroll()

        // gutter background (keeps hour labels readable on top of column tint)
        Rectangle {
            x: 0; y: 0
            width: grid.timeGutterWidth
            height: grid.gridContentHeight
            color: grid.theme.surface
            Rectangle {
                anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                width: 1; color: grid.theme.border
            }
        }

        // day columns: today gets a tint, all get a left border
        Repeater {
            model: 7
            delegate: Item {
                id: dayCol
                x: grid.timeGutterWidth + index * grid.dayColumnWidth
                y: 0
                width: grid.dayColumnWidth
                height: grid.gridContentHeight
                property var date: grid.weekDays[index]
                property bool isToday: grid.theme.sameDay(date, grid.currentTime)

                Rectangle {
                    anchors.fill: parent
                    color: dayCol.isToday ? grid.theme.todayTint : "transparent"
                }
                Rectangle {
                    x: 0; y: 0; width: 1; height: dayCol.height
                    color: grid.theme.border
                }
            }
        }

        // hour separator lines + labels
        Repeater {
            model: 24
            delegate: Item {
                y: index * grid.hourHeight
                width: flick.contentWidth
                height: grid.hourHeight

                Text {
                    x: 6
                    // Sit just below the hour line, inside this hour's row, so
                    // when we scroll to N*hourHeight the "NN:00" label is the
                    // first thing visible (instead of being cropped 7px above).
                    y: 3
                    width: grid.timeGutterWidth - 10
                    horizontalAlignment: Text.AlignRight
                    text: Qt.formatTime(new Date(2000, 0, 1, index, 0), "HH:mm")
                    font.pixelSize: grid.theme.fs(10)
                    color: grid.theme.textFaint
                    visible: index > 0
                }

                Rectangle {
                    x: grid.timeGutterWidth
                    width: parent.width - grid.timeGutterWidth
                    y: 0
                    height: 1
                    color: grid.theme.border
                    visible: index > 0
                }
            }
        }

        // timed event blocks
        Repeater {
            model: grid.laidOutTimed
            delegate: EventBlock {
                theme: grid.theme
                event: modelData.event
                x: modelData.x
                y: modelData.y
                width: modelData.w
                height: modelData.h
                compact: false
                onClicked: grid.theme.openEventDetails(modelData.event)
            }
        }

        // ---- now line ----
        Item {
            id: nowLine
            property int todayCol: {
                var now = grid.currentTime;
                for (var i = 0; i < 7; i++) {
                    if (grid.theme.sameDay(grid.weekDays[i], now)) return i;
                }
                return -1;
            }
            visible: todayCol >= 0
            x: visible ? grid.timeGutterWidth + todayCol * grid.dayColumnWidth : 0
            width: grid.dayColumnWidth
            y: {
                var now = grid.currentTime;
                var minutes = now.getHours() * 60 + now.getMinutes() + now.getSeconds() / 60;
                return minutes / 60 * grid.hourHeight;
            }
            height: 2
            z: 10

            Rectangle {
                width: 8; height: 8; radius: 4
                color: grid.theme.nowLine
                anchors.verticalCenter: parent.top
                x: -4
            }
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.top
                height: 2
                color: grid.theme.nowLine
            }
        }
    }
}
