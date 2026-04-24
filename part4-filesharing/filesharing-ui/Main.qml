import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 720
    height: 900

    property int    storageStatus: 0
    property string lastError: ""
    property var    files: []
    property var    lastUpload: ({})
    property var    lastDownload: ({})

    // ── Logos bridge helpers ─────────────────────────────────────────

    function callFS(method, args) {
        if (typeof logos === "undefined" || !logos.callModule) {
            console.log("logos bridge unavailable")
            return null
        }
        return logos.callModule("filesharing", method, args)
    }

    function refresh() {
        storageStatus = callFS("storageStatus", []) || 0
        lastError     = callFS("lastError", []) || ""

        try { lastUpload   = JSON.parse(callFS("currentUpload",   []) || "{}") } catch (e) { lastUpload   = {} }
        try { lastDownload = JSON.parse(callFS("currentDownload", []) || "{}") } catch (e) { lastDownload = {} }

        if (storageStatus === 2) {
            try { files = JSON.parse(callFS("listFiles", []) || "[]") } catch (e) { files = [] }
        } else {
            files = []
        }
    }

    function statusText(s) {
        if (s === 0) return "Off"
        if (s === 1) return "Starting…"
        if (s === 2) return "Running"
        if (s === 3) return "Error"
        return ""
    }
    function statusColor(s) {
        if (s === 2) return "#34a853"
        if (s === 1) return "#fbbc04"
        if (s === 3) return "#ea4335"
        return "#9aa5b1"
    }

    function humanSize(n) {
        if (!n || n <= 0) return "0 B"
        const units = ["B", "KB", "MB", "GB", "TB"]
        let i = 0
        let v = n
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
        return v.toFixed(v < 10 && i > 0 ? 1 : 0) + " " + units[i]
    }

    // Basecamp's QML sandbox whitelists only QtQuick / QtQuick.Controls 2.15 /
    // QtQuick.Layouts 1.15 — QtQuick.Dialogs and Qt.labs.platform are both
    // "not installed" inside plugins. Hence: no FileDialog. Users paste a
    // path, or drag a file into the DropArea (both TextFields accept drops).

    function normaliseUrl(path) {
        // DropArea gives us file:// URLs; TextField paste gives a raw path.
        // Storage module's uploadUrl takes either, but we want a consistent
        // file:// URL for both cases so the filename extraction works.
        if (!path) return ""
        if (path.indexOf("file://") === 0) return path
        if (path.charAt(0) === "/") return "file://" + path
        return path
    }

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
                text: "File sharing"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle {
                width: 10; height: 10; radius: 5
                color: statusColor(storageStatus)
            }
            Text {
                text: statusText(storageStatus)
                color: "#444"
                font.pixelSize: 13
            }
            Button {
                text: storageStatus === 0 || storageStatus === 3 ? "Start" : "Stop"
                onClicked: {
                    if (storageStatus === 0 || storageStatus === 3) callFS("startStorage", [])
                    else                                             callFS("stopStorage",  [])
                    refresh()
                }
            }
        }

        // Persistent error banner — only shows when the core reports an error.
        // This is how a failed storage_module.init / start surfaces to the user
        // instead of silently flipping to status 3.
        Rectangle {
            Layout.fillWidth: true
            visible: lastError.length > 0
            color: "#fde7e9"
            border.color: "#ea4335"
            border.width: 1
            radius: 6
            Layout.preferredHeight: errCol.implicitHeight + 20

            ColumnLayout {
                id: errCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 2

                Text {
                    text: "Storage error"
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    color: "#b3261e"
                }
                Text {
                    Layout.fillWidth: true
                    text: lastError
                    color: "#5f1f1a"
                    font.pixelSize: 12
                    font.family: "monospace"
                    wrapMode: Text.WordWrap
                }
            }
        }

        // Upload card
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: uploadCol.implicitHeight + 24
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 8

            ColumnLayout {
                id: uploadCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Text {
                    text: "Upload"
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                    color: "#1f2d3d"
                }

                Text {
                    text: "Paste a file path or drag a file from Finder into the field below, then Upload."
                    color: "#666"
                    font.pixelSize: 11
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }

                // The DropArea sits behind the TextField. When a file is
                // dragged in, we set the TextField text from the first URL.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: uploadPathField.implicitHeight + 12
                    color: uploadDrop.containsDrag ? "#e8f0fe" : "transparent"
                    border.color: uploadDrop.containsDrag ? "#1a73e8" : "#dfe3e8"
                    border.width: 1
                    radius: 4

                    TextField {
                        id: uploadPathField
                        anchors.fill: parent
                        anchors.margins: 2
                        placeholderText: "/absolute/path/to/file  —  or drag one here"
                        font.pixelSize: 12
                        selectByMouse: true
                        background: null
                    }

                    DropArea {
                        id: uploadDrop
                        anchors.fill: parent
                        onDropped: (drop) => {
                            if (drop.hasUrls && drop.urls.length > 0) {
                                uploadPathField.text = drop.urls[0].toString()
                                drop.acceptProposedAction()
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: "Upload"
                        enabled: storageStatus === 2 && uploadPathField.text.trim().length > 0
                        onClicked: {
                            const url = normaliseUrl(uploadPathField.text.trim())
                            if (url.length === 0) return
                            callFS("uploadFile", [url])
                            refresh()
                        }
                    }
                    Text {
                        text: lastUpload.filename
                              ? lastUpload.filename + "  —  " + humanSize(lastUpload.bytes)
                              : "no upload yet"
                        color: "#555"
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }

                ProgressBar {
                    Layout.fillWidth: true
                    indeterminate: lastUpload.status === 1
                    value: lastUpload.status === 2 ? 1 : 0
                    visible: lastUpload.status === 1 || lastUpload.status === 2
                }

                // CID row — visible once the upload reports a CID
                RowLayout {
                    Layout.fillWidth: true
                    visible: lastUpload.cid && lastUpload.cid.length > 0
                    spacing: 8

                    Text {
                        text: "CID:"
                        color: "#666"
                        font.pixelSize: 12
                    }
                    TextField {
                        id: cidOutField
                        Layout.fillWidth: true
                        text: lastUpload.cid || ""
                        readOnly: true
                        font.family: "monospace"
                        font.pixelSize: 12
                        selectByMouse: true
                    }
                    Button {
                        text: "Copy"
                        onClicked: {
                            cidOutField.selectAll()
                            cidOutField.copy()
                        }
                    }
                }

                Text {
                    visible: lastUpload.status === 3 && lastUpload.error
                    text: "Error: " + (lastUpload.error || "")
                    color: "#ea4335"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
            }
        }

        // Download card
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: downloadCol.implicitHeight + 24
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 8

            ColumnLayout {
                id: downloadCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Text {
                    text: "Download"
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                    color: "#1f2d3d"
                }

                TextField {
                    id: cidField
                    Layout.fillWidth: true
                    placeholderText: "Paste a CID (zDv...)"
                    font.family: "monospace"
                    font.pixelSize: 12
                }

                TextField {
                    id: saveToField
                    Layout.fillWidth: true
                    placeholderText: "/absolute/destination/path.ext"
                    font.pixelSize: 12
                    selectByMouse: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: "Download"
                        enabled: storageStatus === 2
                                 && cidField.text.trim().length > 0
                                 && saveToField.text.trim().length > 0
                        onClicked: {
                            const cid  = cidField.text.trim()
                            const dest = normaliseUrl(saveToField.text.trim())
                            callFS("downloadFile", [cid, dest])
                            refresh()
                        }
                    }
                    Text {
                        text: lastDownload.destPath
                              ? lastDownload.destPath + "  —  " + humanSize(lastDownload.bytes)
                              : "no download yet"
                        color: "#555"
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                    }
                }

                ProgressBar {
                    Layout.fillWidth: true
                    indeterminate: lastDownload.status === 1
                    value: lastDownload.status === 2 ? 1 : 0
                    visible: lastDownload.status === 1 || lastDownload.status === 2
                }

                Text {
                    visible: lastDownload.status === 3 && lastDownload.error
                    text: "Error: " + (lastDownload.error || "")
                    color: "#ea4335"
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
            }
        }

        // My files — local manifests
        Text {
            text: "My files"
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: "#1f2d3d"
        }

        ListView {
            id: listView
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: files
            spacing: 8
            clip: true

            delegate: Rectangle {
                width: listView.width
                height: fileCol.implicitHeight + 20
                color: "white"
                border.color: "#dfe3e8"
                border.width: 1
                radius: 8

                ColumnLayout {
                    id: fileCol
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 6

                    Text {
                        text: modelData.filename && modelData.filename.length > 0
                              ? modelData.filename
                              : "(unnamed)"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        color: "#1f2d3d"
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }

                    Text {
                        text: humanSize(modelData.datasetSize)
                              + (modelData.mimetype ? "  ·  " + modelData.mimetype : "")
                        color: "#888"
                        font.pixelSize: 11
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        TextField {
                            Layout.fillWidth: true
                            text: modelData.cid
                            readOnly: true
                            font.family: "monospace"
                            font.pixelSize: 11
                            selectByMouse: true
                        }
                        Button {
                            text: "Copy CID"
                            onClicked: {
                                cidField.text = modelData.cid
                            }
                        }
                        Button {
                            text: "Remove"
                            onClicked: {
                                callFS("removeFile", [modelData.cid])
                                refresh()
                            }
                        }
                    }
                }
            }

            Label {
                anchors.centerIn: parent
                visible: files.length === 0
                text: storageStatus === 2
                      ? "No files yet. Upload one above."
                      : "Start the storage node to see your files."
                color: "#9aa5b1"
            }
        }
    }

    // Poll every 500ms while anything is in flight, otherwise 1.5s. A real
    // app would subscribe to filesharing events via logos.onModuleEvent.
    Timer {
        interval: (lastUpload.status === 1 || lastDownload.status === 1) ? 500 : 1500
        running: true
        repeat: true
        onTriggered: refresh()
    }

    Component.onCompleted: refresh()
}
