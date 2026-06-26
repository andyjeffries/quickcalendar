// Centred details popup for a single event. Backdrop dims the calendar
// behind it; clicking the backdrop or the × button (or pressing Esc, handled
// in shell.qml) closes. URLs in `location` and `description` are made into
// clickable <a> tags via a small linkifier; clicking one signals up to the
// host which routes the URL through ~/.local/bin/xdg-open so we
// reuse the user's existing browser window.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: root
    property var theme
    property var event   // null when hidden
    visible: event !== null && event !== undefined
    z: 100

    signal closed()
    signal openUrl(string url)

    anchors.fill: parent

    // Backdrop — eats clicks, dims background.
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.42)
        MouseArea {
            anchors.fill: parent
            onClicked: root.closed()
        }
    }

    // Card
    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 64, 560)
        height: Math.min(parent.height - 64, content.implicitHeight + 48)
        radius: 14
        color: theme ? theme.card : "#ffffff"
        border.color: theme ? theme.border : "#dddddd"
        border.width: 1

        // Soft drop shadow halo.
        Rectangle {
            z: -1
            anchors.fill: parent
            anchors.margins: -6
            radius: parent.radius + 6
            color: Qt.rgba(0, 0, 0, 0.16)
        }

        // Swallow clicks on the card so they don't bubble to the backdrop.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 24
            spacing: 14

            // ---- top row: calendar pill + close ----
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                    visible: root.event !== null
                    height: root.theme ? root.theme.fs(22) : 22
                    width: pillRow.implicitWidth + 16
                    radius: height / 2
                    color: root.event ? root.theme.calBg(root.event.calendar_url) : "transparent"

                    Row {
                        id: pillRow
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 6

                        Rectangle {
                            width: 8; height: 8; radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.event ? root.theme.calDot(root.event.calendar_url) : "transparent"
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.event ? root.event.calendar_label : ""
                            color: root.event ? root.theme.calText(root.event.calendar_url) : "#333"
                            font.pixelSize: root.theme ? root.theme.fs(11) : 11
                            font.weight: Font.Medium
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                Rectangle {
                    width: 28; height: 28; radius: 6
                    color: closeMouse.containsMouse ? (root.theme ? root.theme.surface : "#eee") : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: "×"
                        color: root.theme ? root.theme.textMuted : "#666"
                        font.pixelSize: root.theme ? root.theme.fs(20) : 20
                        anchors.verticalCenterOffset: -1
                    }
                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.closed()
                    }
                }
            }

            // ---- title ----
            Text {
                Layout.fillWidth: true
                text: root.event ? root.event.summary : ""
                color: root.theme ? root.theme.text : "#111"
                font.pixelSize: root.theme ? root.theme.fs(22) : 22
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
            }

            // ---- time ----
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text {
                    text: "🕒"
                    font.pixelSize: root.theme ? root.theme.fs(14) : 14
                    color: root.theme ? root.theme.textMuted : "#666"
                }
                Text {
                    Layout.fillWidth: true
                    color: root.theme ? root.theme.text : "#111"
                    font.pixelSize: root.theme ? root.theme.fs(13) : 13
                    text: root.event
                          ? (root.event.all_day
                             ? Qt.formatDate(root.event._start, "ddd d MMM yyyy") + "  (all day)"
                             : Qt.formatDate(root.event._start, "ddd d MMM yyyy")
                               + ",  " + Qt.formatTime(root.event._start, "HH:mm")
                               + " – " + Qt.formatTime(root.event._end, "HH:mm"))
                          : ""
                }
            }

            // ---- join meeting (Google Meet / Zoom / Teams) ----
            // Shown above location so it's the first actionable element you
            // see when joining is the whole reason you opened the modal.
            // BG tints to the event's calendar (calStripe = mid-saturation),
            // and the icon matches the FA video-camera glyph used in the
            // chip badges — same visual vocabulary, scaled up.
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: root.theme ? root.theme.fs(40) : 40
                visible: root.event && root.event.meet_url && root.event.meet_url.length > 0
                radius: 8
                color: {
                    if (!root.event || !root.theme) return "#3b82f6";
                    var base = root.theme.calStripe(root.event.calendar_url);
                    return joinMouse.containsMouse ? Qt.darker(base, 1.12) : base;
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 8
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "\uF03D"  // FontAwesome 4: video-camera
                        font.family: "JetBrainsMono Nerd Font"
                        color: "#ffffff"
                        font.pixelSize: root.theme ? root.theme.fs(14) : 14
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Join meeting"
                        color: "#ffffff"
                        font.pixelSize: root.theme ? root.theme.fs(13) : 13
                        font.weight: Font.DemiBold
                    }
                }

                MouseArea {
                    id: joinMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { if (root.event) root.openUrl(root.event.meet_url); }
                }

                Behavior on color { ColorAnimation { duration: 100 } }
            }

            // ---- location ----
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                visible: root.event && root.event.location && root.event.location.length > 0
                Text {
                    text: "📍"
                    font.pixelSize: root.theme ? root.theme.fs(14) : 14
                    color: root.theme ? root.theme.textMuted : "#666"
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: 2
                }
                Text {
                    id: locText
                    Layout.fillWidth: true
                    color: root.theme ? root.theme.text : "#111"
                    font.pixelSize: root.theme ? root.theme.fs(13) : 13
                    text: root.event ? root.linkify(root.event.location) : ""
                    wrapMode: Text.WordWrap
                    textFormat: Text.RichText
                    onLinkActivated: function(link) { root.openUrl(link); }
                    linkColor: root.theme ? root.theme.accent : "#3b82f6"

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }
            }

            // ---- description (scrolls if long) ----
            // Layout.fillHeight contributes 0 to implicit size, so the card
            // (which sizes to content.implicitHeight) would give this 0 px
            // and the description would be invisible. The implicitHeight
            // here makes the modal grow with the text, capped at half the
            // host height so a wall-of-text invite can't push the close
            // button off-screen.
            Flickable {
                Layout.fillWidth: true
                Layout.fillHeight: true
                implicitHeight: Math.min(descText.implicitHeight, root.height * 0.5)
                visible: root.event && root.event.description && root.event.description.length > 0
                contentWidth: width
                contentHeight: descText.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Text {
                    id: descText
                    width: parent.width
                    text: root.event ? root.linkify(root.event.description) : ""
                    color: root.theme ? root.theme.text : "#333"
                    font.pixelSize: root.theme ? root.theme.fs(13) : 13
                    wrapMode: Text.WordWrap
                    textFormat: Text.RichText
                    linkColor: root.theme ? root.theme.accent : "#3b82f6"
                    onLinkActivated: function(link) { root.openUrl(link); }

                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.NoButton
                        cursorShape: parent.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
                    }
                }
            }
        }
    }

    // ---- linkifier ----
    // Escape HTML specials and wrap http(s):// URLs in <a> tags. Trailing
    // sentence punctuation is shaved off so "see http://x.com." doesn't
    // include the period in the link target.
    function linkify(s) {
        if (!s) return "";
        var esc = String(s)
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;");
        var tail = ".,;:!?)]}";
        esc = esc.replace(/https?:\/\/[^\s<>"']+/g, function(m) {
            var trailing = "";
            while (m.length > 1 && tail.indexOf(m[m.length - 1]) >= 0) {
                trailing = m[m.length - 1] + trailing;
                m = m.substring(0, m.length - 1);
            }
            return '<a href="' + m + '">' + m + '</a>' + trailing;
        });
        return esc.replace(/\n/g, "<br/>");
    }
}
