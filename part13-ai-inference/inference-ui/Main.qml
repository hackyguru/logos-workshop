import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 640
    height: 860

    property int    deliveryStatus: 0
    property var    exchanges: []
    property string myId: ""
    property string currentRoom: "lobby"

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callInf(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("inference", method, args)
    }

    // Basecamp JSON-encodes every remote-method return, so a C++ QString arrives
    // in QML as a JSON-string literal. Unwrap that layer before using.
    function unwrapRemote(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try { return JSON.parse(raw) } catch (e) { return defaultVal }
    }

    function refresh() {
        const sNum = unwrapRemote(callInf("deliveryStatus", []), 0)
        deliveryStatus = (typeof sNum === "number") ? sNum : 0
        if (myId === "") {
            const v = unwrapRemote(callInf("myId", []), "")
            myId = (typeof v === "string") ? v : ""
        }
        const r = unwrapRemote(callInf("room", []), "lobby")
        if (typeof r === "string" && r.length > 0) currentRoom = r
        const inner = unwrapRemote(callInf("listExchanges", []), [])
        try {
            exchanges = (typeof inner === "string") ? JSON.parse(inner) : inner
        } catch (e) { exchanges = [] }
    }

    function send() {
        const p = promptField.text.trim()
        if (p.length === 0 || deliveryStatus === 0) return
        callInf("sendPrompt", [p])
        promptField.text = ""
        refresh()
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
    function topicFor(room) { return "/inference/1/" + room + "/json" }

    // ── Layout ───────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "AI Inference"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle { width: 10; height: 10; radius: 5; color: statusColor(deliveryStatus) }
            Text { text: statusText(deliveryStatus); color: "#444"; font.pixelSize: 13 }
            Button {
                text: deliveryStatus === 0 ? "Start" : "Stop"
                onClicked: {
                    if (deliveryStatus === 0) callInf("startDelivery", [])
                    else                      callInf("stopDelivery",  [])
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
            Layout.preferredHeight: 52
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8
            RowLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                Text { text: "Room"; color: "#555"; font.pixelSize: 13 }
                // No binding to currentRoom — that would clobber typing on every poll.
                TextField {
                    id: roomField
                    Layout.fillWidth: true
                    placeholderText: currentRoom
                }
                Button {
                    text: "Join"
                    enabled: roomField.text.trim().length > 0
                             && roomField.text.trim() !== currentRoom
                    onClicked: { callInf("joinRoom", [roomField.text.trim()]); refresh() }
                }
            }
        }

        // Prompt composer
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 110
            color: "#f8f9fa"
            border.color: "#dfe3e8"; border.width: 1; radius: 8
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 8
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    TextArea {
                        id: promptField
                        placeholderText: "Ask the model anything…  (Ctrl+Enter to send)"
                        wrapMode: TextArea.Wrap
                        font.pixelSize: 13
                        selectByMouse: true
                        Keys.onPressed: (e) => {
                            if ((e.modifiers & Qt.ControlModifier) &&
                                (e.key === Qt.Key_Return || e.key === Qt.Key_Enter)) {
                                send(); e.accepted = true
                            }
                        }
                    }
                }
                Button {
                    Layout.alignment: Qt.AlignRight
                    text: "Send prompt"
                    enabled: deliveryStatus !== 0 && promptField.text.trim().length > 0
                    onClicked: send()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Text {
                text: exchanges.length > 0 ? exchanges.length + " prompt(s)" : ""
                color: "#666"; font.pixelSize: 12; Layout.fillWidth: true
            }
            Button {
                text: "Clear"
                visible: exchanges.length > 0
                onClicked: { callInf("clearExchanges", []); refresh() }
            }
        }

        // Exchange list (newest first)
        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: exchanges
            spacing: 10
            clip: true

            delegate: Rectangle {
                width: listView.width
                height: col.implicitHeight + 22
                color: "white"
                border.color: modelData.answered ? "#34a853" : "#dfe3e8"
                border.width: 1
                radius: 8

                ColumnLayout {
                    id: col
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 6

                    // The prompt (what you asked)
                    Text {
                        text: "🧑  " + modelData.prompt
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: "#1f2d3d"
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: "#eef1f4" }

                    // The response (or a thinking indicator)
                    Text {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        textFormat: Text.PlainText
                        font.pixelSize: 13
                        color: modelData.answered ? "#1f2d3d" : "#9a7700"
                        text: modelData.answered
                              ? ("🤖  " + (modelData.text && modelData.text.length > 0
                                          ? modelData.text : "(empty response)"))
                              : ("🤖  thinking… " + Math.floor(modelData.ageMs / 1000) + "s")
                    }

                    // Footer: model · provider · latency
                    Text {
                        visible: modelData.answered
                        text: (modelData.model || "model")
                              + "  ·  " + (modelData.provider || "?")
                              + "  ·  " + modelData.rttMs + " ms"
                        color: "#188038"
                        font.pixelSize: 11
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
                      ? "Press Start, type a prompt, and Send.\nA logoscore-CLI provider running ollama will answer."
                      : "Type a prompt and Send — it goes onto\n" + topicFor(currentRoom)
                color: "#9aa5b1"
            }
        }
    }

    // Poll for live updates. A production app would subscribe to inference's
    // responseReceived / promptSent events via logos.onModuleEvent(...).
    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
