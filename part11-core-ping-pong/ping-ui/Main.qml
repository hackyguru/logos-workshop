import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 620
    height: 760

    property int    deliveryStatus: 0
    property var    exchanges: []
    property string myId: ""
    property string currentRoom: "lobby"

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callPing(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("ping", method, args)
    }

    // Basecamp JSON-encodes every remote-method return, so a C++ QString arrives
    // in QML as a JSON-string literal. Unwrap that layer before using.
    function unwrapRemote(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try { return JSON.parse(raw) } catch (e) { return defaultVal }
    }

    function refresh() {
        const sNum = unwrapRemote(callPing("deliveryStatus", []), 0)
        deliveryStatus = (typeof sNum === "number") ? sNum : 0
        if (myId === "") {
            const v = unwrapRemote(callPing("myId", []), "")
            myId = (typeof v === "string") ? v : ""
        }
        const r = unwrapRemote(callPing("room", []), "lobby")
        if (typeof r === "string" && r.length > 0) currentRoom = r
        const inner = unwrapRemote(callPing("listExchanges", []), [])
        try {
            exchanges = (typeof inner === "string") ? JSON.parse(inner) : inner
        } catch (e) { exchanges = [] }
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
    function topicFor(room) { return "/pingpong/1/" + room + "/json" }

    // ── Layout ───────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "Ping ⟷ Pong"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle { width: 10; height: 10; radius: 5; color: statusColor(deliveryStatus) }
            Text { text: statusText(deliveryStatus); color: "#444"; font.pixelSize: 13 }
            Button {
                text: deliveryStatus === 0 ? "Start" : "Stop"
                onClicked: {
                    if (deliveryStatus === 0) callPing("startDelivery", [])
                    else                      callPing("stopDelivery",  [])
                    refresh()
                }
            }
        }

        Text {
            visible: myId.length > 0
            text: "my id: " + myId + "   ·   topic: " + topicFor(currentRoom)
            color: "#888"
            font.pixelSize: 11
        }

        // Room row
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8
            RowLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                Text { text: "Room"; color: "#555"; font.pixelSize: 13 }
                // No binding to currentRoom — that would clobber what the user
                // is typing on every poll. The active room is shown in the topic
                // line above; this field is only for switching to a new one.
                TextField {
                    id: roomField
                    Layout.fillWidth: true
                    placeholderText: currentRoom
                }
                Button {
                    text: "Join"
                    enabled: roomField.text.trim().length > 0
                             && roomField.text.trim() !== currentRoom
                    onClicked: { callPing("joinRoom", [roomField.text.trim()]); refresh() }
                }
            }
        }

        // Send ping
        Button {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            text: "Send Ping"
            enabled: deliveryStatus !== 0
            font.pixelSize: 16
            onClicked: { callPing("sendPing", []); refresh() }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: exchanges.length > 0 ? exchanges.length + " ping(s) sent" : ""
                color: "#666"; font.pixelSize: 12; Layout.fillWidth: true
            }
            Button {
                text: "Clear"
                visible: exchanges.length > 0
                onClicked: { callPing("clearExchanges", []); refresh() }
            }
        }

        // Exchange list
        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: exchanges
            spacing: 8
            clip: true

            delegate: Rectangle {
                width: listView.width
                height: 64
                color: "white"
                border.color: modelData.ponged ? "#34a853" : "#dfe3e8"
                border.width: 1
                radius: 8

                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 12

                    // Status glyph
                    Rectangle {
                        width: 34; height: 34; radius: 17
                        color: modelData.ponged ? "#e6f4ea" : "#fef7e0"
                        Text {
                            anchors.centerIn: parent
                            text: modelData.ponged ? "🏓" : "⏳"
                            font.pixelSize: 16
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        Layout.fillWidth: true
                        Text {
                            text: "ping " + modelData.id
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            color: "#1f2d3d"
                        }
                        Text {
                            text: modelData.ponged
                                  ? ("pong from " + (modelData.ponger || "?"))
                                  : ("waiting for pong… " + Math.floor(modelData.ageMs / 1000) + "s")
                            color: modelData.ponged ? "#188038" : "#9a7700"
                            font.pixelSize: 12
                        }
                    }

                    Text {
                        visible: modelData.ponged
                        text: modelData.rttMs + " ms"
                        color: "#188038"
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: exchanges.length === 0
                width: parent.width - 40
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: deliveryStatus === 0
                      ? "Press Start, then Send Ping.\nA logoscore-CLI ponger on the same topic will answer."
                      : "Press Send Ping — your ping goes onto\n" + topicFor(currentRoom)
                color: "#9aa5b1"
            }
        }
    }

    // Poll for live updates. A production app would subscribe to ping's
    // pongReceived / pingSent events via logos.onModuleEvent(...).
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
