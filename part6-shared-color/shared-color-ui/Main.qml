import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 640
    height: 520

    property int    deliveryStatus: 0
    property string currentColor: ""
    property string currentSenderId: ""
    property string myId: ""

    // Fixed palette. Add/remove freely — each entry is just {name, hex}.
    property var palette: [
        { name: "Red",    hex: "#ea4335" },
        { name: "Blue",   hex: "#1a73e8" },
        { name: "Green",  hex: "#34a853" },
        { name: "Yellow", hex: "#fbbc04" },
        { name: "Purple", hex: "#9334ea" },
        { name: "Orange", hex: "#f57c00" },
        { name: "Pink",   hex: "#ff6ec7" },
        { name: "Teal",   hex: "#00bfa5" },
        { name: "White",  hex: "#ffffff" }
    ]

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callColor(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("shared_color: logos bridge unavailable")
            return null
        }
        return logos.callModule("shared_color", method, args)
    }

    function unwrapRemote(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try { return JSON.parse(raw) } catch (e) { return defaultVal }
    }

    function refresh() {
        const sNum = unwrapRemote(callColor("deliveryStatus", []), 0)
        deliveryStatus = (typeof sNum === "number") ? sNum : 0

        if (myId === "") {
            const m = unwrapRemote(callColor("myId", []), "")
            myId = (typeof m === "string") ? m : ""
        }
        const c = unwrapRemote(callColor("currentColor", []), "")
        currentColor = (typeof c === "string") ? c : ""
        const s = unwrapRemote(callColor("currentSenderId", []), "")
        currentSenderId = (typeof s === "string") ? s : ""
    }

    function statusText(s) {
        if (s === 0) return "Off"
        if (s === 1) return "Connecting…"
        if (s === 2) return "Connected"
        if (s === 3) return "Error"
        return ""
    }
    function statusColor(s) {
        if (s === 2) return "#34a853"
        if (s === 1) return "#fbbc04"
        if (s === 3) return "#ea4335"
        return "#9aa5b1"
    }

    function textOn(hex) {
        if (!hex || hex.length < 7) return "#1f2d3d"
        const r = parseInt(hex.substr(1, 2), 16)
        const g = parseInt(hex.substr(3, 2), 16)
        const b = parseInt(hex.substr(5, 2), 16)
        const yiq = (r * 299 + g * 587 + b * 114) / 1000
        return yiq >= 160 ? "#1f2d3d" : "#ffffff"
    }

    function shortId(id) {
        if (!id) return ""
        return id.substring(0, 8)
    }

    // Tinted background — separate child instead of coloring root, because
    // Basecamp's sidebar host may not paint the root Item's color attribute.
    Rectangle {
        id: tint
        anchors.fill: parent
        color: currentColor.length > 0 ? currentColor : "#f4f6f9"
        Behavior on color { ColorAnimation { duration: 250 } }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 18

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Text {
                text: "Shared color"
                font.pixelSize: 26
                font.weight: Font.DemiBold
                color: textOn(tint.color.toString())
                Layout.fillWidth: true
            }
            Rectangle {
                width: 10; height: 10; radius: 5
                color: statusColor(deliveryStatus)
            }
            Text {
                text: statusText(deliveryStatus)
                color: textOn(tint.color.toString())
                opacity: 0.85
                font.pixelSize: 13
            }
            Button {
                text: deliveryStatus === 0 ? "Start" : "Stop"
                onClicked: {
                    if (deliveryStatus === 0) callColor("startDelivery", [])
                    else                      callColor("stopDelivery",  [])
                    refresh()
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 92
            radius: 12
            color: Qt.rgba(1, 1, 1, 0.65)
            border.color: "#dfe3e8"
            border.width: 1

            RowLayout {
                anchors.fill: parent
                anchors.margins: 14
                spacing: 14

                Rectangle {
                    width: 64; height: 64; radius: 10
                    color: currentColor.length > 0 ? currentColor : "#f0f0f0"
                    border.color: "#dfe3e8"
                    border.width: 1
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4
                    Text {
                        text: currentColor.length > 0
                              ? "Current: " + currentColor
                              : "No color set yet"
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        color: "#1f2d3d"
                    }
                    Text {
                        visible: currentSenderId.length > 0
                        text: currentSenderId === myId
                              ? "set by you"
                              : "set by " + shortId(currentSenderId)
                        font.pixelSize: 12
                        color: "#5a6675"
                    }
                }
            }
        }

        Text {
            text: "Pick a color"
            font.pixelSize: 14
            color: textOn(tint.color.toString())
            opacity: 0.85
        }

        // Palette — using Button (same pattern as polling) so the click path
        // is identical to what's known to work. Each button paints its full
        // bounding box in the palette color via a custom background.
        GridLayout {
            Layout.fillWidth: true
            columns: 3
            columnSpacing: 12
            rowSpacing: 12

            Repeater {
                model: palette
                delegate: Button {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 60

                    contentItem: Text {
                        text: modelData.name
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        color: textOn(modelData.hex)
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    background: Rectangle {
                        radius: 10
                        color: modelData.hex
                        border.color: currentColor === modelData.hex ? "#1f2d3d" : "#dfe3e8"
                        border.width: currentColor === modelData.hex ? 3 : 1
                    }

                    onClicked: {
                        console.log("shared_color: clicked", modelData.name, modelData.hex)
                        callColor("setColor", [modelData.hex])
                        refresh()
                        console.log("shared_color: after setColor, currentColor =", currentColor)
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }

        Text {
            visible: myId.length > 0
            text: "your id: " + shortId(myId)
            font.pixelSize: 11
            color: textOn(tint.color.toString())
            opacity: 0.6
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
