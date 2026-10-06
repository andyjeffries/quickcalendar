// Month overlay: a Mon–Sun grid for a single month, slid in over the week view
// by the "M" shortcut. Each cell lists as many of that day's events as fit, and
// clicking a day selects it back in the week view (see shell.qml selectDate()).
//
// NB: named MonthOverlay, not MonthGrid, on purpose — QtQuick.Controls (imported
// by shell.qml) exports a built-in `MonthGrid` type that shadows a local
// component of the same name, silently hiding its custom properties/signals.
//
// Driven entirely off the same theme root as WeekGrid — it reuses the root's
// date helpers (mondayOf/addDays/…) and per-calendar colour functions so the
// chips match the week grid exactly. Cells are sized explicitly (plain Row/Grid
// positioners) rather than via QtQuick.Layouts, which mis-distributed the
// header vs. grid height here.

import QtQuick

Item {
    id: month

    // ---- inputs ----
    property var theme          // the FloatingWindow root — colours + helpers
    property var monthAnchor    // first-of-month (local midnight) to display
    property var events: []     // same array shell.qml feeds WeekGrid
    property var selectedDate: null

    signal daySelected(var day)

    // ---- derived ----
    readonly property date now: theme ? theme.now : new Date()
    // Monday of the week containing the 1st — top-left cell of the grid.
    readonly property var gridStart: theme ? theme.mondayOf(monthAnchor) : monthAnchor
    // How many week-rows this month needs (4–6). Based on the offset of the
    // last calendar day of the month from gridStart.
    readonly property int weeks: {
        if (!theme || !monthAnchor) return 6;
        var last = new Date(monthAnchor.getFullYear(), monthAnchor.getMonth() + 1, 0);
        var span = theme.localDayDiff(gridStart, last); // 0-based index of last day
        return Math.max(1, Math.ceil((span + 1) / 7));
    }

    // Grey fill for days outside the displayed month (a touch darker than the
    // surface so it's unmistakably "another month").
    readonly property color outOfMonthBg: "#eceef2"

    // ---- cell geometry ----
    readonly property real headerH: theme ? theme.fs(30) : 30
    readonly property real cellW: width / 7
    readonly property real cellH: Math.max(1, (height - headerH - 1) / Math.max(1, weeks))

    // Events overlapping a given local day, all-day first then by start time.
    function eventsForDay(day) {
        if (!theme || !events) return [];
        var out = [];
        for (var i = 0; i < events.length; i++) {
            if (theme.eventCoversDay(events[i], day)) out.push(events[i]);
        }
        out.sort(function(a, b) {
            var aa = a.all_day === true ? 0 : 1;
            var bb = b.all_day === true ? 0 : 1;
            if (aa !== bb) return aa - bb;
            return a._start - b._start;
        });
        return out;
    }

    // Opaque background so the week grid underneath never shows through.
    Rectangle { anchors.fill: parent; color: theme.surface }

    // ---- weekday header (Mon … Sun) ----
    Row {
        id: dowRow
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: month.headerH
        Repeater {
            model: 7
            delegate: Rectangle {
                width: month.cellW
                height: month.headerH
                color: theme.card
                Text {
                    anchors.centerIn: parent
                    text: Qt.formatDate(theme.addDays(month.gridStart, index), "ddd").toUpperCase()
                    font.pixelSize: theme.fs(11)
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.6
                    color: theme.textMuted
                }
            }
        }
    }
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: dowRow.bottom }
        height: 1
        color: theme.border
    }

    // ---- day grid ----
    Grid {
        anchors {
            left: parent.left; right: parent.right
            top: dowRow.bottom; topMargin: 1
            bottom: parent.bottom
        }
        columns: 7

        Repeater {
            model: month.weeks * 7
            delegate: Rectangle {
                id: cell
                width: month.cellW
                height: month.cellH
                clip: true

                property var cellDate: theme.addDays(month.gridStart, index)
                property bool inMonth: cellDate.getMonth() === month.monthAnchor.getMonth()
                property bool isToday: theme.sameDay(cellDate, month.now)
                property bool isSelected: month.selectedDate && theme.sameDay(cellDate, month.selectedDate)
                property var dayEvents: month.eventsForDay(cellDate)

                // Chip sizing + how many fit under the date number.
                readonly property int chipH: theme.fs(16)
                readonly property int chipGap: 2
                readonly property real chipsAvail: Math.max(0, height - dateRow.height - 4)
                readonly property int maxChips: Math.floor((chipsAvail + chipGap) / (chipH + chipGap))
                // Reserve one slot for the "+N more" line when we overflow.
                readonly property var shownEvents:
                    dayEvents.length > maxChips
                        ? dayEvents.slice(0, Math.max(0, maxChips - 1))
                        : dayEvents.slice(0, maxChips)
                readonly property int hiddenCount: dayEvents.length - shownEvents.length

                // Days spilling in from the adjacent months get a distinctly grey
                // fill (and dimmed content below) so their events read clearly as
                // belonging to another month, not the one on display.
                property color allDayTint: theme.dayTint(cellDate)
                color: !inMonth            ? month.outOfMonthBg
                     : allDayTint.a > 0    ? allDayTint
                     : isToday             ? theme.todayTint
                     :                       theme.card
                border.width: 1
                border.color: theme.border

                // ---- date number ----
                Item {
                    id: dateRow
                    anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: theme.fs(24)

                    Rectangle {
                        id: dayCircle
                        width: theme.fs(20); height: theme.fs(20); radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 4
                        color: cell.isToday ? theme.accent : "transparent"
                        border.color: (!cell.isToday && cell.isSelected) ? theme.accent : "transparent"
                        border.width: (!cell.isToday && cell.isSelected) ? 2 : 0
                        Text {
                            anchors.centerIn: parent
                            text: cell.cellDate.getDate()
                            font.pixelSize: theme.fs(12)
                            font.weight: cell.isToday ? Font.DemiBold : Font.Normal
                            color: cell.isToday ? "#ffffff"
                                 : (cell.inMonth ? theme.text : theme.textFaint)
                        }
                    }
                }

                // ---- event chips ----
                Column {
                    id: chipCol
                    anchors {
                        left: parent.left; right: parent.right
                        top: dateRow.bottom; bottom: parent.bottom
                        leftMargin: 3; rightMargin: 3; bottomMargin: 3
                    }
                    spacing: cell.chipGap
                    // Spilled-in days (adjacent months) show no events at all —
                    // only their greyed cell + faint date number remain.
                    visible: cell.inMonth

                    Repeater {
                        model: cell.shownEvents
                        delegate: Rectangle {
                            width: chipCol.width
                            height: cell.chipH
                            radius: 3
                            color: theme.calBg(modelData.calendar_url)
                            clip: true

                            Rectangle {
                                width: 2
                                anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                color: theme.calStripe(modelData.calendar_url)
                            }
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 5
                                anchors.rightMargin: 3
                                verticalAlignment: Text.AlignVCenter
                                text: modelData.all_day === true
                                      ? modelData.summary
                                      : theme.fmtTime(modelData._start) + "  " + modelData.summary
                                color: theme.calText(modelData.calendar_url)
                                font.pixelSize: theme.fs(10)
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Text {
                        visible: cell.hiddenCount > 0
                        width: chipCol.width
                        height: cell.chipH
                        leftPadding: 5
                        verticalAlignment: Text.AlignVCenter
                        text: "+" + cell.hiddenCount + " more"
                        color: theme.textMuted
                        font.pixelSize: theme.fs(10)
                        elide: Text.ElideRight
                    }
                }

                // Hover tint + click-to-select.
                Rectangle {
                    anchors.fill: parent
                    color: theme.accent
                    opacity: cellMouse.containsMouse ? 0.06 : 0
                    Behavior on opacity { NumberAnimation { duration: 80 } }
                }
                MouseArea {
                    id: cellMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: month.daySelected(cell.cellDate)
                }
            }
        }
    }
}
