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

    function callVoting(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("voting", method, args)
    }

    function refresh() {
        deliveryStatus = callVoting("deliveryStatus", []) || 0
        if (voterId === "") voterId = callVoting("myVoterId", []) || ""
        const json = callVoting("listPolls", [])
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
                text: "Voting"
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
                    if (deliveryStatus === 0) callVoting("startDelivery", [])
                    else                      callVoting("stopDelivery",  [])
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

                    // Vote tally bar
                    Rectangle {
                        Layout.fillWidth: true
                        height: 8
                        radius: 4
                        color: "#eee"

                        Rectangle {
                            anchors.left: parent.left
                            anchors.top: parent.top; anchors.bottom: parent.bottom
                            width: parent.width * (modelData.total > 0
                                                   ? modelData.yes / modelData.total
                                                   : 0)
                            radius: 4
                            color: "#34a853"
                            Behavior on width { NumberAnimation { duration: 200 } }
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
                            onClicked: { callVoting("vote", [modelData.id, true]); refresh() }
                        }
                        Button {
                            Layout.fillWidth: true
                            text: "Vote No"
                            highlighted: modelData.myVote === "no"
                            onClicked: { callVoting("vote", [modelData.id, false]); refresh() }
                        }
                        Button {
                            text: "Close"
                            onClicked: { callVoting("closePoll", [modelData.id]); refresh() }
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

        // Open / join poll form
        Rectangle {
            Layout.fillWidth: true
            height: openCol.implicitHeight + 24
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 8

            ColumnLayout {
                id: openCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 6

                Text {
                    text: "Open or join a poll"
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    TextField {
                        id: pollIdField
                        Layout.fillWidth: true
                        placeholderText: "Poll id (e.g. fruit-best-2026)"
                    }
                    Button {
                        text: "Random"
                        onClicked: pollIdField.text =
                            "poll-" + Math.random().toString(36).slice(2, 8)
                    }
                }

                TextField {
                    id: questionField
                    Layout.fillWidth: true
                    placeholderText: "Question (leave blank when joining an existing poll)"
                    onAccepted: openButton.clicked()
                }

                Button {
                    id: openButton
                    Layout.fillWidth: true
                    text: "Open / Join"
                    onClicked: {
                        const id = pollIdField.text.trim()
                        if (id.length === 0) return
                        callVoting("openPoll", [id, questionField.text.trim()])
                        pollIdField.text = ""
                        questionField.text = ""
                        refresh()
                    }
                }
            }
        }
    }

    // Poll every 1.5s for a simple live tally. A real app would subscribe to the
    // voting module's voteReceived events via logos.onModuleEvent(...).
    Timer {
        interval: 1500
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
