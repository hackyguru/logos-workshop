import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 520
    height: 620

    property int    chainStatus: 0      // 0=unconfigured 1=checking 2=ready 3=error
    property string lastError:   ""
    property string sequencerUrl: ""
    property var    countState:   ({})   // {count, fetchedAt}

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callCounter(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("counter", method, args)
    }

    function refresh() {
        chainStatus  = callCounter("chainStatus",  []) || 0
        lastError    = callCounter("lastError",    []) || ""
        sequencerUrl = callCounter("sequencerUrl", []) || ""
        try { countState = JSON.parse(callCounter("currentCount", []) || "{}") }
        catch (e) { countState = {} }
    }

    function statusText(s) {
        if (s === 2) return "Connected"
        if (s === 1) return "Checking…"
        if (s === 3) return "Error"
        return "Unconfigured"
    }
    function statusColor(s) {
        if (s === 2) return "#34a853"
        if (s === 1) return "#fbbc04"
        if (s === 3) return "#ea4335"
        return "#9aa5b1"
    }

    // ── Layout ───────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 16

        // Header: title + chain status dot + refresh
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "On-chain counter"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle {
                width: 10; height: 10; radius: 5
                color: statusColor(chainStatus)
            }
            Text {
                text: statusText(chainStatus)
                color: "#444"
                font.pixelSize: 13
            }
            Button {
                text: "Refresh"
                onClicked: { callCounter("refresh", []); refresh() }
            }
        }

        // Sequencer URL row — read from the wallet config; editable so
        // workshop attendees can point at a shared testnet.
        Rectangle {
            Layout.fillWidth: true
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 6
            Layout.preferredHeight: urlCol.implicitHeight + 20

            ColumnLayout {
                id: urlCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                Text {
                    text: "Sequencer"
                    font.pixelSize: 11
                    color: "#666"
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    TextField {
                        id: urlField
                        Layout.fillWidth: true
                        text: root.sequencerUrl
                        placeholderText: "https://devnet.blockchain.logos.co or http://127.0.0.1:3040"
                        font.family: "monospace"
                        font.pixelSize: 12
                        selectByMouse: true
                    }
                    Button {
                        text: "Set"
                        enabled: urlField.text.trim().length > 0 &&
                                 urlField.text.trim() !== root.sequencerUrl
                        onClicked: {
                            callCounter("setSequencerUrl", [urlField.text.trim()])
                            refresh()
                        }
                    }
                }
            }
        }

        // The big number + increment button
        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 260
            spacing: 12

            Text {
                Layout.alignment: Qt.AlignHCenter
                text: (countState.count !== undefined && countState.count !== null)
                      ? countState.count
                      : "—"
                font.pixelSize: 120
                font.weight: Font.Bold
                color: chainStatus === 2 ? "#1f2d3d" : "#9aa5b1"
            }
            Text {
                Layout.alignment: Qt.AlignHCenter
                text: countState.fetchedAt
                      ? "fetched " + countState.fetchedAt + " UTC"
                      : ""
                color: "#888"
                font.pixelSize: 11
            }
            Button {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 240
                Layout.preferredHeight: 56
                text: "Increment +1"
                font.pixelSize: 18
                enabled: chainStatus === 2
                onClicked: {
                    callCounter("increment", [])
                    refresh()
                }
            }
        }

        Item { Layout.fillHeight: true }   // spacer

        // Error banner — only visible when something's wrong
        Rectangle {
            Layout.fillWidth: true
            visible: lastError.length > 0
            color: "#fde7e9"
            border.color: "#ea4335"
            border.width: 1
            radius: 6
            Layout.preferredHeight: errCol.implicitHeight + 16

            ColumnLayout {
                id: errCol
                anchors.fill: parent
                anchors.margins: 8
                spacing: 2
                Text {
                    text: "Chain error"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: "#b3261e"
                }
                Text {
                    Layout.fillWidth: true
                    text: lastError
                    color: "#5f1f1a"
                    font.pixelSize: 11
                    font.family: "monospace"
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    // Poll cadence: 1.5 s when connected, 500 ms while checking.
    Timer {
        interval: chainStatus === 1 ? 500 : 1500
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
