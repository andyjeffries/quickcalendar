// A single event rendered as a colored block. Two density modes:
//   compact: true  — used for all-day chips (one row)
//   compact: false — used for timed events in the hour grid (multi-line)
//
// Colors are derived from the source calendar's URL (stable hash → HSL),
// so the same calendar gets the same tint across runs and machines.

import QtQuick
import QtQuick.Controls

Rectangle {
    id: blk
    property var theme
    property var event
    property bool compact: false

    radius: 6
    color: theme.calBg(event.calendar_url)
    border.width: 0
    clip: true

    signal clicked()

    // Left accent stripe — the only thing keeping the tinted background from
    // visually merging with the day's tint when both are light.
    Rectangle {
        width: 3
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        radius: 0
        color: theme.calStripe(blk.event.calendar_url)
    }

    // ---- per-event hint badges (meet / recurring / alarm) ----
    // Reused in both compact and full layouts. FontAwesome glyphs from the
    // JetBrainsMono Nerd Font give us monochrome SVG-quality icons that
    // inherit the chip's calText colour — no PNG/SVG bundle needed, and
    // they don't fight the colour palette like emoji do. Codepoints are
    // written as \uXXXX escapes so the source survives editor round-trips
    // that strip PUA glyphs.
    component Badges: Row {
        spacing: 4
        Text {
            visible: !!blk.event.meet_url && blk.event.meet_url.length > 0
            text: "\uF03D"  // FontAwesome 4: video-camera
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: blk.theme.fs(11)
            color: blk.theme.calText(blk.event.calendar_url)
            opacity: 0.85
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: blk.event.recurring === true
            text: "\uF021"  // FontAwesome 4: refresh
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: blk.theme.fs(11)
            color: blk.theme.calText(blk.event.calendar_url)
            opacity: 0.85
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: !!blk.event.alarms && blk.event.alarms.length > 0
            text: "\uF0F3"  // FontAwesome 4: bell
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: blk.theme.fs(11)
            color: blk.theme.calText(blk.event.calendar_url)
            opacity: 0.85
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ---- compact (all-day) ----
    Item {
        visible: blk.compact
        anchors.fill: parent

        Badges {
            id: compactBadges
            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.right: compactBadges.left
            anchors.rightMargin: compactBadges.width > 0 ? 4 : 0
            anchors.verticalCenter: parent.verticalCenter
            text: blk.event.summary
            color: blk.theme.calText(blk.event.calendar_url)
            font.pixelSize: blk.theme.fs(11)
            font.weight: Font.Medium
            elide: Text.ElideRight
        }
    }

    // ---- full (timed) ----
    Item {
        visible: !blk.compact
        anchors.fill: parent

        // Badges sit top-right so they ride the summary line — that line is
        // always visible no matter how short the block. Putting them at the
        // bottom would race the location row in tall events and disappear
        // entirely under short ones.
        Badges {
            id: fullBadges
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: 5
            anchors.topMargin: 4
        }

        Column {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.leftMargin: 8
            anchors.rightMargin: 4
            anchors.topMargin: 4
            anchors.bottomMargin: 4
            spacing: 1

            Text {
                // Summary shares the top line with the badges, so reserve
                // their width on the right to keep them from sitting on
                // top of the text.
                text: blk.event.summary
                color: blk.theme.calText(blk.event.calendar_url)
                font.pixelSize: blk.theme.fs(11)
                font.weight: Font.DemiBold
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                width: parent.width - (fullBadges.width > 0 ? fullBadges.width + 6 : 0)
            }
            Text {
                text: blk.theme.fmtRange(blk.event._start, blk.event._end)
                color: blk.theme.calText(blk.event.calendar_url)
                opacity: 0.75
                font.pixelSize: blk.theme.fs(10)
                elide: Text.ElideRight
                width: parent.width
                visible: blk.height >= 32
            }
            Text {
                text: blk.event.location
                color: blk.theme.calText(blk.event.calendar_url)
                opacity: 0.65
                font.pixelSize: blk.theme.fs(10)
                elide: Text.ElideRight
                width: parent.width
                visible: blk.event.location && blk.event.location.length > 0 && blk.height >= 48
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: blk.clicked()
        ToolTip.visible: containsMouse
        ToolTip.delay: 500
        ToolTip.text: {
            var parts = [blk.event.summary,
                         blk.theme.fmtRange(blk.event._start, blk.event._end),
                         "[" + blk.event.calendar_label + "]"];
            if (blk.event.location) parts.push(blk.event.location);
            return parts.join("\n");
        }
    }
}
