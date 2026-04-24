import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 640
    height: 820

    property int  deliveryStatus: 0
    property var  polls: []
    property string voterId: ""

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callPolling(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("polling", method, args)
    }

    function refresh() {
        deliveryStatus = callPolling("deliveryStatus", []) || 0
        if (voterId === "") voterId = callPolling("myVoterId", []) || ""
        const json = callPolling("listPolls", [])
        try { polls = JSON.parse(json) } catch (e) { polls = [] }
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
    function pct(n, total) {
        if (total <= 0) return 0
        return Math.round((n / total) * 100)
    }

    // ── Layout ───────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        // Header: title + connection status + start/stop button
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Text {
                text: "Polling"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle {
                width: 10; height: 10; radius: 5
                color: statusColor(deliveryStatus)
            }
            Text {
                text: statusText(deliveryStatus)
                color: "#444"
                font.pixelSize: 13
            }
            Button {
                text: deliveryStatus === 0 ? "Start" : "Stop"
                onClicked: {
                    if (deliveryStatus === 0) callPolling("startDelivery", [])
                    else                      callPolling("stopDelivery",  [])
                    refresh()
                }
            }
        }

        Text {
            visible: voterId.length > 0
            text: "voter id: " + voterId
            color: "#888"
            font.pixelSize: 11
        }

        // Polls list
        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: polls
            spacing: 10
            clip: true

            delegate: Rectangle {
                width: listView.width
                height: pollCol.implicitHeight + 24
                color: "white"
                border.color: "#dfe3e8"
                border.width: 1
                radius: 8

                ColumnLayout {
                    id: pollCol
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 8

                    Text {
                        text: modelData.question && modelData.question.length > 0
                              ? modelData.question
                              : "(no question) " + modelData.id
                        font.pixelSize: 16
                        font.weight: Font.DemiBold
                        color: "#1f2d3d"
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }

                    Text {
                        text: "id: " + modelData.id
                        color: "#888"
                        font.pixelSize: 11
                    }

                    // Vote tally bar — red "no" background, green "yes" overlay.
                    // Stays grey when there are no votes yet.
                    Rectangle {
                        Layout.fillWidth: true
                        height: 8
                        radius: 4
                        color: modelData.total > 0 ? "#ea4335" : "#eee"

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top; anchors.bottom: parent.bottom
                            width: parent.width * (modelData.total > 0
                                                   ? modelData.yes / modelData.total
                                                   : 0)
                            radius: 4
                            color: "#34a853"
                        }
                    }

                    RowLayout {
                        spacing: 18
                        Text {
                            text: "Yes: " + modelData.yes + "  (" + pct(modelData.yes, modelData.total) + "%)"
                            color: "#34a853"
                            font.pixelSize: 13
                        }
                        Text {
                            text: "No: "  + modelData.no  + "  (" + pct(modelData.no,  modelData.total) + "%)"
                            color: "#ea4335"
                            font.pixelSize: 13
                        }
                        Text {
                            text: "Total: " + modelData.total
                            color: "#666"
                            font.pixelSize: 13
                            Layout.fillWidth: true
                        }
                        Text {
                            visible: modelData.myVote && modelData.myVote.length > 0
                            text: "you: " + modelData.myVote
                            color: "#1a73e8"
                            font.pixelSize: 12
                            font.italic: true
                        }
                    }

                    RowLayout {
                        spacing: 8
                        Layout.fillWidth: true

                        Button {
                            Layout.fillWidth: true
                            text: "Vote Yes"
                            highlighted: modelData.myVote === "yes"
                            onClicked: { callPolling("vote", [modelData.id, true]); refresh() }
                        }
                        Button {
                            Layout.fillWidth: true
                            text: "Vote No"
                            highlighted: modelData.myVote === "no"
                            onClicked: { callPolling("vote", [modelData.id, false]); refresh() }
                        }
                        Button {
                            text: "Close"
                            onClicked: { callPolling("closePoll", [modelData.id]); refresh() }
                        }
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: polls.length === 0
                text: "No polls open. Open one below, or paste an id to join."
                color: "#9aa5b1"
            }
        }

        // Create / Join form — mode toggle at top, id + (optional) question
        // fields below. Fixed height so the container doesn't jump between
        // modes.
        Rectangle {
            id: formCard
            Layout.fillWidth: true
            Layout.preferredHeight: 210
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 8

            // "create" = new poll, need id + question. "join" = existing poll, id only.
            property string mode: "create"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10

                // Segmented mode toggle
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    Button {
                        Layout.fillWidth: true
                        text: "Create poll"
                        highlighted: formCard.mode === "create"
                        onClicked: formCard.mode = "create"
                    }
                    Button {
                        Layout.fillWidth: true
                        text: "Join poll"
                        highlighted: formCard.mode === "join"
                        onClicked: formCard.mode = "join"
                    }
                }

                // Poll id — always visible. Random helper only in create mode.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    TextField {
                        id: pollIdField
                        Layout.fillWidth: true
                        placeholderText: formCard.mode === "create"
                            ? "Choose a poll id (e.g. fruit-best-2026)"
                            : "Poll id to join"
                    }
                    Button {
                        visible: formCard.mode === "create"
                        text: "Random"
                        onClicked: pollIdField.text =
                            "poll-" + Math.random().toString(36).slice(2, 8)
                    }
                }

                // Question — only in create mode. Space is naturally reclaimed
                // by the fixed container height staying constant.
                TextField {
                    id: questionField
                    visible: formCard.mode === "create"
                    Layout.fillWidth: true
                    placeholderText: "Your question (shown to everyone who joins)"
                }

                Button {
                    id: actionButton
                    Layout.fillWidth: true
                    text: formCard.mode === "create" ? "Create poll" : "Join poll"
                    enabled: {
                        const hasId = pollIdField.text.trim().length > 0
                        if (formCard.mode === "create")
                            return hasId && questionField.text.trim().length > 0
                        return hasId
                    }
                    onClicked: {
                        const id = pollIdField.text.trim()
                        if (id.length === 0) return
                        const q  = formCard.mode === "create"
                                   ? questionField.text.trim() : ""
                        callPolling("openPoll", [id, q])
                        pollIdField.text = ""
                        questionField.text = ""
                        refresh()
                    }
                }
            }
        }
    }

    // Poll every 1.5s for a simple live tally. A real app would subscribe to the
    // polling module's voteReceived events via logos.onModuleEvent(...).
    Timer {
        interval: 1500
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
